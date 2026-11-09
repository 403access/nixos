package main

import (
	"encoding/json"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type CPUInfo struct {
	Model        string  `json:"model"`
	Cores        int     `json:"cores"`
	UsagePercent float64 `json:"usage_percent"`
}

type MemoryInfo struct {
	Total     int64 `json:"total"`
	Used      int64 `json:"used"`
	Free      int64 `json:"free"`
	Available int64 `json:"available"`
	Cached    int64 `json:"cached"`
	SwapTotal int64 `json:"swap_total"`
	SwapUsed  int64 `json:"swap_used"`
}

type DiskUsage struct {
	Mount      string  `json:"mount"`
	Total      int64   `json:"total"`
	Used       int64   `json:"used"`
	Available  int64   `json:"available"`
	UsePercent float64 `json:"use_percent"`
}

type PoolInfo struct {
	Name          string `json:"name"`
	Size          int64  `json:"size"`
	Allocated     int64  `json:"allocated"`
	Free          int64  `json:"free"`
	Health        string `json:"health"`
	Fragmentation string `json:"fragmentation"`
}

type Temperature struct {
	Label   string  `json:"label"`
	Celsius float64 `json:"celsius"`
}

type TailscaleInfo struct {
	Connected bool     `json:"connected"`
	Hostname  string   `json:"hostname"`
	DNSName   string   `json:"dns_name"`
	IPs       []string `json:"ips"`
	State     string   `json:"state"`
}

type ServiceCounts struct {
	Running int `json:"running"`
	Failed  int `json:"failed"`
	Total   int `json:"total"`
}

type Capabilities struct {
	Services bool `json:"services"`
	Rebuild  bool `json:"rebuild"`
	Power    bool `json:"power"`
}

type Status struct {
	ServerVersion string         `json:"server_version"`
	Hostname      string         `json:"hostname"`
	OS            string         `json:"os"`
	Kernel        string         `json:"kernel"`
	NixOSVersion  string         `json:"nixos_version"`
	UptimeSeconds int64          `json:"uptime_seconds"`
	BootTime      string         `json:"boot_time"`
	Load          []float64      `json:"load"`
	CPU           CPUInfo        `json:"cpu"`
	Memory        MemoryInfo     `json:"memory"`
	RootDisk      DiskUsage      `json:"root_disk"`
	Pools         []PoolInfo     `json:"pools"`
	Temperatures  []Temperature  `json:"temperatures"`
	Addresses     []string       `json:"addresses"`
	Generation    int            `json:"generation"`
	Tailscale     *TailscaleInfo `json:"tailscale,omitempty"`
	Services      ServiceCounts  `json:"services"`
	Capabilities  Capabilities   `json:"capabilities"`
}

func (a *app) collectStatus() *Status {
	hostname, _ := os.Hostname()
	osRelease := parseOSRelease(readFileTrim("/etc/os-release"))

	uptimeSeconds := int64(0)
	uptimeFields := strings.Fields(readFileTrim("/proc/uptime"))
	if len(uptimeFields) > 0 {
		uptimeSeconds = int64(parseFloat(uptimeFields[0]))
	}

	load := parseLoad(readFileTrim("/proc/loadavg"))

	kernel := readFileTrim("/proc/sys/kernel/osrelease")
	if kernel == "" {
		if out, err := runCmd(3*time.Second, "uname", "-r"); err == nil {
			kernel = strings.TrimSpace(out)
		}
	}

	nixosVersion := strings.TrimSpace(readFileTrim("/run/current-system/nixos-version"))
	if nixosVersion == "" {
		if out, err := runCmd(5*time.Second, "nixos-version"); err == nil {
			nixosVersion = strings.TrimSpace(out)
		}
	}
	if nixosVersion == "" {
		nixosVersion = osRelease["VERSION"]
	}
	if nixosVersion == "" {
		nixosVersion = osRelease["PRETTY_NAME"]
	}

	bootTime := time.Now().Add(-time.Duration(uptimeSeconds) * time.Second).UTC().Format(time.RFC3339)

	return &Status{
		ServerVersion: version,
		Hostname:      hostname,
		OS:            osRelease["PRETTY_NAME"],
		Kernel:        kernel,
		NixOSVersion:  nixosVersion,
		UptimeSeconds: uptimeSeconds,
		BootTime:      bootTime,
		Load:          load,
		CPU: CPUInfo{
			Model:        parseCPUModel(readFileTrim("/proc/cpuinfo")),
			Cores:        runtime.NumCPU(),
			UsagePercent: cpuSamplerInstance.usagePercent(),
		},
		Memory:       parseMeminfo(readFileTrim("/proc/meminfo")),
		RootDisk:     collectRootDisk(),
		Pools:        collectPools(),
		Temperatures: collectTemperatures(),
		Addresses:    collectAddresses(),
		Generation:   readGeneration(),
		Tailscale:    collectTailscale(),
		Services:     collectServiceCounts(),
		Capabilities: Capabilities{
			Services: true,
			Rebuild:  a.allowRebuild,
			Power:    a.allowPower,
		},
	}
}

func parseOSRelease(content string) map[string]string {
	result := make(map[string]string)
	for _, line := range splitLines(content) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		result[strings.TrimSpace(key)] = unquote(value)
	}
	return result
}

func parseLoad(content string) []float64 {
	fields := strings.Fields(content)
	load := []float64{0, 0, 0}
	for i := 0; i < 3 && i < len(fields); i++ {
		load[i] = parseFloat(fields[i])
	}
	return load
}

func parseCPUModel(content string) string {
	for _, line := range splitLines(content) {
		key, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		switch strings.TrimSpace(key) {
		case "model name", "Hardware", "Processor":
			if model := strings.TrimSpace(value); model != "" {
				return model
			}
		}
	}
	return "Unknown CPU"
}

func parseMeminfo(content string) MemoryInfo {
	values := make(map[string]int64)
	for _, line := range splitLines(content) {
		key, value, found := strings.Cut(line, ":")
		if !found {
			continue
		}
		fields := strings.Fields(value)
		if len(fields) == 0 {
			continue
		}
		values[strings.TrimSpace(key)] = parseInt64(fields[0]) * 1024
	}

	total := values["MemTotal"]
	free := values["MemFree"]
	available := values["MemAvailable"]
	if available == 0 {
		available = free + values["Buffers"] + values["Cached"] + values["SReclaimable"]
	}
	used := total - available
	if used < 0 {
		used = 0
	}
	swapTotal := values["SwapTotal"]
	swapFree := values["SwapFree"]
	swapUsed := swapTotal - swapFree
	if swapUsed < 0 {
		swapUsed = 0
	}

	return MemoryInfo{
		Total:     total,
		Used:      used,
		Free:      free,
		Available: available,
		Cached:    values["Cached"] + values["SReclaimable"],
		SwapTotal: swapTotal,
		SwapUsed:  swapUsed,
	}
}

func collectRootDisk() DiskUsage {
	output, err := runCmd(5*time.Second, "df", "-B1", "-P", "/")
	if err != nil {
		return DiskUsage{Mount: "/"}
	}
	for _, line := range splitLines(output) {
		fields := strings.Fields(line)
		if len(fields) < 6 || fields[0] == "Filesystem" {
			continue
		}
		return DiskUsage{
			Mount:      fields[5],
			Total:      parseInt64(fields[1]),
			Used:       parseInt64(fields[2]),
			Available:  parseInt64(fields[3]),
			UsePercent: parseFloat(strings.TrimSuffix(fields[4], "%")),
		}
	}
	return DiskUsage{Mount: "/"}
}

func collectPools() []PoolInfo {
	pools := []PoolInfo{}
	output, err := runCmd(8*time.Second, "zpool", "list", "-Hp", "-o", "name,size,allocated,free,health,fragmentation")
	if err != nil {
		return pools
	}
	for _, line := range splitLines(output) {
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		pools = append(pools, PoolInfo{
			Name:          fields[0],
			Size:          parseInt64(fields[1]),
			Allocated:     parseInt64(fields[2]),
			Free:          parseInt64(fields[3]),
			Health:        fields[4],
			Fragmentation: fields[5],
		})
	}
	return pools
}

func collectTemperatures() []Temperature {
	results := []Temperature{}
	paths, _ := filepath.Glob("/sys/class/hwmon/hwmon*/temp*_input")
	seen := make(map[string]int)

	for _, path := range paths {
		celsius := float64(parseInt64(readFileTrim(path))) / 1000
		if celsius < -20 || celsius > 150 {
			continue
		}

		directory := filepath.Dir(path)
		label := readFileTrim(filepath.Join(directory, strings.TrimSuffix(filepath.Base(path), "_input")+"_label"))
		if label == "" {
			label = readFileTrim(filepath.Join(directory, "name"))
		}
		if label == "" {
			label = filepath.Base(directory)
		}

		seen[label]++
		if seen[label] > 1 {
			label = fmt.Sprintf("%s #%d", label, seen[label])
		}

		results = append(results, Temperature{
			Label:   label,
			Celsius: math.Round(celsius*10) / 10,
		})
	}

	sort.Slice(results, func(i, j int) bool {
		return results[i].Celsius > results[j].Celsius
	})
	if len(results) > 12 {
		results = results[:12]
	}
	return results
}

func collectAddresses() []string {
	addresses := []string{}
	interfaces, err := net.Interfaces()
	if err != nil {
		return addresses
	}

	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch value := addr.(type) {
			case *net.IPNet:
				ip = value.IP
			case *net.IPAddr:
				ip = value.IP
			}
			if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
				continue
			}
			addresses = append(addresses, ip.String())
		}
	}

	sort.Slice(addresses, func(i, j int) bool {
		ipv4i := strings.Contains(addresses[i], ":")
		ipv4j := strings.Contains(addresses[j], ":")
		if ipv4i != ipv4j {
			return !ipv4i
		}
		return addresses[i] < addresses[j]
	})
	return addresses
}

var generationLinkRE = regexp.MustCompile(`system-(\d+)-link`)

func readGeneration() int {
	target, err := os.Readlink("/nix/var/nix/profiles/system")
	if err != nil {
		return 0
	}
	match := generationLinkRE.FindStringSubmatch(target)
	if len(match) != 2 {
		return 0
	}
	generation, _ := strconv.Atoi(match[1])
	return generation
}

type tailscaleStatusJSON struct {
	BackendState string `json:"BackendState"`
	Self         struct {
		HostName     string   `json:"HostName"`
		DNSName      string   `json:"DNSName"`
		TailscaleIPs []string `json:"TailscaleIPs"`
	} `json:"Self"`
}

func collectTailscale() *TailscaleInfo {
	if !commandExists("tailscale") {
		return &TailscaleInfo{State: "not installed", IPs: []string{}}
	}

	output, err := runCmd(4*time.Second, "tailscale", "status", "--json")
	if err != nil {
		return &TailscaleInfo{State: "unavailable", IPs: []string{}}
	}

	var parsed tailscaleStatusJSON
	if err := json.Unmarshal([]byte(output), &parsed); err != nil {
		return &TailscaleInfo{State: "unavailable", IPs: []string{}}
	}

	ips := parsed.Self.TailscaleIPs
	if ips == nil {
		ips = []string{}
	}

	return &TailscaleInfo{
		Connected: parsed.BackendState == "Running",
		Hostname:  parsed.Self.HostName,
		DNSName:   strings.TrimSuffix(parsed.Self.DNSName, "."),
		IPs:       ips,
		State:     parsed.BackendState,
	}
}

type cpuSampler struct {
	mu        sync.Mutex
	prevTotal uint64
	prevIdle  uint64
	primed    bool
}

var cpuSamplerInstance = &cpuSampler{}

func primeCPU() {
	cpuSamplerInstance.usagePercent()
}

func (s *cpuSampler) usagePercent() float64 {
	total, idle := readCPUTimes()
	if total == 0 {
		return 0
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.primed {
		s.prevTotal = total
		s.prevIdle = idle
		s.primed = true
		return 0
	}

	deltaTotal := total - s.prevTotal
	deltaIdle := idle - s.prevIdle
	s.prevTotal = total
	s.prevIdle = idle

	if deltaTotal == 0 {
		return 0
	}
	usage := 100 * float64(deltaTotal-deltaIdle) / float64(deltaTotal)
	if usage < 0 {
		return 0
	}
	if usage > 100 {
		return 100
	}
	return math.Round(usage*10) / 10
}

func readCPUTimes() (uint64, uint64) {
	content := readFileTrim("/proc/stat")
	for _, line := range splitLines(content) {
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)
		var total, idle uint64
		for i, field := range fields[1:] {
			if i >= 8 {
				break
			}
			value := parseUint64(field)
			total += value
			if i == 3 || i == 4 { // idle + iowait
				idle += value
			}
		}
		return total, idle
	}
	return 0, 0
}

func collectGenerations() []Generation {
	generations := []Generation{}

	output, err := runCmd(8*time.Second, "nix-env", "--list-generations", "--profile", "/nix/var/nix/profiles/system")
	if err == nil {
		generations = parseGenerationsOutput(output)
	}
	if len(generations) > 0 {
		return generations
	}

	links, _ := filepath.Glob("/nix/var/nix/profiles/system-*-link")
	for _, link := range links {
		base := filepath.Base(link)
		match := generationLinkRE.FindStringSubmatch(base)
		if len(match) != 2 {
			continue
		}
		number, _ := strconv.Atoi(match[1])
		date := ""
		if info, err := os.Stat(link); err == nil {
			date = info.ModTime().Format("2006-01-02 15:04:05")
		}
		generations = append(generations, Generation{
			Number:  number,
			Date:    date,
			Current: number == readGeneration(),
		})
	}

	sort.Slice(generations, func(i, j int) bool {
		return generations[i].Number < generations[j].Number
	})
	return generations
}

var generationLineRE = regexp.MustCompile(`^\s*(\d+)\s+(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(.*)$`)

func parseGenerationsOutput(output string) []Generation {
	generations := []Generation{}
	for _, line := range splitLines(output) {
		match := generationLineRE.FindStringSubmatch(line)
		if len(match) != 4 {
			continue
		}
		number, _ := strconv.Atoi(match[1])
		generations = append(generations, Generation{
			Number:  number,
			Date:    match[2],
			Current: strings.Contains(strings.ToLower(match[3]), "current"),
		})
	}
	return generations
}
