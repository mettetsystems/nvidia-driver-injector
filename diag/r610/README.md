# R610 CUDA regression ladder

Operator scripts. **Do not** run from CI. Stages 4B+ freeze the host on
stock 610.57.04.

```
export EGPU_BDF=          # optional; otherwise discover 10de:2b85
sudo ./diag/r610/01-driver-init
sudo ./diag/r610/02-context-create
sudo ./diag/r610/03-vram-4k
sudo ./diag/r610/04-transfer-256m
# STOP. Stage 4B needs I_ACCEPT_HOST_FREEZE_RISK=1
I_ACCEPT_HOST_FREEZE_RISK=1 sudo ./diag/r610/05-pinned-transfer
I_ACCEPT_HOST_FREEZE_RISK=1 sudo ./diag/r610/06-compute-smoke
I_ACCEPT_HOST_FREEZE_RISK=1 sudo ./diag/r610/07-soak
```

Each CUDA stage prints the PCI BDF, dumps `NVRM|Xid|AER|GPPut|WATCHDOG`
kernel lines afterwards, and exits non-zero on CUDA errors.

See [`../../docs/r610-test-plan.md`](../../docs/r610-test-plan.md).
