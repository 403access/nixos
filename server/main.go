package main

import (
	"flag"
	"log"
	"net/http"
	"time"
)

// version is overridden at build time via -ldflags "-X main.version=...".
var version = "dev"

type app struct {
	tokenFile    string
	flake        string
	allowRebuild bool
	allowPower   bool
	jobs         *jobManager
}

func main() {
	listen := flag.String("listen", "127.0.0.1:8787", "address to listen on")
	tokenFile := flag.String("token-file", "", "file containing the bearer token")
	flake := flag.String("flake", "", "optional flake reference for nixos-rebuild (for example /etc/nixos#hostname)")
	allowRebuild := flag.Bool("allow-rebuild", true, "allow nixos-rebuild actions")
	allowPower := flag.Bool("allow-power", true, "allow reboot and shutdown actions")
	flag.Parse()

	if *tokenFile == "" {
		log.Fatal("--token-file is required")
	}

	a := &app{
		tokenFile:    *tokenFile,
		flake:        *flake,
		allowRebuild: *allowRebuild,
		allowPower:   *allowPower,
		jobs:         newJobManager(),
	}

	// Prime the CPU sampler so the first status request has a usable delta.
	primeCPU()

	srv := &http.Server{
		Addr:              *listen,
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}

	log.Printf("nixos-control %s listening on %s", version, *listen)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}
