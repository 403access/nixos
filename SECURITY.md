# Security notes

Known exposures on `nixos` and the decisions taken about them. Nothing in this
file changes behaviour; it records what is open, why, and how to close it.

Last reviewed: **2026-11-20** (from `scripts/zfs-audit.sh` on the live host).

## Accepted risks (left unchanged on purpose)

### Samba exposes `/` and `tank` read-write

`testparm -s` on the host:

```text
[root]
    force user = nixos
    path = /
    read only = No

[tank]
    force user = root
    path = /mnt/tank
    read only = No
```

Why this is dangerous:

- `[root]` lets any authenticated SMB user write **anywhere**, including
  `/etc`, `/nix` and `/boot`. Writes are performed as `nixos`, which is in
  `wheel`, so file ownership checks do not help.
- `[tank]` runs writes as **root**, bypassing all ownership and permission
  checks on the data that matters most.
- `services.samba.openFirewall = true` publishes 139/445 to the whole LAN.
- Samba reports `Weak crypto is allowed by GnuTLS (e.g. NTLM as a
  compatibility fallback)`.
- The account password is still the repository placeholder unless it has been
  changed with `passwd`.

**Decision:** leave the shares unchanged for now, documented here. Revisit
before adding more users, before exposing the machine beyond the LAN, and
before enabling Docker or agents that bind ports.

**Remediation when wanted** (`configuration.nix`, `services.samba.settings`):

```nix
# Remove the whole "root" share.
"tank" = {
  path = "/mnt/tank";
  browseable = "yes";
  "read only" = "no";
  "guest ok" = "no";
  "valid users" = "nixos";   # no anonymous, no other accounts
  "force user" = "nixos";    # never root
};
```

Then rebuild. Verify with `testparm -s` and
`smbclient -L localhost -U nixos`.

### SSH password login

`services.openssh.settings.PasswordAuthentication = true`, port 22 open.
Root login is key-only (`PermitRootLogin = prohibit-password`), but the
desktop account is still brute-forceable.

**Decision:** unchanged. Close it when you have keys everywhere:

```nix
services.openssh.settings.PasswordAuthentication = false;
```

### Peripherals API is CORS-readable and the web UI stores its token

`GET /api/peripherals` and `/api/health` send
`Access-Control-Allow-Origin: *` so the standalone `peripherals-ui` dashboard
can read them from any desktop. Both routes still require the bearer token.

The dashboard stores that token in the browser's `localStorage`, so use a
trusted browser profile and serve the dashboard from a trusted origin. The
route is read-only: it cannot send input, pair devices or write firmware.

**Decision:** accepted. The alternative is to serve the dashboard from the same
origin as the API or put it behind a reverse proxy; use that if the browser
profile is shared. See [`docs/peripherals.md`](docs/peripherals.md).

### xrdp and the firewall

`xrdp` listens on `*:3389`, and `networking.firewall.allowedTCPPorts` includes
`3389` and `3000`. RDP is reachable from the whole LAN.

**Decision:** unchanged. Prefer reaching it through Tailscale and removing
3389 from `allowedTCPPorts` when you no longer need direct LAN RDP.

### `tank` is not encrypted

`zfs get encryption tank` reports `off`; the `encryption` pool feature is
enabled but unused. Data at rest on the two HDDs is readable by anyone who
removes a disk.

This cannot be enabled on an existing dataset. The safe migration is:

1. `zfs create -o encryption=on -o keyformat=passphrase tank/encrypted`
2. `rsync`/`zfs send` the data into it, verify checksums.
3. Delete the plaintext copy **only after** the encrypted copy is verified
   and backed up.

**Decision:** unchanged; no space for a second full copy today (81% used).

## Agent sandboxes

`mySandbox` is deliberately asymmetric and root-run:

- `agent-vm` needs root for KVM, network namespaces, nftables and buildah.
  There is no passwordless sudo rule by default; adding one grants the user
  the ability to boot arbitrary OCI images inside the VM boundary.
- The host can reach a sandbox (published ports and the guest IP by design).
  A sandbox cannot initiate a connection to the host, the LAN or another
  sandbox. New connections to host addresses, including `127.0.0.1`, are
  dropped in the `inet agent_vm` nftables table.
- Workspaces and `--share` folders are read-write. A compromised agent can
  delete project files; it cannot write elsewhere on the host. Keep backups.
- The web/iOS sandbox API can create VMs and execute arbitrary commands inside
  them. The bearer token is therefore root-equivalent for this feature too.
  API-created workspaces are confined to the `mySandbox` workspace root and
  shares to the share root; use the CLI for other host paths.
- Images are pulled by root buildah. Use only trusted registries.
- This is a KVM microVM, not a confidential VM: the boundary is the hypervisor
  plus the guest kernel.

See [`docs/sandbox.md`](docs/sandbox.md) and
[`sandbox/README.md`](sandbox/README.md) for the full model.

## Not a risk, but worth knowing

- `/etc/nixos` is **not** a git checkout. Pulling the GitHub repo into
  `~/Desktop/nixos` changes nothing until the files are deployed to
  `/etc/nixos` and `nixos-rebuild switch` runs.
- `/dev/sdc` (465 GB) is unformatted and unused.
- The pool is at 81% capacity; ZFS performance and snapshot headroom both
  degrade above ~80%.

## Related

- Offsite backup gap: [`../docs/backup.md`](../docs/backup.md)
- Installer ZFS guard: [`../install/README.md`](../install/README.md)