# Agent sandboxes

`mySandbox` runs untrusted agents — and Docker containers inside those agents —
in KVM microVMs with their own kernel and their own network namespace.  The
short version:

- **The host can reach a sandbox.** Published ports and the sandbox IP work
  from the host.
- **A sandbox cannot initiate anything to the host.** New connections to any
  host address, including `127.0.0.1`, are dropped by the host firewall.
- **Sandboxes cannot reach each other.** Traffic between sandbox subnets is
  dropped.
- **Only explicit folders are shared.** The workspace is exclusive to one
  running sandbox; `--share` is the deliberate way to share a folder with the
  host or with another sandbox.
- **Offline is the default.** `--online` adds internet egress; `--lan` also
  adds private networks, but never the host.

The implementation is in [`sandbox/`](../sandbox/README.md).  This page is the
operator guide: how to run it, verify it, and reason about failures.

## Enable

```nix
mySandbox = {
  enable = true;
  user = "nixos";
  cpus = 4;
  memory = 4096;
  image = "docker.io/library/debian:bookworm-slim";
};
```

Rebuild:

```bash
sudo nixos-rebuild switch
```

The module creates:

| Path | Purpose |
| --- | --- |
| `/var/lib/agent-workspaces` | Default workspace root, owned by `mySandbox.user` |
| `/var/lib/agent-shares` | Conventional root for folders shared between sandboxes |
| `/var/lib/agent-vm` | Root-only state: sandbox metadata, ports, shares |
| `/run/agent-vm` | Runtime: network namespaces, socat pids, nft ruleset, logs |

It also enables `net.ipv4.ip_forward` for guest egress and installs
`agent-vm`, `krunvm`, `buildah`, `nftables`, `iproute2` and `socat`.

## Run

```bash
cd ~/src/project
sudo agent-vm
```

That boots the default image with four vCPUs and 4 GiB RAM, mounts the current
directory at `/workspace`, and starts an interactive shell.  Useful forms:

```bash
sudo agent-vm --ephemeral -- python3 -m pytest
sudo agent-vm --online -- npm ci
sudo agent-vm --name web --detach --port 8080:8080 -- my-server
sudo agent-vm logs web
sudo agent-vm stop web
sudo agent-vm rm web
sudo agent-vm list
```

### Published ports

```bash
# 127.0.0.1:8080 on the host -> guest port 8080
sudo agent-vm --port 8080:8080 -- my-server

# all host interfaces, only if you really need it
sudo agent-vm --publish 0.0.0.0:8080:8080 -- my-server
```

The host binds the listener with `socat` and proxies to the sandbox; there is
no DNAT from a host loopback source into the guest.  Ports are TCP only.  Two
running sandboxes cannot publish the same host port.

### Shared folders

```bash
# /srv/docs -> /share-docs, read-only
sudo agent-vm --share /srv/docs:ro

# /srv/team -> /share-team, read-write
sudo agent-vm --share team=/srv/team
```

A running workspace is exclusive: a second sandbox that names the same
`--workspace` is refused.  Giving two sandboxes the same `--share` path is the
supported way for sandbox A and sandbox B to exchange files.  The host
filesystem is the broker; neither sandbox mounts the other.

> **Warning:** The VMM runs as root to mount the OCI rootfs. Inside a
> read-write workspace or share, guest root can create files owned by host root
> and set mode bits. Do not execute files from an agent workspace as a
> privileged host user, and use `--share ...:ro` for host-provided inputs. A
> dedicated workspace dataset mounted with `nosuid` and `devices=off` limits
> the blast radius.

### Docker in the sandbox

```bash
sudo ./sandbox/build-agent-image.sh
sudo agent-vm --image localhost/nixos-agent:latest --docker -- ./test.sh
```

`--docker` starts `dockerd` inside the guest with host networking.  The
included image wraps `docker run`/`create` with `--network host`; container
traffic therefore follows the same host firewall as the sandbox.  Container
port publishing (`docker run -p`) is not available — publish the guest port
with `agent-vm --port` instead.

## From the web and iOS apps

The API exposes the sandbox inventory when `mySandbox` and `nixos-control` are
enabled together:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/sandboxes` | Inventory, status, ports, shares and roots |
| `POST` | `/api/sandboxes` | Create and start a sandbox; returns a job |
| `GET` | `/api/sandboxes/{name}/logs?lines=200` | Runtime log |
| `POST` | `/api/sandboxes/{name}/{action}` | `start`, `stop`, `restart`, `remove` |

The web console has a **Sandboxes** section, and the iOS app has a
**Sandboxes** tab with a create sheet, start/stop/restart/remove actions and a
log viewer. Create requests may only use a workspace name below the workspace
root; the directory is created and owned by the workspace-root owner. Shared
folders must already exist below the share root. The CLI is still the way to
mount an arbitrary project directory or share.

`start` replays the original command saved with the sandbox. `stop` keeps the
VM definition, workspace and command; `remove` deletes the VM definition but
leaves the workspace files.

## Verify

```bash
sudo ./scripts/sandbox-smoke-test.sh
```

The test asserts:

1. the workspace file is visible in an offline guest;
2. the offline guest cannot reach the host gateway or the internet;
3. the host reaches a published guest port;
4. an online guest reaches the internet but not the host or a peer sandbox;
5. two sandboxes exchange a file only through one explicit share;
6. a workspace in use and a published port in use are refused;
7. `dockerd` starts inside the guest when the agent image exists.

## Design notes

### Separate kernel

`krunvm` boots a `libkrun` microVM with `libkrunfw`'s kernel.  The guest root
is an OCI image; the only host path it sees is the mounted workspace and the
extra shares.  The guest root user is not host root.

### Separate network namespace

The VMM process runs under `ip netns exec`.  libkrun's TSI networking executes
the guest's socket syscalls in the namespace, so the namespace's routing and
the host firewall decide where the guest can go.

Each sandbox gets:

```text
host: 10.213.<idx>.1/30  ── veth ──  10.213.<idx>.2/30 : VMM netns
```

The nftables table `inet agent_vm` is regenerated from the state files after
every start and stop:

- `input`: accept established replies from a sandbox, drop new connections;
- `forward`: drop sandbox→sandbox, drop private ranges for internet-only
  sandboxes, accept `--online` egress, drop offline egress;
- `postrouting`: masquerade guest sources.

The host→guest direction is not filtered: a host process can connect to the
veth address or a published port.  That asymmetry is the point.

### Why no `--online` DNAT

libkrun's port map publishes a listener in the VMM's network namespace.  A host
`nft` DNAT into that namespace inherits the host's loopback source address,
which the guest kernel treats as a martian.  The implementation avoids the
problem entirely: the host binds a proxy (`socat`) and connects to the guest
as a routed client from `10.213.<idx>.1`.  This also works when the guest
service bound only `127.0.0.1`.

## Troubleshooting

### `agent-vm: refusing to expose / to a guest`

Run from a project directory, or pass `--workspace DIR`.  The default is
`$PWD`.

### `host port N is already in use`

Something already listens on that port in the host namespace.  Pick another
port, or stop the other sandbox with `agent-vm stop NAME`.

### `workspace ... is already used by sandbox ...`

Another running sandbox owns that directory.  Stop it, use a copy, or use
`--share` if sharing is intended.

### `no free sandbox slot`

254 sandboxes have an allocated index.  `agent-vm list` shows stopped ones;
`agent-vm rm NAME` frees the slot.

### Online egress fails

Check `net.ipv4.ip_forward` and the host firewall.  `nft list table inet
agent_vm` shows the live ruleset.  If `networking.firewall.filterForward` is
enabled, the NixOS forward chain can drop `10.213.0.0/16`; allow that range or
turn forwarding filtering off.  A DNS failure points at `mySandbox.dns`.

### Docker fails to start

Read `/var/log/dockerd.log` inside the guest, or run the sandbox in the
foreground.  If overlayfs is unavailable on the guest root, retry with:

```bash
sudo agent-vm --docker --env AGENT_DOCKER_STORAGE_DRIVER=vfs -- ./test.sh
```

### A sandbox is listed as running but no process exists

```bash
sudo agent-vm gc
```

It removes stale namespaces and states after a crash or reboot.

## Limits

- MicroVM, not a confidential VM: the boundary is KVM plus the guest kernel.
- Workspace and shares are read-write; keep backups. Nothing quotas the shared
  filesystem, so an agent can fill the host disk through its workspace.
- TCP publishing only.
- IPv4 only inside the sandbox network.
- No `exec` into a live sandbox; use ports, logs or the foreground console.
- Published listeners are loopback-only unless you use `--publish`.
