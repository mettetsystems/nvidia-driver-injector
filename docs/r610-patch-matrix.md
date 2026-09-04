# R610 patch matrix

**Branch:** `r610-linux-7.1`
**Vanilla target:** NVIDIA/open-gpu-kernel-modules tag `610.57.04` (`e4a5faa2567f`)
**Apply order:** `patches/manifest` (C6 → … → A12; A11 before A10)
**Classification date:** 2026-09-03

`git apply` success is necessary but not sufficient. Semantic status records
whether R610 already contains the *intent*.

Apply-status values: `CLEAN_APPLY` | `OFFSET_ONLY` | `MOVED_CODE` |
`PARTIALLY_UPSTREAMED` | `FULLY_UPSTREAMED` | `OBSOLETE` |
`SEMANTIC_REWRITE_REQUIRED` | `UNKNOWN`

Worktree used for the stacked apply: `/tmp/ogkm-610-clean-apply`.
Result: **19 applied, 0 rejected**. Patched `make modules` vs
`7.1.10-200.fc44.x86_64` **PASS**. `modinfo` version
`610.57.04-apnex.1` (file only — not loaded).

| Patch ID | Layer | Original purpose | R595 target | R610 target | Apply status | Semantic status | Required action | Risk | Validation |
|---|---|---|---|---|---|---|---|---|---|
| C6 | base | Invert `os_cond_acquire_rwlock_{read,write}` so 1=acquired matches Linux `down_*_trylock` | `os-interface.c` | identical, still inverted | OFFSET_ONLY | still required | keep | deadlock if dropped (A10/A11) | apply + compile |
| C1 | base | Kbuild reads `NVIDIA_VERSION` from `version.mk` | `kernel-open/Kbuild` `-DNV_VERSION_STRING=\"595.71.05\"` | same, literal is now `610.57.04` | CLEAN_APPLY (minus-line retargeted) | still required | keep | version drift | `modinfo` vs `version.mk` |
| C2 | base | Unmask AER internal-error bits at probe | `nv-pci.c:nv_pci_probe` | same site, surrounding probe grew | OFFSET_ONLY | still required | keep | silent AER | apply + compile |
| C3 | base | Retry `NV_PMC_BOOT_0` in `osHandleGpuLost` | `osinit.c:osHandleGpuLost` | **identical** | OFFSET_ONLY | still required | keep | false GPU-lost | apply + compile |
| C4 | base | Register `pci_error_handlers` stubs | `nv_pci_driver.err_handler` unset | still unset | OFFSET_ONLY | still required | keep | no AER callbacks | apply + compile |
| E1 | base | TB/USB4 eGPU via `pci_is_thunderbolt_attached` / `untrusted` | `RmCheckForExternalGpu` TB3 whitelist | **identical** | OFFSET_ONLY | still required | keep | eGPU treated as internal | apply + compile |
| C5 | base | Dead-bus crash-safety | `nv_state_t` + RM/UVM/DRM/resserv | `nv_state_t` gained `is_cxl_dev`; `rs_server.c` gained `rmapi/resource.h`; `nv-pat.h` gone | MOVED_CODE | still required | ported (field after `is_cxl_dev`; include order) | host freeze on dead MMIO | apply + compile |
| A1 | addon | PCIe/AER snapshot primitives | `nv-tb-egpu-pcie.{c,h}` | additive | OFFSET_ONLY | still required | keep | none (additive) | apply + compile |
| A2 | addon | PMC_BOOT_0 bus-loss kthread | `nv-tb-egpu-qwd.{c,h}` | additive | OFFSET_ONLY | still required; **not** RC GPFIFO | keep | none for RC watchdog | apply + compile |
| A3 | addon | Recovery state machine | `nv.c` include after `nv-pat.h` | `nv-pat.h` dropped; include after `nv-caps-imex.h` | MOVED_CODE | still required | ported | recovery silent | apply + compile |
| A4 | addon | Close-path `[CLOSE]` telemetry | UVM Kbuild after `uvm_linux.c` | UVM Kbuild gained rubin sources before `uvm_common.c` | MOVED_CODE | still required | ported | missing close logs | apply + compile |
| A5 | addon | Version stamp + `CONFIG_NV_TB_EGPU` | `595.71.05-apnex.30` | `610.57.04-apnex.1` | CLEAN_APPLY (literals retargeted) | still required | keep | firmware path mismatch | `modinfo` |
| A6 | addon | Bounded-wait `/dev/nvidia*` open | `nv.c` | surrounding nv.c grew | OFFSET_ONLY | still required | keep | F40b hang | apply + compile |
| A7 | addon | Bounded-wait shutdown | `nv.c` | same | OFFSET_ONLY | still required | keep | F40b hang | apply + compile |
| A8 | addon | `tb_egpu_*` sysfs | `nv-pci.c` / metrics | same | OFFSET_ONLY | still required | keep | no counters | apply + compile |
| A9 | addon | `is_external_gpu` at probe | `nv-pci.c` | same | OFFSET_ONLY | still required | keep | late classify | apply + compile |
| A11 | addon | F45 deadlock breaker | `nv.c` / `osapi.c` | same | OFFSET_ONLY | still required | keep | open-path deadlock | apply + compile |
| A10 | addon | Lock-free GPU-lost sink | `nv.c` / `osapi.c` | same | OFFSET_ONLY | still required | keep | lost-state wedge | apply + compile |
| A12 | addon | Bound GSP-bootstrap funnel | `nv.c` | same | OFFSET_ONLY | still required | keep | probe/resume hang | apply + compile |

Nothing in the 19-patch set is `FULLY_UPSTREAMED` for the symbols compared in
[`r610-rebase-audit.md`](r610-rebase-audit.md).

## Not in the production set (new work)

| ID (proposed) | Purpose | Status |
|---|---|---|
| (none yet) | NVIDIA RC GPFIFO watchdog (`GPPut < WATCHDOG_GPFIFO_ENTRIES` @ `kernel_rc_watchdog.c:1551`) | Analysis only — see [`r610-watchdog-analysis.md`](r610-watchdog-analysis.md). Do **not** globally disable the RC watchdog. |

A2’s “Q-watchdog” is PMC_BOOT_0 `0xFFFFFFFF` detection. It does not run on
this assertion path.
