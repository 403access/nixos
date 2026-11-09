package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"os/exec"
	"regexp"
	"sync"
	"time"
)

type Job struct {
	ID         string  `json:"id"`
	Kind       string  `json:"kind"`
	Status     string  `json:"status"`
	StartedAt  string  `json:"started_at"`
	FinishedAt *string `json:"finished_at,omitempty"`
	ExitCode   *int    `json:"exit_code,omitempty"`
	Output     string  `json:"output"`
	Error      string  `json:"error,omitempty"`
}

type jobRecord struct {
	Job
	cancel context.CancelFunc
	buffer *tailBuffer
}

type jobManager struct {
	mu    sync.Mutex
	jobs  map[string]*jobRecord
	order []string
}

func newJobManager() *jobManager {
	return &jobManager{jobs: make(map[string]*jobRecord)}
}

func (m *jobManager) start(kind, name string, args []string, directory string) *Job {
	id := randomID()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Minute)

	record := &jobRecord{
		Job: Job{
			ID:        id,
			Kind:      kind,
			Status:    "running",
			StartedAt: time.Now().UTC().Format(time.RFC3339),
		},
		cancel: cancel,
		buffer: newTailBuffer(64 * 1024),
	}

	m.mu.Lock()
	m.jobs[id] = record
	m.order = append(m.order, id)
	m.mu.Unlock()

	command := exec.CommandContext(ctx, name, args...)
	if directory != "" {
		command.Dir = directory
	}
	command.Stdout = record.buffer
	command.Stderr = record.buffer

	go func() {
		runErr := command.Run()
		finished := time.Now().UTC().Format(time.RFC3339)

		m.mu.Lock()
		record.FinishedAt = &finished
		record.cancel = nil

		switch {
		case ctx.Err() == context.Canceled:
			record.Status = "cancelled"
			record.Error = "cancelled"
		case ctx.Err() == context.DeadlineExceeded:
			record.Status = "failed"
			record.Error = "timed out after 45 minutes"
		case runErr != nil:
			record.Status = "failed"
			record.Error = runErr.Error()
			if exitErr, ok := runErr.(*exec.ExitError); ok {
				code := exitErr.ExitCode()
				record.ExitCode = &code
			}
		default:
			record.Status = "succeeded"
			code := 0
			record.ExitCode = &code
		}
		m.mu.Unlock()

		cancel()
	}()

	return m.snapshot(id)
}

func (m *jobManager) snapshot(id string) *Job {
	m.mu.Lock()
	defer m.mu.Unlock()

	record, ok := m.jobs[id]
	if !ok {
		return nil
	}

	job := record.Job
	job.Output = record.buffer.String()
	return &job
}

func (m *jobManager) cancel(id string) *Job {
	m.mu.Lock()
	record, ok := m.jobs[id]
	if ok && record.cancel != nil {
		record.cancel()
	}
	m.mu.Unlock()

	return m.snapshot(id)
}

func (m *jobManager) list() []Job {
	m.mu.Lock()
	defer m.mu.Unlock()

	jobs := []Job{}
	for i := len(m.order) - 1; i >= 0 && len(jobs) < 20; i-- {
		if record, ok := m.jobs[m.order[i]]; ok {
			job := record.Job
			job.Output = record.buffer.String()
			jobs = append(jobs, job)
		}
	}
	return jobs
}

func randomID() string {
	buffer := make([]byte, 8)
	if _, err := rand.Read(buffer); err != nil {
		return time.Now().UTC().Format("20060102150405.000000000")
	}
	return hex.EncodeToString(buffer)
}

type tailBuffer struct {
	mu   sync.Mutex
	data []byte
	max  int
}

func newTailBuffer(max int) *tailBuffer {
	return &tailBuffer{max: max}
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.data = append(b.data, p...)
	if len(b.data) > b.max {
		copy(b.data, b.data[len(b.data)-b.max:])
		b.data = b.data[:b.max]
	}
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return stripANSI(string(b.data))
}

var ansiEscapeRE = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)

func stripANSI(value string) string {
	return ansiEscapeRE.ReplaceAllString(value, "")
}
