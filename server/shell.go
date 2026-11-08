package main

import (
	"context"
	"fmt"
	"os/exec"
	"time"
)

const commandTimeout = 8 * time.Second

// runCmd runs a command and returns combined stdout/stderr. It never uses a
// shell, so arguments are not interpreted.
func runCmd(timeout time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return string(out), fmt.Errorf("%s timed out after %s", name, timeout)
	}
	return string(out), err
}

func commandExists(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}
