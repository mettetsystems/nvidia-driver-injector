# R610 RC / GPFIFO watchdog analysis

**Status:** analysis only. No production patch yet.
**Do not** globally disable NVIDIA’s RC watchdog.
**Do not** confuse this path with addon **A2** (PMC_BOOT_0 bus-loss kthread).

## Observed failure (stock 610.57.04)

After CUDA stages 1–4 passed (init, context, 4 KiB VRAM, 256 MiB pageable
H2D/D2H with byte verification), a subsequent CUDA context / **pinned-memory**
test produced:

- userspace: CUDA error **719** (`CUDA_ERROR_LAUNCH_FAILED`)
- host: hard freeze
- previous-boot kernel log:

```
NVRM: nvAssertFailedNoLog:
Assertion failed:
GPPut < WATCHDOG_GPFIFO_ENTRIES
@ kernel_rc_watchdog.c:1551
NVRM: GPU at PCI:0000:8d:00
```

`0000:8d:00.0` is a **fixture BDF** on the reference host, not a hardcoded
project constant.

External signal: NVIDIA issue
[#1153](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1153)
reports the same assertion on kernel **7.0.x** but not 6.19.x. Linux 7.1 sits
in that window. That is a kernel-interaction hypothesis, not proof for this
5090 / pinned-memory case.

## R595 vs R610 implementation

File: `src/nvidia/src/kernel/gpu/rc/kernel_rc_watchdog.c`

| Item | R595.71.05 | R610.57.04 |
|---|---|---|
| `WATCHDOG_GPFIFO_ENTRIES` | 4 | 4 |
| `krcWatchdogWriteNotifierToGpfifo_IMPL` | assert then `return` if `GPPut >= 4` | **unchanged** |
| includes | — | added `#include "alloc/alloc_channel.h"` |
| assertion line | ~1549 | **1551** |

Core logic (R610):

1. `GPPut = MEM_RD32(&pControlGPFifo[subdeviceId]->GPPut)`
2. if `GPPut >= WATCHDOG_GPFIFO_ENTRIES` (4): `NV_ASSERT(...)` then `return`
3. write a GPFIFO notifier entry at that slot
4. `GPPut = (GPPut + 1) % 4` and write it back

`NV_ASSERT` maps to `nvAssertFailedNoLog`. On a debug/assert build this is
loud; combined with a stuck or garbage `GPPut` it is the last kernel breadcrumb
before the host freeze.

## What the injector currently changes

**Nothing on this path.** Production patches do not mention
`WATCHDOG_GPFIFO_ENTRIES`, `GPPut`, or `kernel_rc_watchdog`.

**A2** (`nv-tb-egpu-qwd.c`) is a different watchdog:

- reads `NV_PMC_BOOT_0` at ~5 Hz
- fires only on `0xFFFFFFFF` (dead bus)
- dispatches into C5 `cleanupGpuLostStateAtomic`
- kill switch: `NVreg_TbEgpuQwdEnable`

A live GPU with a stuck RC command queue can keep `GPPut` out of range (or
the mapping can be MMIO garbage) **without** PMC_BOOT_0 reading as
`0xFFFFFFFF`, so A2 will not fire. CUDA 719 is the userspace face of the
subsequent channel kill.

## Suspected mechanism

Working hypothesis (not proven):

1. Pinned H2D/D2H over USB4/TB5 puts sustained pressure on host mappings and
   the eGPU’s BAR1 window (32 GiB).
2. The RC watchdog channel’s `GPPut` usermode pointer becomes stale, wraps
   incorrectly, or reads as a non-modulo-4 value (including all-ones MMIO).
3. `krcWatchdogWriteNotifierToGpfifo_IMPL` asserts and returns without
   repairing the channel.
4. Subsequent user launches fail with 719; under TB-tunneled Blackwell the
   host then hard-locks (same class of cascade C5 tries to stop on *dead
   bus*, but this path is not dead-bus).

Alternative: Linux 7.x changed something about write-combining, IOMMU
passthrough, or usermode mappings that the RC watchdog’s `MEM_RD32` of
`GPPut` does not tolerate. `#1153` is consistent with a 7.x interaction
even on non-eGPU hardware.

## Proposed mitigation (future patch — not in this rebase)

Constraints:

- Do **not** `#undef` / compile-out the RC watchdog globally.
- A workaround that hides a stuck GPU without recovery is not acceptable.
- Must be observable (counter + printk rate-limited).
- Must be kill-switchable (`NVreg_*`).
- Dual-GPU: scope to `nv->is_external_gpu` / GB202 where possible so the
  RTX 2070 display path is untouched.

Candidate (in preference order):

1. **Treat out-of-range `GPPut` as a recoverable RC event, not an assert.**
   If `GPPut >= 4` *or* `GPPut == 0xFFFFFFFF`, skip the notifier write,
   increment a `tb_egpu_rc_watchdog_gpfifo_skew` counter, rate-limited
   `NV_PRINTF`, and hand the GPU to the existing C5/A3 lost/recovery path
   when the read looks like dead MMIO. Keep the watchdog thread alive.
2. **Validate the `pControlGPFifo` mapping** before `MEM_RD32` (NULL /
   poisoned). Same observability.
3. **Do not** bump `WATCHDOG_GPFIFO_ENTRIES` to paper over overflow. That
   hides a stuck PUT pointer.

Rejected:

- `NVreg_EnableDbgBreakpoint=0` style global assert disable
- ripping out `krcWatchdog`
- applying A2 more frequently as a substitute (wrong sensor)

Suggested future ids (not allocated): a new **C** patch if the assert-to-
recover change is transport-agnostic and upstreamable; otherwise an **A**
patch gated on `is_external_gpu`.

## Observability

Until a patch exists, operators should capture after every CUDA stage:

```
journalctl -k -b -0 --no-pager | grep -E 'NVRM|Xid|AER|GPPut|WATCHDOG'
```

When a patch lands it must export at least:

- `tb_egpu_rc_watchdog_gpfifo_skew` (count)
- last `GPPut` value seen
- last result (`skipped` / `handed-to-c5` / `ok`)

## Rollback

No runtime change in this branch. Reverting future watchdog work is a
single-patch revert plus image rebuild. Do not leave a host running a
module that disabled RC watchdog globally.

## Relation to the test ladder

[`r610-test-plan.md`](r610-test-plan.md) Stage 4B is the regression that
hits this path. Scripts in `diag/r610/` **refuse** to run Stage 4B unless
`I_ACCEPT_HOST_FREEZE_RISK=1`.
