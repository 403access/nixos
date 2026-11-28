---
title: Agent sandboxes
sidebar_position: 6
description: Run untrusted agents and Docker containers in KVM microVMs that cannot reach the host.
---

# Agent sandboxes

`mySandbox` is a small NixOS module for running untrusted agents — and the
Docker containers those agents start — inside KVM microVMs instead of on the
host kernel.

Each sandbox has:

- its **own Linux kernel** through `libkrun`/`krunvm`,
- its **own network namespace** with a point-to-point link to the host,
- **one workspace** and any explicitly shared folders,
- **no access to the host, the LAN or another sandbox** unless you grant it.

The host keeps the upper hand: it can reach published guest ports and the
guest IP, and it can stop the sandbox at any time.

```text
   host  ────── published ports / guest IP ──────►  sandbox
   host  ◄───── new connections dropped ──────────  sandbox
   sandbox A  ◄──── dropped ────►  sandbox B
```

## Why a microVM

Docker isolates namespaces and cgroups on the **same kernel** as the host.  A
kernel bug, a leaked socket, or a careless `--privileged` flag is enough to
cross the boundary.  A microVM adds a hypervisor boundary and a separate guest
kernel, so guest root is not host root.

| | Docker container | `agent-vm` microVM |
| --- | --- | --- |
| Kernel exploit | host compromised | guest only |
| Host `/proc`, `/sys`, ZFS | visible if mounted | not visible |
| Docker daemon | often leaked | none in the guest |
| Host loopback | shared | separate namespace |
| Sandbox to sandbox | same bridge | dropped by the firewall |
| Default network | bridge, often LAN-wide | offline |

## Enable it

```nix
mySandbox = {
  enable = true;
  user = "nixos";
  cpus = 4;                 # default, max 8
  memory = 4096;            # MiB, max 16384
  image = "docker.io/library/debian:bookworm-slim";
};
```

The module installs `agent-vm`, `krunvm`, `buildah`, `nftables`, `iproute2`
and `socat`, enables IPv4 forwarding for guest egress, and creates the
workspace, share and state directories.

## Run an agent

```bash
cd ~/src/project
sudo agent-vm

# one-shot and throw the VM away
sudo agent-vm --ephemeral -- python3 -m pytest

# internet, but no host and no LAN
sudo agent-vm --online -- npm ci

# a server the host can reach on 127.0.0.1:8080
sudo agent-vm --name web --detach --port 8080:8080 -- my-server
sudo agent-vm logs web
sudo agent-vm stop web
```

The current directory is mounted at `/workspace`.  A running workspace belongs
to exactly one sandbox; a second sandbox that points at it is refused.

`sudo agent-vm list` shows running and stopped sandboxes, their images,
published ports and shares.

## Shared folders

Use `--share` when the agent needs something outside the workspace, or when
two sandboxes should exchange files:

```bash
# /srv/docs -> /share-docs, read-only
sudo agent-vm --share /srv/docs:ro

# /srv/team -> /share-team, read-write
sudo agent-vm --share team=/srv/team
```

The host filesystem is the broker.  Sandbox A and sandbox B share a folder by
being given the same path; they still cannot mount each other's filesystem and
their network path to each other stays blocked.

:::warning
The VMM runs as root to mount the OCI rootfs. Inside a read-write workspace or
share, guest root can create files owned by host root and set mode bits. Do not
execute files from an agent workspace as a privileged host user, and use
`--share ...:ro` for host-provided inputs. Keep a dedicated workspace dataset
mounted with `nosuid` and `devices=off` where possible.
:::

## Network rules

| Traffic | Result |
| --- | --- |
| Guest → internet, `--online` | allowed through host NAT |
| Guest → private ranges, `--online` | dropped |
| Guest → anything, `--offline` | dropped |
| Guest → host, any address | dropped |
| Guest A → guest B | dropped |
| Host → published port | allowed |
| Host → guest IP | allowed |

`--lan` widens `--online` to private ranges for the rare case that needs it.
The host itself is still unreachable.  IPv6 is disabled inside the sandbox
namespace, so a dual-stack host cannot leak through `::1`.

Published ports are proxied by the host, not DNAT'd from a loopback source.
`--port H:G` listens on `127.0.0.1:H`; `--publish 0.0.0.0:H:G` listens on all
interfaces.  Ports are TCP only.

## Docker inside a sandbox

The guest is an OCI image with its own kernel, so it can run a container
runtime.  The repository includes an agent image with Docker and common
tooling:

```bash
sudo ./sandbox/build-agent-image.sh
sudo agent-vm --image localhost/nixos-agent:latest --docker -- ./test.sh
```

`--docker` starts `dockerd` in the guest with `--bridge=none` and iptables
disabled.  The image's `docker` wrapper uses `--network host` for containers,
so container traffic follows the sandbox's own network policy.  Container
port publishing is not available; publish the guest port with `--port`.

No Docker socket, image or process from the guest is visible to the host or to
another sandbox.

## From the web and iOS apps

The web console has a **Sandboxes** section and the iOS app has a **Sandboxes**
tab. Both list running and stopped sandboxes, show their image, workspace,
network mode, ports and shared folders, and let you create, start, stop,
restart, remove and read logs without opening a terminal.

Create requests use a workspace name below the configured workspace root; the
API creates the directory. The CLI is still the way to mount an existing
project directory outside that root, or to use arbitrary host shares.

`start` replays the command that was saved with the sandbox. `stop` keeps the
VM and workspace for later; `remove` deletes the VM but keeps the workspace.

## Verify

```bash
sudo ./scripts/sandbox-smoke-test.sh
```

The smoke test checks the workspace mount, offline isolation, host access to a
published port, the online-but-not-host case, peer isolation, an explicit
cross-sandbox share, workspace and port ownership, and Docker-in-sandbox when
the agent image is present.

## Limits

- KVM microVM, not a confidential VM; the boundary is the hypervisor plus the
  guest kernel.
- Workspace and shares are read-write by design.
- TCP publishing only; IPv4 only inside the sandbox.
- No `exec` into a live sandbox; use published ports, logs, or the foreground
  console.
- `--online` is still network access.  Treat the agent as an untrusted client
  for that run, and keep `--lan` for cases that need it.

The full operator guide, threat model and troubleshooting notes live in
[`docs/sandbox.md`](https://github.com/403access/nixos/blob/main/docs/sandbox.md)
and [`sandbox/README.md`](https://github.com/403access/nixos/blob/main/sandbox/README.md).
