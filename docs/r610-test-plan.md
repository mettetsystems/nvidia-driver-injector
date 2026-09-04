# R610 test plan

**Do not** run Stage 4B, soak, or any `modprobe`/`insmod` from automation.
Those steps need an explicit human operator.

Scripts: [`diag/r610/`](../diag/r610/). Unit tests: `bash tests/run.sh`
(no GPU required).

## Milestone gates

| Milestone | Meaning | Status |
|---|---|---|
| **A** — source rebase | stock + patched `make modules` on 7.1.10; repo tests pass | **PASS** (compile + unit tests; see [`r610-build-baseline.md`](r610-build-baseline.md)) |
| **B** — safe module load | patched `nvidia.ko` loads; 2070 display lives; 5090 enumerates; BAR1 32 GiB; `nvidia-smi` | **not started** |
| **C** — CUDA regression | Stages 1–4B without 719 / GPFIFO assert / freeze | **not started** |
| **D** — compute soak | modest kernel + repeated ctx + 5/30 min | **not started** |

## Ladder (operator)

Every CUDA stage must select the GB202 GPU by discovered PCI BDF (or
`EGPU_BDF` override), print before each dangerous call, flush output, and
dump kernel lines matching `NVRM|Xid|AER|GPPut|WATCHDOG`.

| Stage | Script | Stock 610 result | Patched target |
|---|---|---|---|
| 0 | `01-driver-init` | nvidia-smi PASS | PASS |
| 1 | `02-context-create` (cuInit + cuDeviceGetByPCIBusId) | PASS | PASS |
| 2 | same script (`cuCtxCreate_v2`) | PASS | PASS |
| 3 | `03-vram-4k` | PASS | PASS |
| 4 | `04-transfer-256m` (pageable) | PASS (~0.46 / 0.86 GB/s) | PASS, no freeze |
| 4B | `05-pinned-transfer` | **719 + host freeze + GPPut assert** | PASS, GPU remains usable |
| 5 | `06-compute-smoke` | not reached | modest kernel PASS |
| 6–8 | `07-soak` | not reached | repeated ctx; 5 min; then 30 min |

Stage 4B / 5 / soak refuse unless `I_ACCEPT_HOST_FREEZE_RISK=1`.

Do not jump to vLLM or a 30 GiB model.

## Dual GPU

- RTX 2070 (`0000:02:00.0` on the fixture) stays the display GPU.
- RTX 5090 / GB202 is compute-only.
- Do not globally disable NVIDIA ICDs (`apply.sh` skips them when a
  non-GB202 NVIDIA device is present).
- Audio udev stays scoped to `10de:22e8`.

## Kernel cmdline

Do not regress the known-good Fedora 44 + 7.1 line documented in
[`platforms/fedora44-linux71-aorus5090.md`](platforms/fedora44-linux71-aorus5090.md).
`scripts/apply.sh` will not write `iommu=off` on that platform unless
`--force-cmdline`.
