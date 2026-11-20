# Project services with Docker

Long-running, trusted services run in Docker. Untrusted agents do **not** —
they use the KVM microVMs from `mySandbox`.

## Layout

```text
/var/lib/projects/
  example/
    compose.yaml
    data/            # bind mounts, owned by the service user
```

Images and layers stay in `/var/lib/docker` on the ext4 root. Do not move the
Docker root onto `tank`: it is a 128K-record dataset holding your data, and
Docker rewrites its storage constantly.

## Commands

```bash
sudo cp -r services/templates/example /var/lib/projects/example
sudo project-up example
sudo project-logs example
sudo project-down example
project-list
```

`project-up`, `project-down`, `project-logs` and `project-list` are covered by
a narrow sudo rule: they only accept a project name, only look under
`/var/lib/projects`, and refuse names containing `/`. The desktop user is
deliberately **not** in the `docker` group, because that group is equivalent
to root on the host.

## What the module hardens

| Setting | Effect |
| --- | --- |
| `icc = false` | containers on the default bridge cannot talk to each other |
| `no-new-privileges` | setuid helpers inside a container cannot escalate |
| `live-restore` | restarting Docker does not kill running projects |
| `log-driver = local` | bounded, compressed container logs |

Per compose file, also use:

```yaml
read_only: true
cap_drop: [ALL]
security_opt: ["no-new-privileges:true"]
user: "1000:1000"
tmpfs: ["/tmp:rw,noexec,nosuid,size=64m"]
ports: ["127.0.0.1:8080:8080"]
networks: [internal]
```

Never add `network_mode: host`, `privileged: true`, or
`/var/run/docker.sock` as a volume. Those three undo the isolation.

### Networks: published service vs. no egress

Docker **does not publish ports from an `internal: true` network** (the
network has no default gateway), so a service that must be reachable from the
host belongs on a normal project bridge.  That is what the example now uses.

For a service that must have no outbound route, put it on an internal network
and add a small proxy attached to both the internal network and a normal one:

```yaml
services:
  app:
    networks: [backend]
  proxy:
    image: alpine/socat
    command: ["TCP-LISTEN:8080,fork,reuseaddr", "TCP:app:8080"]
    ports: ["127.0.0.1:8080:8080"]
    networks: [backend, edge]   # backend: internal; edge: normal

networks:
  backend:
    internal: true
  edge:
```

The app then has no egress; only the trusted proxy does.  Agents use the KVM
microVM sandbox instead, which has no network at all unless `--online` is
passed.

## Remote access

Nothing is published beyond loopback. To reach a service from the phone or
another machine, use Tailscale:

```bash
sudo tailscale serve --bg https+insecure://127.0.0.1:8080
```

or an SSH tunnel. Do not open the port in `networking.firewall`.

## Backup

Bind mounts and named volumes are the only state. Back up the project
directory (and `docker volume ls` if you use named volumes) with the same
tooling you use for `tank`; `project-down` first is not required but makes
the copy consistent.

## Limits

- Docker shares the host kernel. A service container is not a security
  boundary against a malicious image; run only code you trust, and keep
  agents in `mySandbox`.
- Compose files are trusted input. Anyone who can write to
  `/var/lib/projects` can request `privileged: true`; keep that directory
  root-owned (the module creates it as `root:root 0750`).