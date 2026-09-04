# Fedora 44 + Linux 7.1 + AORUS RTX 5090 AI BOX

Reference platform for branch `r610-linux-7.1`. BDFs below are a **test
fixture**, not values to hardcode in generic logic.

## Inventory

| Item | Value |
|---|---|
| OS | Fedora Linux 44 Workstation |
| Kernel | `7.1.10-200.fc44.x86_64` |
| NVIDIA open kernel module | 610.57.04 (stock) / `610.57.04-apnex.1` (patched, not loaded) |
| NVIDIA userspace | 610.57.04 |
| CUDA UMD | 13.3 |
| Internal GPU | GeForce RTX 2070 — example BDF `0000:02:00.0` |
| eGPU | GB202 GeForce RTX 5090 (`10de:2b85`) in a GIGABYTE AORUS RTX 5090 AI BOX |
| eGPU example BDF | `0000:8d:00.0` (HDA `0000:8d:00.1`) |
| Link | USB4 / Thunderbolt 5, 80 Gb/s negotiated (2 × 40) |
| BAR1 | 32 GiB (`34359738368` bytes) |

Example topology (do not bake into scripts):

```
0000:80:1d.0
  └── 0000:86:00.0
        └── 0000:87:03.0
              └── 0000:8b:00.0
                    └── 0000:8c:00.0
                          ├── 0000:8d:00.0 RTX 5090
                          └── 0000:8d:00.1 NVIDIA HDA
```

Discovery: vendor `0x10de` + device `0x2b85`, then walk sysfs to the
parent bridge. See `tools/lib/platform.sh`.

## Known-good kernel command line

```
iommu=pt hpbussize=0x20 pcie_aspm=off pcie_ports=native pcie_port_pm=off
thunderbolt.host_reset=false
pci=realloc,assign-busses,resource_alignment=35@0000:8c:00.0
```

The `resource_alignment=35@…` BDF is the **upstream bridge** of the 5090,
not the GPU. Re-discover it after a retimer/port change.

This is **not** the NUC 15 / TB4 line baked into `scripts/apply.sh`
(`iommu=off`, `pcie_aspm.policy=performance`, `thunderbolt.clx=0`).

On Fedora 44 + Linux 7.1, `apply.sh` **refuses** to write those NUC args
unless `--force-cmdline`. Use `--skip-cmdline` (the default on this
platform) and keep the line above.

`scripts/status.sh` accepts `iommu=pt` **or** `iommu=off`. `/sys/class/iommu/dmar0`
is **expected** under `iommu=pt` and is not a failure.

Do not disable SELinux, Secure Boot, IOMMU, or AER globally.

## Results already observed on stock 610.57.04

| Check | Result |
|---|---|
| USB4 authorization | PASS |
| RTX 5090 PCI enumeration | PASS |
| D3cold → D0 | PASS |
| NVIDIA driver binding | PASS |
| nvidia-smi | PASS |
| Physical BAR1 | 32 GiB |
| CUDA stages 1–4 (pageable) | PASS |
| Stage 4B pinned + extra context | CUDA 719, host freeze, RC GPFIFO assert |

See [`../r610-watchdog-analysis.md`](../r610-watchdog-analysis.md).

## Dual GPU / compute-only

- Keep the RTX 2070 as the GNOME display GPU.
- Do not run `apply.sh` ICD disable on this host (script skips it when a
  non-GB202 NVIDIA device exists).
- HDMI audio unbind stays scoped to `10de:22e8`.
- `RmForceExternalGpu=1` is a **global** module param — review before
  loading a patched module here.

## Layer 1 / Layer 2

```
sudo ./scripts/preflight-r610.sh
sudo ./scripts/install-r610.sh          # dry-run
sudo ./scripts/apply.sh --skip-cmdline --skip-icd --no-act
```

Do **not** `docker compose up` / `modprobe` without reading
[`../r610-rollback.md`](../r610-rollback.md).

## Podman (preferred on this workstation)

Preserve Docker Compose and k3s. For local image builds:

```
podman build -t apnex/nvidia-driver-injector:610.57.04-apnex.1 .
```

`Containerfile` is a symlink to `Dockerfile`.

Kernel module **load** cannot be rootless: the injector still needs
privileged host mounts (`/lib/modules`, `/sys`, `/dev`). Documented
privilege boundary: building in Podman is fine; loading `nvidia.ko`
affects the host kernel and needs explicit human approval.

SELinux: bind-mounts used in Phase 0/3 used `:Z` on the NVIDIA source
tree and `:ro` on kernel headers. Do not `setenforce 0`.

Quadlet is optional and not required for Milestone A. A privileged
`.container` unit that `modprobe`s on start is equivalent in risk to
`docker compose up` — do not enable one by default.

Compose-equivalent run (load **not** invoked until the entrypoint runs —
do not start this until Milestone B is approved):

```
podman run --name nvidia-driver-injector --privileged --pid=host \
  -v /lib/modules:/lib/modules:rw \
  -v /usr/src:/usr/src:ro \
  -v /sys:/sys:rw \
  -v /proc:/proc \
  -v /dev:/dev \
  -v /etc/modprobe.d:/etc/modprobe.d:ro \
  -v /etc/group:/etc/group:ro \
  -v /lib/firmware:/lib/firmware:rw \
  apnex/nvidia-driver-injector:610.57.04-apnex.1
```

## Compile (no load)

See [`../r610-build-baseline.md`](../r610-build-baseline.md) for the
rootless Fedora 44 Podman `make modules` recipe.
