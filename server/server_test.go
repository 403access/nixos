package main

import "testing"

func TestParseMeminfo(t *testing.T) {
	content := `MemTotal:       16384000 kB
MemFree:         2048000 kB
MemAvailable:   12288000 kB
Buffers:          512000 kB
Cached:          4096000 kB
SReclaimable:     512000 kB
SwapTotal:       4096000 kB
SwapFree:        3072000 kB
`
	memory := parseMeminfo(content)

	if memory.Total != 16384000*1024 {
		t.Fatalf("unexpected total: %d", memory.Total)
	}
	if memory.Used != (16384000-12288000)*1024 {
		t.Fatalf("unexpected used: %d", memory.Used)
	}
	if memory.SwapUsed != 1024000*1024 {
		t.Fatalf("unexpected swap used: %d", memory.SwapUsed)
	}
	if memory.Cached != (4096000+512000)*1024 {
		t.Fatalf("unexpected cached: %d", memory.Cached)
	}
}

func TestParseGenerationsOutput(t *testing.T) {
	output := `   1   2024-01-01 10:00:00
   2   2024-02-01 11:30:00
   3   2024-03-01 12:45:00   (current)
`
	generations := parseGenerationsOutput(output)

	if len(generations) != 3 {
		t.Fatalf("expected 3 generations, got %d", len(generations))
	}
	if generations[2].Number != 3 || !generations[2].Current {
		t.Fatalf("expected generation 3 to be current: %+v", generations[2])
	}
	if generations[0].Date != "2024-01-01 10:00:00" {
		t.Fatalf("unexpected date: %q", generations[0].Date)
	}
}

func TestParseLoad(t *testing.T) {
	load := parseLoad("0.52 0.61 0.73 2/412 12345\n")
	if len(load) != 3 || load[0] != 0.52 || load[1] != 0.61 || load[2] != 0.73 {
		t.Fatalf("unexpected load: %v", load)
	}
}

func TestParseOSRelease(t *testing.T) {
	release := parseOSRelease("PRETTY_NAME=\"NixOS 25.05 (Xantusia)\"\nVERSION_ID=25.05\n")
	if release["PRETTY_NAME"] != "NixOS 25.05 (Xantusia)" {
		t.Fatalf("unexpected pretty name: %q", release["PRETTY_NAME"])
	}
	if release["VERSION_ID"] != "25.05" {
		t.Fatalf("unexpected version: %q", release["VERSION_ID"])
	}
}

func TestValidToken(t *testing.T) {
	if !validToken("secret", "secret") {
		t.Fatal("expected tokens to match")
	}
	if validToken("secret", "other") {
		t.Fatal("expected tokens not to match")
	}
	if validToken("", "") {
		t.Fatal("empty token must never be valid")
	}
}

func TestValidUnitName(t *testing.T) {
	valid := []string{"nginx.service", "getty@tty1.service", "docker.service", "systemd-networkd.service", "systemd-fsck@dev-disk-by\\x2duuid-1234.service"}
	for _, name := range valid {
		if !validUnitName(name) {
			t.Fatalf("expected %q to be valid", name)
		}
	}

	invalid := []string{"nginx", "../../etc/passwd", "--help.service", "nginx.socket", "foo bar.service"}
	for _, name := range invalid {
		if validUnitName(name) {
			t.Fatalf("expected %q to be invalid", name)
		}
	}
}

func TestTailBufferKeepsTail(t *testing.T) {
	buffer := newTailBuffer(5)
	_, _ = buffer.Write([]byte("abc"))
	_, _ = buffer.Write([]byte("defg"))

	if got := buffer.String(); got != "cdefg" {
		t.Fatalf("unexpected tail: %q", got)
	}
}
