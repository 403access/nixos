package main

import (
	"encoding/json"
	"strings"
	"time"
)

type ServiceUnit struct {
	Unit        string `json:"unit"`
	Load        string `json:"load"`
	Active      string `json:"active"`
	Sub         string `json:"sub"`
	Description string `json:"description"`
}

type Generation struct {
	Number  int    `json:"number"`
	Date    string `json:"date"`
	Current bool   `json:"current"`
}

func collectServiceUnits() []ServiceUnit {
	output, err := runCmd(10*time.Second, "systemctl", "list-units", "--type=service", "--all", "--output=json", "--no-pager")
	if err == nil {
		var units []ServiceUnit
		if json.Unmarshal([]byte(output), &units) == nil {
			return units
		}
	}

	// Fallback for systemd versions without JSON output.
	output, err = runCmd(10*time.Second, "systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager")
	if err != nil && strings.TrimSpace(output) == "" {
		return []ServiceUnit{}
	}

	units := []ServiceUnit{}
	for _, line := range splitLines(output) {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == "●" {
			fields = fields[1:]
		}
		if len(fields) < 4 || !strings.HasSuffix(fields[0], ".service") {
			continue
		}
		description := ""
		if len(fields) > 4 {
			description = strings.Join(fields[4:], " ")
		}
		units = append(units, ServiceUnit{
			Unit:        fields[0],
			Load:        fields[1],
			Active:      fields[2],
			Sub:         fields[3],
			Description: description,
		})
	}
	return units
}

func collectServiceCounts() ServiceCounts {
	counts := ServiceCounts{}
	output, err := runCmd(10*time.Second, "systemctl", "list-units", "--type=service", "--all", "--no-legend", "--plain", "--no-pager")
	if err != nil && strings.TrimSpace(output) == "" {
		return counts
	}

	for _, line := range splitLines(output) {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[0] == "●" {
			fields = fields[1:]
		}
		if len(fields) < 3 || !strings.HasSuffix(fields[0], ".service") {
			continue
		}
		counts.Total++
		switch fields[2] {
		case "active":
			counts.Running++
		case "failed":
			counts.Failed++
		}
	}
	return counts
}
