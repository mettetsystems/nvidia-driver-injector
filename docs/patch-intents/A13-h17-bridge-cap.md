---
id: A13-h17-bridge-cap
layer: addon
source-branch: a13-h17-bridge-cap
upstream-candidacy: n/a
telemetry-tier: mandatory
status: draft
related-patches: [A1-pcie-primitives, E1-egpu-detection]
---

# A13-h17-bridge-cap — In-driver H17 LnkCtl2 cap for GB202 under lockdown

## Purpose

The driver SHALL apply Lever H17 (Hardware Autonomous Speed Disable plus
Target Link Speed Gen3) on the immediate upstream PCIe bridge of a GB202
Thunderbolt/USB4 eGPU from `nv_pci_probe`, using kernel PCI APIs that are
not blocked by `LOCKDOWN_PCI_ACCESS`. Fedora 44 with Secure Boot sets
kernel lockdown to integrity, which rejects userspace `setpci` writes
through sysfs. This patch is the production cap path. It SHALL NOT
program an internal NVIDIA display GPU such as the RTX 2070.

## Requirements

### Requirement: Probe SHALL cap only GB202 on a TB/USB4 path

The driver SHALL call `tb_egpu_h17_apply` from `nv_pci_probe` after
`nvl->pci_dev` is assigned and before GSP/`rm_init_adapter`. The helper
MUST return 0 without writing when the device is not PCI `10de:2b85`,
when `NVreg_TbEgpuH17Enable=0`, or when the GPU is not
`pci_is_thunderbolt_attached` and not `pdev->untrusted`. On a matching
GB202 the helper MUST obtain `pci_upstream_bridge`, RMW
`PCI_EXP_LNKCTL2` with `PCI_EXP_LNKCTL2_HASD` and configured TLS via
`pcie_capability_clear_and_set_word`, read back and require HASD plus
TLS, then request retrain with `PCI_EXP_LNKCTL_RL`. Verify failure MUST
fail only that GB202 probe.

#### Scenario: Internal RTX 2070 is probed
- **GIVEN** a NVIDIA device whose PCI device id is not `0x2b85`
- **WHEN** `nv_pci_probe` runs
- **THEN** `tb_egpu_h17_apply` MUST return 0 without writing LnkCtl2
- **AND** the 2070 probe MUST continue

#### Scenario: GB202 eGPU LnkCtl2 is capped before GSP
- **GIVEN** PCI `10de:2b85` on a Thunderbolt/USB4 path
- **AND** `NVreg_TbEgpuH17Enable=1`
- **WHEN** `nv_pci_probe` assigns `nvl->pci_dev`
- **THEN** the upstream bridge LnkCtl2 MUST have HASD set and TLS=Gen3
- **AND** the driver MUST log PASS or VERIFY_FAILED clearly
- **AND** a verify mismatch MUST fail that probe only

## Scope boundary

- This patch deliberately does NOT disable Secure Boot or kernel lockdown.
- Out-of-scope: userspace `setpci` as an authoritative cap on lockdown hosts.
- A1 remains pure observability; H17 writes live in this translation unit.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| apply | `pci_info` | `"tb_egpu H17: LnkCtl2 0x%04x -> 0x%04x (HASD + TLS=Gen%u) for GB202 %s"` |
| pass | `pci_info` | `"tb_egpu H17: PASS LnkCtl2=0x%04x retrain requested"` |
| verify-fail | `pci_err` | `"tb_egpu H17: VERIFY_FAILED LnkCtl2=0x%04x (need HASD=1 TLS=0x%x)"` |

## Provenance

- **Source cluster:** Lever H17 userspace bridge-link-cap (lockdown bypass).
- **Vanilla baseline:** `kernel-open/nvidia/nv-pci.c:nv_pci_probe`.
- **Fork branch:** `a13-h17-bridge-cap` (hand-authored on the R610 stack).
- **Upstream issue:** n/a.
