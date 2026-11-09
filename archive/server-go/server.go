package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/health", a.handleHealth)
	mux.HandleFunc("GET /api/status", a.handleStatus)

	mux.HandleFunc("GET /api/services", a.handleServices)
	mux.HandleFunc("POST /api/services/{unit}/{action}", a.handleServiceAction)
	mux.HandleFunc("GET /api/services/{unit}/logs", a.handleServiceLogs)

	mux.HandleFunc("GET /api/storage", a.handleStorage)
	mux.HandleFunc("GET /api/storage/pools/{name}", a.handlePoolStatus)

	mux.HandleFunc("GET /api/system/generations", a.handleGenerations)
	mux.HandleFunc("POST /api/system/rebuild", a.handleRebuild)
	mux.HandleFunc("POST /api/system/power", a.handlePower)
	mux.HandleFunc("GET /api/logs", a.handleSystemLogs)

	mux.HandleFunc("GET /api/jobs", a.handleJobs)
	mux.HandleFunc("GET /api/jobs/{id}", a.handleJob)
	mux.HandleFunc("POST /api/jobs/{id}/cancel", a.handleJobCancel)

	return a.recoverPanics(a.logRequests(a.securityHeaders(a.requireAuth(mux))))
}

func (a *app) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func (a *app) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expected, err := os.ReadFile(a.tokenFile)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, "API token is not available")
			return
		}

		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			unauthorized(w)
			return
		}
		got := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))

		if !validToken(got, strings.TrimSpace(string(expected))) {
			// Slow down brute-force attempts a little.
			time.Sleep(200 * time.Millisecond)
			unauthorized(w)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", `Bearer realm="nixos-control"`)
	writeError(w, http.StatusUnauthorized, "unauthorized")
}

func (a *app) recoverPanics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				log.Printf("panic while handling %s %s: %v", r.Method, r.URL.Path, recovered)
				writeError(w, http.StatusInternalServerError, "internal server error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func (a *app) logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(recorder, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.Path, recorder.status, time.Since(start).Round(time.Millisecond))
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("could not encode response: %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func decodeJSON(w http.ResponseWriter, r *http.Request, value any) bool {
	defer r.Body.Close()
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

func (a *app) handleHealth(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":       true,
		"version":  version,
		"hostname": hostname,
		"time":     time.Now().UTC().Format(time.RFC3339),
	})
}

func (a *app) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, a.collectStatus())
}

func (a *app) handleServices(w http.ResponseWriter, r *http.Request) {
	services := collectServiceUnits()
	if services == nil {
		services = []ServiceUnit{}
	}
	writeJSON(w, http.StatusOK, services)
}

func (a *app) handleServiceAction(w http.ResponseWriter, r *http.Request) {
	unit := r.PathValue("unit")
	action := r.PathValue("action")

	if !validUnitName(unit) {
		writeError(w, http.StatusBadRequest, "invalid service unit name")
		return
	}

	allowed := map[string]bool{
		"start":             true,
		"stop":              true,
		"restart":           true,
		"reload":            true,
		"try-restart":       true,
		"reload-or-restart": true,
		"enable":            true,
		"disable":           true,
		"reset-failed":      true,
	}
	if !allowed[action] {
		writeError(w, http.StatusBadRequest, "unsupported action")
		return
	}

	out, err := runCmd(30*time.Second, "systemctl", action, unit)
	if err != nil {
		message := strings.TrimSpace(out)
		if message == "" {
			message = err.Error()
		}
		writeError(w, http.StatusInternalServerError, message)
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) handleServiceLogs(w http.ResponseWriter, r *http.Request) {
	unit := r.PathValue("unit")
	if !validUnitName(unit) {
		writeError(w, http.StatusBadRequest, "invalid service unit name")
		return
	}

	lines := parseLinesParam(r.URL.Query().Get("lines"), 200)
	out, err := runCmd(20*time.Second, "journalctl", "-u", unit, "-n", itoa(lines), "--no-pager", "-o", "short-iso")
	if err != nil && strings.TrimSpace(out) == "" {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"unit":  unit,
		"lines": nonNilLines(out),
	})
}

func (a *app) handleSystemLogs(w http.ResponseWriter, r *http.Request) {
	lines := parseLinesParam(r.URL.Query().Get("lines"), 300)
	out, err := runCmd(20*time.Second, "journalctl", "-n", itoa(lines), "--no-pager", "-o", "short-iso")
	if err != nil && strings.TrimSpace(out) == "" {
		writeError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"lines": nonNilLines(out)})
}

func (a *app) handleStorage(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, collectStorage())
}

func (a *app) handlePoolStatus(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("name")
	if !validPoolName(name) {
		writeError(w, http.StatusBadRequest, "invalid pool name")
		return
	}

	out, err := runCmd(15*time.Second, "zpool", "status", name)
	if err != nil {
		message := strings.TrimSpace(out)
		if message == "" {
			message = err.Error()
		}
		writeError(w, http.StatusInternalServerError, message)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"name": name, "status": out})
}

func (a *app) handleGenerations(w http.ResponseWriter, r *http.Request) {
	generations := collectGenerations()
	if generations == nil {
		generations = []Generation{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"generations": generations})
}

type rebuildRequest struct {
	Action string `json:"action"`
}

func (a *app) handleRebuild(w http.ResponseWriter, r *http.Request) {
	if !a.allowRebuild {
		writeError(w, http.StatusForbidden, "rebuild actions are disabled on this server")
		return
	}

	var request rebuildRequest
	if !decodeJSON(w, r, &request) {
		return
	}

	switch request.Action {
	case "switch", "boot", "test", "dry-activate", "dry-build":
	default:
		writeError(w, http.StatusBadRequest, "action must be one of switch, boot, test, dry-activate, dry-build")
		return
	}

	args := []string{request.Action}
	if a.flake != "" {
		args = append(args, "--flake", a.flake)
	}

	dir := ""
	if _, err := os.Stat("/etc/nixos"); err == nil {
		dir = "/etc/nixos"
	}

	job := a.jobs.start("nixos-rebuild "+request.Action, "nixos-rebuild", args, dir)
	writeJSON(w, http.StatusAccepted, job)
}

type powerRequest struct {
	Action string `json:"action"`
}

func (a *app) handlePower(w http.ResponseWriter, r *http.Request) {
	if !a.allowPower {
		writeError(w, http.StatusForbidden, "power actions are disabled on this server")
		return
	}

	var request powerRequest
	if !decodeJSON(w, r, &request) {
		return
	}

	var action string
	switch request.Action {
	case "reboot":
		action = "reboot"
	case "shutdown", "poweroff":
		action = "poweroff"
	default:
		writeError(w, http.StatusBadRequest, "action must be reboot, shutdown or poweroff")
		return
	}

	out, err := runCmd(10*time.Second, "systemctl", "--no-block", action)
	if err != nil {
		message := strings.TrimSpace(out)
		if message == "" {
			message = err.Error()
		}
		writeError(w, http.StatusInternalServerError, message)
		return
	}

	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (a *app) handleJobs(w http.ResponseWriter, r *http.Request) {
	jobs := a.jobs.list()
	if jobs == nil {
		jobs = []Job{}
	}
	writeJSON(w, http.StatusOK, jobs)
}

func (a *app) handleJob(w http.ResponseWriter, r *http.Request) {
	job := a.jobs.snapshot(r.PathValue("id"))
	if job == nil {
		writeError(w, http.StatusNotFound, "job not found")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (a *app) handleJobCancel(w http.ResponseWriter, r *http.Request) {
	job := a.jobs.cancel(r.PathValue("id"))
	if job == nil {
		writeError(w, http.StatusNotFound, "job not found")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func parseLinesParam(value string, fallback int) int {
	lines := int(parseInt64(value))
	if lines <= 0 {
		return fallback
	}
	if lines < 10 {
		return 10
	}
	if lines > 2000 {
		return 2000
	}
	return lines
}

func itoa(value int) string {
	return strconv.Itoa(value)
}

func nonNilLines(output string) []string {
	lines := splitLines(output)
	if lines == nil {
		return []string{}
	}
	return lines
}
