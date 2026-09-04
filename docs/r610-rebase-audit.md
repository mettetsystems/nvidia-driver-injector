# R610 rebase audit

**Status:** Milestone A (source rebase + patched compile) complete. Do **not** load the patched module without a human gate — see [`r610-rollback.md`](r610-rollback.md).
**Branch:** `r610-linux-7.1`
**Date:** 2026-09-03
**Vanilla trees compared:**

| Tag | Commit | Path |
|---|---|---|
| `595.71.05` | `51edebee79919b54f498c19a0be31982cd97646e` | `/tmp/ogkm-595.71.05-baseline` |
| `610.57.04` | `e4a5faa2567f28c8eabe0ebb6422b6d0abcf37eb` | `/tmp/ogkm-610.57.04-baseline` |

This audit does **not** authorise loading a module, changing the host bootloader, or running CUDA stress tests.

---

## 1. Where `NVIDIA_OPEN_TAG` is defined

**Authoritative pin:** `nvidia-version.env` (`NVIDIA_OPEN_TAG` / `NVIDIA_DRIVER_VERSION`).
`Dockerfile` `ARG NVIDIA_OPEN_TAG` must match (enforced by `tests/test-nvidia-version.sh`).
`tools/validate-patchset.sh` and `tools/regen-base-patches.sh` default to that file
(`--tag` / `--nvidia-tag` override).

```
ARG NVIDIA_OPEN_TAG=610.57.04
ENV NVIDIA_OPEN_TAG=${NVIDIA_OPEN_TAG}
ENV NVIDIA_DRIVER_VERSION=${NVIDIA_OPEN_TAG}
```

That ARG is the image-build pin for:

1. `git clone -b ${NVIDIA_OPEN_TAG}` of `NVIDIA/open-gpu-kernel-modules`
2. `git clone -b ${NVIDIA_OPEN_TAG}` of `NVIDIA/nvidia-modprobe`
3. download of `NVIDIA-Linux-x86_64-${NVIDIA_OPEN_TAG}.run`
4. install of `nvidia-smi` and `libnvidia-ml.so.${NVIDIA_OPEN_TAG}`
5. extraction of GSP firmware blobs from the same `.run`

`entrypoint.sh` firmware install uses `${NVIDIA_OPEN_TAG}` (not a baked 595 path).
A5 stamps `610.57.04-apnex.1`. Compose / DaemonSet image tags match.

`tools/regen-base-patches.sh` **does not rebase the fork stack onto a new NVIDIA tag**. Tag-bump is a manual fork rebase, then regen.

---

## 2. Assumptions tied to NVIDIA 595.71.05

1. Every production patch was regenerated against tag `595.71.05` (`patches/base/.regen-state`).
2. GSP firmware lives at `/lib/firmware/nvidia/595.71.05/{gsp_ga10x,gsp_tu10x}.bin`.
3. Project version suffix is `595.71.05-apnex.N` (currently `.30`).
4. Userspace (`nvidia-smi`, NVML, CUDA UMD) is the matching 595.71.05 `.run`.
5. `validate-patchset.sh` / contributor docs assume a local fork at `/root/open-gpu-kernel-modules` that contains tag `595.71.05`.
6. Tested kernel range in `README.md` / `docs/install-workflow.md` is **6.19–7.0**, not 7.1.
7. Layer 1 cmdline in `scripts/apply.sh` is the NUC 15 / TB4 bring-up (`iommu=off`, `pcie_aspm.policy=performance`, `thunderbolt.clx=0`). The Fedora 44 + 7.1.10 + AORUS 5090 AI BOX reference host uses a **different known-good cmdline** (`iommu=pt`, `hpbussize=0x20`, `pcie_aspm=off`, `pcie_ports=native`, compound `pci=realloc,assign-busses,resource_alignment=35@…`). `apply.sh` must not be run against that host without `--skip-cmdline`.

---

## 3. Literal NVIDIA version locations (production surface)

Excluding mission forensics / historical session notes, the load-bearing literals are:

- `Dockerfile` — `ARG NVIDIA_OPEN_TAG=595.71.05` and comments about the 595.71.05 tarball
- `entrypoint.sh` — firmware target `595.71.05` (several sites)
- `patches/addon/A5-version-and-toggles.patch` — `version.mk` assignment
- `patches/base/C1-kbuild-version-mk.patch` — intent/comments mention the 595 literal that C1 removes
- `docker-compose.yml`, `k8s/daemonset.yaml`, `k8s/README.md`
- `docs/testing.md`, `README.md`, `docs/architecture.md` (nvidia-smi extract note)
- `docs/patch-intents/C1-kbuild-version-mk.md`, `docs/patch-intents/A5-version-and-toggles.md`

Historical `595.71.05-aorus.*` / `595.71.05-apnex.*` strings in `docs/missions/` are provenance and are left alone.

---

## 4. Patch manifest structure

`patches/manifest` columns:

```
id  layer  upstreamed_in  source
```

- `id` — file is `patches/<layer>/<id>.patch`
- `layer` — `base` (C/E, upstream-bound) or `addon` (A, project-local)
- `upstreamed_in` — `-` still needed; else the NVIDIA tag that absorbed it
- `source` — `fork:<branch>` for every row
- **Row order = apply order**

Lint: `tools/lib/manifest.sh` (`manifest_lint`). Compose: `tools/compose-patchset.sh`. Regen: `tools/regen-base-patches.sh` (requires a fork whose stacked branches descend from the target tag).

All 19 production rows currently have `upstreamed_in = -`.

---

## 5. Base patch order

From the manifest (applied first):

1. `C6-cond-acquire-rwlock-fix`
2. `C1-kbuild-version-mk`
3. `C2-aer-internal-unmask`
4. `C3-gpu-lost-retry`
5. `C4-err-handlers-scaffold`
6. `E1-egpu-detection`
7. `C5-crash-safety`

C6 is first because A10/A11 `COND_ACQUIRE` is unsafe until the rwsem polarity is corrected. C5 follows E1 because the crash-safety stack was carved after eGPU detection in the fork series.

---

## 6. Addon patch order

8. `A1-pcie-primitives`
9. `A2-bus-loss-watchdog`
10. `A3-recovery`
11. `A4-close-path-telemetry`
12. `A5-version-and-toggles`
13. `A6-f40b-bounded-wait-open`
14. `A7-f40b-bounded-wait-shutdown`
15. `A8-f40b-sysfs-observability`
16. `A9-egpu-probe-classify`
17. `A11-f45-deadlock-breaker`  *(before A10 on purpose)*
18. `A10-f40b-lockfree-sink`
19. `A12-init-funnel`

A12 subsumes the A6 open-path wrapper at the GSP-bootstrap funnel. A6 remains in the manifest for bisectability and because A12 deletes the A6-specific wrapper rather than rewriting A6 in place.

`patches/legacy/` and `patches/experimental/` are **not** in the production apply list.

---

## 7. Patch intent documents

Every production id has `docs/patch-intents/<id>.md` with the seven-field frontmatter required by `docs/patch-intent-schema.md`. Lint: `tools/intent-lint.sh`. Index: `docs/patch-index.md` (generated).

| ID | Intent (one line) |
|---|---|
| C6 | Correct inverted `os_cond_acquire_rwlock_{read,write}` polarity |
| C1 | `kernel-open/Kbuild` reads `NVIDIA_VERSION` from `version.mk` |
| C2 | Unmask AER internal-error bits at probe (Windows-parity, hand-rolled) |
| C3 | Retry `NV_PMC_BOOT_0` in `osHandleGpuLost` before declaring lost (#979) |
| C4 | Register `pci_error_handlers` stubs on `nv_pci_driver` |
| E1 | Detect TB4/USB4 eGPU via `pci_is_thunderbolt_attached()` / `untrusted` |
| C5 | Dead-bus crash-safety across RM / UVM / DRM / resserv |
| A1 | PCIe/AER snapshot primitives (`nv-tb-egpu-pcie`) |
| A2 | Per-device `NV_PMC_BOOT_0` heartbeat kthread (Q-watchdog / bus-loss) |
| A3 | Self-triggered `pci_reset_bus` recovery state machine |
| A4 | Close-path `[CLOSE]` telemetry |
| A5 | Project version stamp + `CONFIG_NV_TB_EGPU` |
| A6 | Bounded-wait `/dev/nvidia*` open (F40b) |
| A7 | Bounded-wait shutdown |
| A8 | Sysfs observability (`tb_egpu_*`) |
| A9 | Set `nv->is_external_gpu` at **probe**, not first open |
| A11 | F45 deadlock breaker (`COND_ACQUIRE` at adapter-status) |
| A10 | Lock-free GPU-lost sink |
| A12 | Bound every GSP-bootstrap entry (open / probe / resume / RTD3) |

---

## 8. Files touched by each production patch

| ID | Files |
|---|---|
| C6 | `kernel-open/nvidia/os-interface.c` |
| C1 | `kernel-open/Kbuild` |
| C2 | `kernel-open/nvidia/nv-pci.c` |
| C3 | `src/nvidia/arch/nvalloc/unix/src/osinit.c` |
| C4 | `kernel-open/nvidia/nv-pci.c` |
| E1 | `kernel-open/common/inc/os-interface.h`, `kernel-open/nvidia/os-pci.c`, `src/nvidia/arch/nvalloc/unix/include/os-interface.h`, `src/nvidia/arch/nvalloc/unix/src/osinit.c` |
| C5 | ~30 files: `nv.c`, `nv-pci.c`, `os-pci.c`, `os.c`, `osapi.c`, `osinit.c`, DRM/modeset, journal, GSP, graphics, resserv, new `nv-gpu-lost.h` |
| A1 | `kernel-open/nvidia/nv-tb-egpu-pcie.{c,h}`, `nvidia-sources.Kbuild` |
| A2 | `nv-linux.h`, `nv-pci.c`, `nv-tb-egpu-qwd.{c,h}`, `nvidia-sources.Kbuild` |
| A3 | `nv-linux.h`, `nv-pci.c`, `nv-tb-egpu-recover.{c,h}`, `nv.c`, `nvidia-sources.Kbuild` |
| A4 | UVM close glue, `nv-tb-egpu-close.{c,h}`, `nv.c`, both Kbuild files |
| A5 | `kernel-open/Kbuild`, `version.mk` |
| A6 | `kernel-open/nvidia/nv.c` |
| A7 | `kernel-open/nvidia/nv.c` |
| A8 | `nv-pci.c`, `nv-tb-egpu-metrics.{c,h}`, `nv.c`, `nvidia-sources.Kbuild` |
| A9 | `kernel-open/nvidia/nv-pci.c` |
| A11 | `nv.c`, `src/nvidia/arch/nvalloc/unix/src/osapi.c` |
| A10 | `nv.c`, `osapi.c` |
| A12 | `kernel-open/nvidia/nv.c` |

R610 also **drops** `kernel-open/nvidia/nv-pat.c` from `nvidia-sources.Kbuild`. Addon Kbuild hunks that insert after `nv-pat.c` will need retargeting.

---

## 9. Host-kernel compatibility assumptions

| Assumption | Current tree | R610 / 7.1.10 host |
|---|---|---|
| Kernel headers | `/lib/modules/$(uname -r)/build` bind-mounted | `7.1.10-200.fc44.x86_64` present |
| Compile-tested | 7.0.9-204.fc44 | **not yet** (Phase 0) |
| gcc in image | Debian 13 (`Dockerfile`) | Host kernel built with **gcc 16.2.1**; `IGNORE_CC_MISMATCH=1` already used |
| Host `g++` | not required (container has `build-essential`) | **missing on this workstation** (`gcc-c++` not installed; `dnf` needs a real root). Phase 0 uses a Fedora 44 Podman container |
| C2 AER helper | 7.0 `pci_aer_unmask_internal_errors()` is CXL-export-restricted | confirm 7.1 still restricted; C2 remains a hand-roll |
| Layer 1 cmdline | `iommu=off intel_iommu=off thunderbolt.host_reset=false pcie_aspm.policy=performance thunderbolt.clx=0 pcie_port_pm=off pci=resource_alignment=35@<bridge>` | Reference host: `iommu=pt hpbussize=0x20 pcie_aspm=off pcie_ports=native pcie_port_pm=off thunderbolt.host_reset=false pci=realloc,assign-busses,resource_alignment=35@0000:8c:00.0` |
| BAR1 gate | 32 GiB (`EXPECTED_BAR1_BYTES=34359738368`) | keep; do not regress |
| eGPU PCI id | `10de:2b85` (GB202) | still GB202; treat BDF as fixture |
| Dual GPU | ICD disable is **global** | RTX 2070 is the display GPU — compute-only must stay 5090-scoped |

---

## 10. Linux kernel API usage that may have changed in 7.1

Already exercised on 7.0; 7.1 is nearby but Phase 0 is the proof.

| API / pattern | Used by | 7.1 concern |
|---|---|---|
| `down_{read,write}_trylock` polarity (1=acquired) | C6 | Unchanged in practice; C6 still required (see §11) |
| `struct pci_error_handlers` (`.error_detected`, `.mmio_enabled`, `.slot_reset`, `.resume`) | C4, A3 | Confirm no new required fields |
| `pci_find_ext_capability` / raw AER config writes | C2, A1 | C2 cannot call CXL-restricted `pci_aer_unmask_internal_errors()` |
| `pci_is_thunderbolt_attached()`, `pdev->untrusted` | E1, A9 | USB4 host routers still expected to carry Intel TB VSEC |
| `kthread_run` / `kthread_stop` | A2 | — |
| `pci_reset_bus` | A3 | Does not itself dispatch `slot_reset`/`resume` — A3 still must |
| `system_long_wq` + `wait_for_completion_timeout` + `flush_work` | A6/A7/A12 | F40b join invariant |
| `sysfs_emit` | A2/A8 | — |
| Host objtool + `libelf`/`libssl` | kbuild | already documented in README |
| `-fmin-function-alignment=16` | gcc vs kernel | container gcc must be new enough |

External signal: NVIDIA issue [#1153](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1153) reports the **same** `GPPut < WATCHDOG_GPFIFO_ENTRIES` assertion on kernel **7.0.x** but not 6.19.x. Linux 7.1 sits in that window. That is a kernel-interaction hypothesis, not proof for the 5090 CUDA/pinned-memory case.

---

## 11. NVIDIA symbols that moved between R595 and R610

Direct function-body comparison (vanilla trees):

| Symbol | R595 vs R610 | Consequence |
|---|---|---|
| `osHandleGpuLost` | **identical** | C3 intent still missing upstream |
| `RmCheckForExternalGpu` | **identical** (still TB3 whitelist + surprise-hotplug) | E1 still required |
| `os_cond_acquire_rwlock_{read,write}` | **identical**, still inverted | C6 **not** upstreamed |
| `kernel-open/Kbuild` `-DNV_VERSION_STRING` | still a hardcoded literal (`610.57.04`) | C1 still required |
| `nv_pci_driver.err_handler` | still **unset** | C4 still required |
| `krcWatchdogWriteNotifierToGpfifo_IMPL` | assertion text/logic **unchanged**; file gained `#include "alloc/alloc_channel.h"` (line 1551 vs 1549) | no injector patch covers this |
| `nv-gpu-lost.h` | absent in both vanilla trees | C5 still additive |
| `nvidia-sources.Kbuild` | **dropped** `nv-pat.c` | addon Kbuild hunks may OFFSET |
| `nv-pci.c`, `nv.c`, `os.c`, `osapi.c`, `nv-linux.h` | large diffs (100–650 diff lines) | C2/C4/C5/A3/A6–A12 likely OFFSET or SEMANTIC_REWRITE |

GSP firmware **names** in `kernel-open/common/inc/nv-firmware.h` are still `gsp_ga10x` / `gsp_tu10x`. GB20X/GB10X families fall through to `gsp_ga10x.bin`. The Dockerfile extract set does not need a new blob **name**, but the **bytes** must come from the 610.57.04 `.run` (version-aligned). Firmware install path becomes `/lib/firmware/nvidia/610.57.04/`.

---

## 12. Existing eGPU watchdog / recovery implementation

**A2** (`nv-tb-egpu-qwd.c`) is a per-device kthread that reads `NV_PMC_BOOT_0` at ~5 Hz and, on `0xFFFFFFFF`, dispatches into C5’s `cleanupGpuLostStateAtomic` with detector class `NV_GPU_LOST_DETECTOR_QWATCHDOG_DMA_WEDGE`. Kill switch: `NVreg_TbEgpuQwdEnable`. Sysfs: `tb_egpu_qwd_*`.

This is **not** the NVIDIA RC/GPFIFO watchdog.

---

## 13. Existing PCI error-handler implementation

**C4** registers `pci_error_handlers` stubs (`.error_detected` returns CAN_RECOVER / DISCONNECT; `.slot_reset` / `.resume` log and return).

**A3** fills those callbacks with the recovery state machine: H1 max-attempts, H2 rate-limit, H3 enable + kill-switch file, `pci_reset_bus` from a workqueue, then **explicit** `slot_reset`/`resume` dispatch because `pci_reset_bus` does not fire them.

Vanilla R610 `nv_pci_driver` still has **no** `.err_handler`.

---

## 14. Existing GPFIFO / Q-watchdog mitigation

**None for NVIDIA RC GPFIFO.**

The name “Q-watchdog” in this repo means A2’s PMC_BOOT_0 heartbeat (legacy Lever Q). Grep of production patches for `WATCHDOG_GPFIFO_ENTRIES`, `GPPut`, and `kernel_rc_watchdog` is empty.

Observed failure:

```
NVRM: nvAssertFailedNoLog:
Assertion failed: GPPut < WATCHDOG_GPFIFO_ENTRIES
@ kernel_rc_watchdog.c:1551
NVRM: GPU at PCI:0000:8d:00
```

R610 `krcWatchdogWriteNotifierToGpfifo_IMPL` still:

1. `MEM_RD32` of `GPPut`
2. if `GPPut >= WATCHDOG_GPFIFO_ENTRIES` (4): `NV_ASSERT` then `return`
3. write a GPFIFO entry and increment PUT modulo 4

`NV_ASSERT` maps to `nvAssertFailedNoLog`. A live GPU with a stuck command queue can keep `GPPut` out of range (or the mapping can be garbage) without ever showing PMC_BOOT_0 `0xFFFFFFFF`, so **A2 will not fire**. CUDA 719 (`CUDA_ERROR_LAUNCH_FAILED`) is the userspace face of the subsequent channel kill.

Phase 4 must decide a new mitigation. Globally disabling the RC watchdog is out of scope.

---

## 15. Existing bus-loss watchdog

A2 (detection) + A3 (recovery) + C5 (sink). Module param `NVreg_TbEgpuRecoverEnable=1` is the Layer 1 production posture (`scripts/host-files/etc/modprobe.d/nvidia-driver-injector.conf`).

---

## 16. Existing compute-only behavior

| Mechanism | Scope | Dual-GPU risk |
|---|---|---|
| `install nvidia_drm /bin/false` + `options nvidia_drm modeset=0 fbdev=0` | **global** | Protects 2070 from nvidia-drm too — GNOME on 2070 must use i915/amdgpu/simpledrm, not nvidia_drm. Confirm 2070 is not the display GPU via nvidia_drm before tightening |
| Vulkan/EGL/OpenCL ICD rename in `apply.sh` | **global** | **Will break** a 2070 NVIDIA display path |
| udev `80-…-disable-audio.rules` | device `10de:22e8` only | Safe for 2070 |
| `RmForceExternalGpu=1` | **global** module param | Forces **both** GPUs onto the eGPU PM path — needs review on a 2070+5090 host |
| Entrypoint PCI/BAR1 gate | `10de:2b85` only | Correct (5090-only) |

The reference host showed gnome-shell using a few MiB on the 5090. Compute-only is therefore incomplete for this dual-GPU fixture. Do not globally disable ICDs.

---

## 17. Existing bridge-cap handling

Layer 1 systemd unit `nvidia-driver-injector-bridge-link-cap.service` (`Before=docker.service`) caps the upstream TB bridge `LnkCtl2` max-target-speed (Lever H17 / issue #979 Gen3 GSP-boot freeze). Script: `scripts/host-files/usr/local/sbin/nvidia-driver-injector-bridge-link-cap`. Discovers the GPU by `10de:2b85` then walks to the parent bridge — BDF is **not** hardcoded in the generic path. Documented in `docs/bridge-link-cap-mechanism.md`.

---

## 18. Existing BAR1 verification logic

`entrypoint.sh` step 2:

- Default `EXPECTED_BAR1_BYTES=34359738368` (32 GiB)
- Reads sysfs `resource` line 2 (BAR1)
- Fails with `EXIT_BAR1_TOO_SMALL=11` if smaller
- GPU selected by `EGPU_VENDOR_ID`/`EGPU_DEVICE_ID` (default `10de:2b85`) or `EGPU_BDF` override — **not** a hardcoded `0000:8d:00.0`

Layer 1 `apply.sh` adds `pci=resource_alignment=35@<discovered-bridge-bdf>` when it can see the 5090.

---

## Architecture preserved

```
Layer 3  Workload          (vLLM / CUDA) — independent
Layer 2  Injector image    Dockerfile + entrypoint.sh  (compose **or** k3s)
Layer 1  Host bring-up     apply.sh / remove.sh / status.sh
Layer 0  Hardware          AORUS 5090 / USB4
```

Diag (`diag/`) remains a separate image. C/E/A geometry is not collapsed.

---

## Immediate rebase implications (pre-matrix)

Nothing in the 19-patch set is obviously `FULLY_UPSTREAMED` for the symbols we compared. C6, C1, C3, C4, E1 still match their R595 vanilla baselines. The RC GPFIFO failure is **new work**, not a port of A2.

Next documents: [`r610-patch-matrix.md`](r610-patch-matrix.md) (apply-status + semantic status per patch), [`r610-build-baseline.md`](r610-build-baseline.md), [`r610-watchdog-analysis.md`](r610-watchdog-analysis.md).
