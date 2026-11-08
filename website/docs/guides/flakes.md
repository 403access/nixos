---
title: Flakes
sidebar_position: 3
description: Use NixOS Control with a flake-based NixOS configuration.
---

# Flakes

The current `configuration.nix` in the repository is channel-based, so the
default `nixos-rebuild switch` is used. If you migrate to flakes, set the flake
reference:

```nix
services.nixos-control.flake = "/etc/nixos#nixos";
```

With a git-backed flake, make sure `server/` and `nixos-control.nix` are tracked
(`git add`), otherwise Nix will not see them.

## Rebuild behaviour

| `flake` value | Command |
| --- | --- |
| `null` (default) | `nixos-rebuild <action>` |
| `"/etc/nixos#nixos"` | `nixos-rebuild <action> --flake /etc/nixos#nixos` |

Supported actions are `switch`, `boot`, `test`, `dry-activate`, and
`dry-build`. The job runs asynchronously; the app polls the job endpoint for
output and can cancel it.

## Channel-based NIX_PATH

For channel-based systems, `NIX_PATH` is passed through from
`config.nix.nixPath`, so rebuilds see the same channels as a manual command.
