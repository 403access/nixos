# Archive

This directory keeps the original Go implementation of the NixOS Control API
server for reference. The running server is now the Rust implementation in
[`../server`](../server).

The Go sources remain buildable and testable:

```bash
cd archive/server-go
go test ./...
go run . --listen 127.0.0.1:8787 --token-file /tmp/nixos-control-token
```

They are not part of the NixOS module or the normal development workflow.
