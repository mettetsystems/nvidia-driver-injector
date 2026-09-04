# R610 build baseline

**Branch:** `r610-linux-7.1`
**Date:** 2026-09-03 / 2026-09-04
**Host kernel:** `7.1.10-200.fc44.x86_64`
**NVIDIA tag:** `610.57.04` (`e4a5faa2567f28c8eabe0ebb6422b6d0abcf37eb`)
**Compiler in build container:** gcc 16.2.1 (Fedora 44)

Neither the stock nor the patched module was loaded. `modinfo` below is
file-only.

## Host toolchain note

The workstation has gcc 16.2.1 but **no g++**. `dnf install gcc-c++` needs a
real root. Phase 0/3 used a **rootless Podman** `fedora:44` container with
host kernel headers bind-mounted. Missing host `g++` is a toolchain gap, not
a Linux 7.1 API break.

## Stock 610.57.04 (`make modules`)

Worktree: `/tmp/ogkm-610.57.04-baseline`

```
podman run --rm \
  -v /tmp/ogkm-610.57.04-baseline:/src:Z \
  -v /usr/src/kernels/7.1.10-200.fc44.x86_64:/usr/src/kernels/7.1.10-200.fc44.x86_64:ro \
  -v /lib/modules/7.1.10-200.fc44.x86_64:/lib/modules/7.1.10-200.fc44.x86_64:ro \
  fedora:44 \
  bash -lc 'dnf install -y gcc gcc-c++ make elfutils-libelf-devel openssl-devel xz flex bison python3 binutils &&
    cd /src && make modules SYSSRC=/lib/modules/7.1.10-200.fc44.x86_64/build \
      KERNEL_UNAME=7.1.10-200.fc44.x86_64 -j$(nproc) IGNORE_CC_MISMATCH=1'
```

| Artifact | Result |
|---|---|
| `nvidia.ko` | built |
| `nvidia-uvm.ko` | built |
| `nvidia-modeset.ko` | built |
| `nvidia-drm.ko` | built |
| `modinfo version` | `610.57.04` |
| `vermagic` | `7.1.10-200.fc44.x86_64 SMP preempt mod_unload` |

**PASS.** Unmodified NVIDIA 610.57.04 compiles against Linux 7.1.10 headers.
objtool `naked return` warnings are upstream noise, not a hard fail.

## Patched 610.57.04 + 19-patch set

Worktree: `/tmp/ogkm-610-clean-apply` (vanilla tag + manifest apply order).

`git apply` of all 19 production patches: **ok=19 fail=0**.

Same Podman `make modules` command as stock, targeting the patched tree.

| Artifact | Result |
|---|---|
| `nvidia.ko` | built (`LD` + `BTF`) |
| `nvidia-uvm.ko` | built |
| `nvidia-modeset.ko` | built |
| `nvidia-drm.ko` | built |
| `nvidia-peermem.ko` | built |
| `modinfo version` | `610.57.04-apnex.1` |
| `vermagic` | `7.1.10-200.fc44.x86_64 SMP preempt mod_unload` |
| exit code | 0 |

**PASS.** Milestone A compile gate.

## Not done (requires human approval)

- `insmod` / `modprobe` of either `.ko`
- replacing the running RPM Fusion / stock 610.57.04 module
- CUDA Stage 4B / pinned-memory tests
- bootloader or Secure Boot changes
