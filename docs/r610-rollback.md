# R610 rollback

Keep a known-good boot. This branch must never overwrite the only working
kernel entry, unload the live NVIDIA module, or `modprobe` a freshly built
`.ko` without an explicit operator flag.

## What is safe without extra flags

| Action | Safe? |
|---|---|
| `bash tests/run.sh` | yes |
| `git apply` in a throwaway tree | yes |
| Podman `make modules` with headers bind-mounted | yes (`modinfo` file-only) |
| `scripts/preflight-r610.sh` | yes (read-only) |
| `scripts/status-r610.sh` | yes (read-only) |
| `scripts/install-r610.sh` (default) | yes (dry-run) |
| `scripts/remove-r610.sh` (default) | yes (dry-run) |
| `diag/r610/01`–`04` | only after a human has loaded a driver; still no module swap |
| `diag/r610/05`–`07` | **no** unless `I_ACCEPT_HOST_FREEZE_RISK=1` |

## Scripts

```
scripts/preflight-r610.sh     # read-only checks
scripts/install-r610.sh       # default dry-run; never loads modules
scripts/remove-r610.sh        # default dry-run; never unloads modules
scripts/status-r610.sh        # r610-specific read-only view + status.sh
```

`install-r610.sh --apply` runs Layer 1 only:

- `apply.sh --no-act` unless `--apply` (then real Layer 1)
- always `--skip-cmdline` on Fedora 44 + 7.1 (known-good `iommu=pt`)
- always `--skip-icd` when an internal NVIDIA GPU is present
- never installs `nvidia-driver-injector-compute-only.conf` when an
  internal NVIDIA GPU is present (no blacklist / `modeset=0`)

It **will not** `modprobe`/`insmod`. `--load-module` is rejected unless
`--i-accept-host-kernel-risk` is also passed, and even then the script
prints the five-point gate and **exits 78** — it does not execute the
load. A human must run the load command.

On this dual-GPU workstation, Layer 1 keeps RTX 2070 graphics (nvidia /
nvidia_modeset / nvidia_drm / ICDs enabled). The 5090 stays compute-only
via HDMI-audio unbind (`10de:22e8`), D3cold protection, and in-driver
A2/A3 recovery gated to `10de:2b85`. `RmForceExternalGpu` is not used.

`remove-r610.sh` will not `rmmod` or revert cmdline unless the matching
danger flags are passed; `--revert-cmdline` still prints the five-point
gate and refuses to run `grubby` without
`--i-accept-host-kernel-risk`.

## Restore stock 610.57.04

The reference workstation already runs NVIDIA userspace **610.57.04** from
Fedora/RPM. If a patched module is later loaded:

1. Stop Layer 3 consumers (`fuser /dev/nvidia*`).
2. Unload via the injector `uninstall` subcommand (not this script).
3. Confirm `lsmod | grep nvidia` is empty.
4. Restore the previously working module path (RPM Fusion / stock
   `nvidia.ko` 610.57.04).
5. Do **not** mix an R595 `.ko` with R610 userspace.

If the host becomes unbootable, pick the last known-good `7.1.10-200.fc44`
entry in GRUB — `install-r610.sh` does not create or delete boot entries.

## Five-point gate (any live-kernel step)

Print and wait for a human:

1. exact command
2. expected effect
3. rollback command
4. risk
5. verification step
