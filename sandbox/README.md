# Agent sandbox

Run untrusted agents and their containers in a **KVM microVM**, not in a
shared-kernel container.  Each sandbox boots its own Linux kernel through
`libkrun`/`krunvm` and runs its VMM in a **dedicated network namespace**, so a
process inside cannot see the host `/proc`, `/sys`, the ZFS pool, the libvirt
disks, the Docker daemon, or another sandbox.

The network rule is deliberately asymmetric:

```text
   host  ────── published ports, guest IP ──────►  sandbox
   host  ◄───── blocked (new connections) ───────  sandbox
   sandbox A  ◄──── blocked ────►  sandbox B
```

Only explicitly shared host folders break the file boundary, and only
explicitly published ports break the network boundary.

## Why not plain Docker

Docker isolates namespaces and cgroups on the **same kernel** as the host.  A
kernel bug, a mounted socket, or one careless `--privileged`/`-v /` undoes the
boundary.  A microVM has a separate kernel and a hypervisor boundary; the guest
root user is not host root.

| Threat | Docker container | `agent-vm` microVM |
| --- | --- | --- |
| Kernel exploit | host compromised | guest only |
| `/mnt/tank` visible | if mounted | never, unless shared |
| Docker socket | often leaked | no daemon in the guest unless you add one |
| Host loopback | shared | separate network namespace |
| Sandbox-to-sandbox | same bridge | dropped by the host firewall |
| Host network | bridge, often LAN-wide | offline by default |
| Escape cost | kernel bug | hypervisor + kernel bug |

## Usage

```bash
cd ~/src/my-project
sudo agent-vm --cpus 4 --mem 4096

# One-shot command, deleted afterwards
sudo agent-vm --ephemeral -- python3 -m pytest

# A server, reachable by the host on 127.0.0.1:8080
sudo agent-vm --name web --detach --port 8080:8080 -- my-server
sudo agent-vm logs web
sudo agent-vm stop web

# Internet access, but not the host or the LAN
sudo agent-vm --online -- npm install

# Extra folders, read-only and read-write
sudo agent-vm --share docs=/srv/docs:ro --share team=/srv/team
```

- The current directory is exposed read-write at `/workspace`.
- A workspace can only be used by one running sandbox.  Use `--share` if two
  sandboxes should see the same folder.
- `--port H:G` publishes guest TCP port `G` on `127.0.0.1:H`.
  `--publish 0.0.0.0:H:G` publishes on all host interfaces.  The module does
  not open `networking.firewall`; add the port yourself if you publish beyond
  loopback.
- `--detach` leaves the sandbox running; `sudo agent-vm list` shows it.
- `--ephemeral` deletes the microVM when the command exits.
- `sudo agent-vm gc` removes state for VMs that no longer exist.

Sensitive host paths (`/`, `/etc`, `/boot`, `/nix`, `/root`, `/mnt/tank`,
`/var/lib/libvirt`, `/var/lib/docker`, `/proc`, `/sys`, `/dev`,
`/var/lib/agent-vm`) are refused as workspaces or shares.

## Networking model

Each sandbox gets a `/30` link:

```text
host: 10.213.<idx>.1/30  ── veth ──  10.213.<idx>.2/30 : guest VMM netns
```

The VMM process itself runs inside that namespace, so libkrun's TSI socket
passthrough executes its `connect()` calls in the namespace, not on the host.
The host nftables table (`inet agent_vm`, regenerated from state after every
start/stop) then enforces:

| Traffic | Result |
| --- | --- |
| guest → internet, `--online` | allowed through host NAT |
| guest → private/CGNAT/link-local, `--online` | dropped |
| guest → internet or LAN, `--offline` | dropped |
| guest → host (any address, including `127.0.0.1`) | dropped |
| guest A → guest B | dropped |
| host → guest, published port | allowed |
| host → guest, guest IP | allowed |
| host → guest, reply to an existing connection | allowed |

`--online` is internet-only on purpose.  Add `--lan` if the sandbox really
needs private-range access; the host itself remains unreachable.  IPv6 is
disabled inside the sandbox network namespace, so a dual-stack host cannot
leak through `::1` or a global IPv6 address.

Published ports are proxied by the host, not DNAT'd from a host loopback
source.  A host-side `socat` listens on the requested address and connects to
the sandbox as a normal routed client; a second `socat` inside the namespace
exposes the TSI listener on the veth address.  This keeps loopback source
addresses out of the guest and works whether the guest service bound
`0.0.0.0` or `127.0.0.1`.

The host is expected to reach the sandbox; that is why the guest IP and its
published ports are reachable from the host.  A process inside the sandbox has
no allowed path back in the other direction.

## Shared folders

- `--workspace DIR` → `/workspace` (read-write, exclusive while running).
- `--share PATH` → `/share-<basename>` (read-write).
- `--share NAME=PATH` → `/share-NAME`.

krunvm only accepts a single root child as a guest path, so shares are
`/share-NAME` rather than a nested `/shares/NAME` directory.
- `--share PATH:ro` → read-only bind; krunvm sees a read-only mount.

Giving the same host path to two sandboxes is the only supported way for
sandbox A and sandbox B to exchange files.  The broker is still the host
filesystem: neither sandbox mounts the other's filesystem, and their only
network path to each other is dropped.

### Shared-folder caveat

The VMM runs as root to mount the OCI rootfs.  Within a read-write workspace or
share, guest root can therefore create files owned by host root and set file
mode bits.  Do not execute files from an agent workspace as a privileged host
user, and do not point `--workspace` at a directory whose contents you trust.
For host-provided inputs, use `--share ...:ro`.  A dedicated workspace root on
a ZFS dataset mounted with `nosuid` and `devices=off` keeps the blast radius
small; keep secrets and other users' files out of shared folders.

## Docker inside a sandbox

The guest is an OCI image with its own kernel, so it can run a container
runtime.  Build the included agent image once, as root, so krunvm's buildah can
see it:

```bash
sudo ./sandbox/build-agent-image.sh
sudo agent-vm --image localhost/nixos-agent:latest --docker -- ./run-tests.sh
```

`--docker` starts `dockerd` in the guest before the command with
`--iptables=false --ip6tables=false --bridge=none`.  The image ships a `docker`
wrapper that adds `--network host` to `docker run`/`docker create`, so
containers share the guest network, which the host firewall already confines.
No Docker socket, network or process from the guest is visible to the host or
to another sandbox.

If `dockerd` cannot use `overlay2` on the guest root, pass a different driver:

```bash
sudo agent-vm --image localhost/nixos-agent:latest --docker \
  --env AGENT_DOCKER_STORAGE_DRIVER=vfs -- ./run-tests.sh
```

Container port publishing (`docker run -p`) is not available; publish the
guest port instead with `agent-vm --port`.

## Configuration

```nix
mySandbox = {
  enable = true;
  user = "nixos";
  cpus = 4;                 # default per sandbox, max 8
  memory = 4096;            # MiB, max 16384
  image = "docker.io/library/debian:bookworm-slim";
  dns = "1.1.1.1";
  workspaceRoot = "/var/lib/agent-workspaces";
  sharedRoot = "/var/lib/agent-shares";
  stateRoot = "/var/lib/agent-vm";
};
```

The module installs `agent-vm`, `krunvm`, `buildah`, `nftables`, `iproute2`
and `socat`, enables IPv4 forwarding for guest egress, creates the workspace,
share and state directories, and provides the buildah signature policy.

`agent-vm` needs root for KVM, network namespaces, nftables and for buildah to
mount the image.  It is installed as a store script and validates its
arguments; there is no passwordless sudo rule by default.  Add one only if you
accept that the user can start arbitrary OCI images inside the VM boundary.

## Verify

```bash
sudo ./scripts/sandbox-smoke-test.sh
```

It checks the workspace mount, offline isolation, host→published-port access,
the online-but-not-host case, peer isolation, an explicit cross-sandbox share,
workspace and port ownership, and Docker-in-sandbox when the agent image is
present.

## Limits

- `libkrun` is a Type-2-style VMM; the security boundary is KVM plus the guest
  kernel, not a TPM-measured confidential VM.  For stronger isolation, move to
  `cloud-hypervisor` or Firecracker with a minimal rootfs.
- The workspace and shares are read-write by design: an agent can delete
  project files, just not touch the rest of the host.  Keep backups and
  per-task copies.  Nothing quotas the shared filesystem, so an agent can also
  fill the host disk through its workspace; use a dedicated dataset/quota if
  that matters.
- Published ports are TCP only; libkrun's port map does not forward UDP.
- `--online` gives internet egress.  Treat the agent as an untrusted network
  client for that run; `--lan` widens that to private networks.
- Images are pulled with buildah as root; only use registries you trust.
- There is no `exec` into a running sandbox.  Use a published port, the
  foreground console, or `agent-vm logs NAME` for detached runs.
- The host can reach the sandbox by design.  Do not run untrusted host
  processes with access to the sandbox network if you do not trust that
  direction.

## Related

Project services use Docker (`myServices`) with per-project networks and no
docker-group membership.  The two modules are independent on purpose: a
compromised service container must not become an agent sandbox escape, and
vice versa.
