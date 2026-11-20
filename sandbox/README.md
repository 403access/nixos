# Agent sandbox

Run untrusted agents in a **KVM microVM**, not in a shared-kernel container.
Each sandbox boots its own Linux kernel through `libkrun`/`krunvm`, so a
process inside cannot see the host `/proc`, `/sys`, the ZFS pool, the libvirt
disks or the Docker daemon.

## Why not plain Docker

Docker isolates namespaces and cgroups on the **same kernel** as the host. A
kernel bug, a mounted socket, or one careless `--privileged`/`-v /` undoes the
boundary. A microVM has a separate kernel and a hypervisor boundary; the guest
root user is not host root.

| Threat | Docker container | `agent-vm` microVM |
| --- | --- | --- |
| Kernel exploit | host compromised | guest only |
| `/mnt/tank` visible | if mounted | never, unless you mount it |
| Docker socket | often leaked | no daemon in the guest |
| Host network | bridge, often LAN-wide | **offline by default** |
| Escape cost | kernel bug | hypervisor + kernel bug |

## Usage

```bash
cd ~/src/my-project
sudo agent-vm --cpus 4 --mem 4096
sudo agent-vm --ephemeral -- python3 -m pytest
sudo agent-vm --image docker.io/library/node:22 -- npm test
```

- The current directory is exposed read-write at `/workspace`.
- The guest is **offline by default** (the VMM runs in an empty network
  namespace). Pass `--online` only when the agent must download packages, and
  `--port 8080:8080` (implies `--online`) to publish a port.
- `--ephemeral` deletes the microVM when the command exits.
- `sudo agent-vm list` and `sudo agent-vm rm NAME` manage kept VMs.

Sensitive host paths (`/`, `/etc`, `/boot`, `/nix`, `/root`, `/mnt/tank`,
`/var/lib/libvirt`, `/var/lib/docker`) are refused as workspaces.

## Configuration

```nix
mySandbox = {
  enable = true;
  user = "nixos";
  cpus = 4;                 # default per sandbox, max 8
  memory = 4096;            # MiB, max 16384
  image = "docker.io/library/debian:bookworm-slim";
  workspaceRoot = "/var/lib/agent-workspaces";
};
```

`agent-vm` needs root for KVM and for buildah to mount the image. It is
installed as a store script and validates its arguments; there is no
passwordless sudo rule by default. Add one only if you accept that the user
can start arbitrary OCI images inside the VM boundary.

## Limits

- `libkrun` is a Type-2-style VMM; the security boundary is KVM plus the
  guest kernel, not a TPM-measured confidential VM. For stronger isolation you
  would move to `cloud-hypervisor` or Firecracker with a minimal rootfs.
- The workspace is read-write by design: an agent can delete project files,
  just not touch the rest of the host. Keep backups and per-task copies.
- With `--online`, the guest uses libkrun's host socket passthrough. It may
  reach services the host can reach. Treat the agent as an untrusted network
  client for that run, or keep it offline.
- Images are pulled with buildah as root; only use registries you trust.

## Related

Project services use Docker (`myServices`) with per-project networks and no
docker-group membership. The two modules are independent on purpose: a
compromised service container must not become an agent sandbox escape, and
vice versa.