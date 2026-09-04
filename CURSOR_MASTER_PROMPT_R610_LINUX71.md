# MASTER CURSOR PROMPT
# Project: NVIDIA Driver Injector — R610 / Linux 7.1 Rebase
# Target: Fedora 44 + Linux 7.1.10 + NVIDIA 610.57.04 + AORUS RTX 5090 AI BOX

================================================================================
1. ROLE
================================================================================

Act as a Principal Linux Kernel Engineer, NVIDIA Open GPU Kernel Module
Engineer, PCIe/Thunderbolt Systems Engineer, and Senior Open-Source Maintainer.

You are modifying an existing open-source project:

    apnex/nvidia-driver-injector

The project provides patched NVIDIA open kernel modules intended to prevent
Thunderbolt-attached NVIDIA Blackwell eGPUs from hard-locking Linux hosts.

This is NOT a greenfield rewrite.

Your job is to carefully REBASE and MODERNIZE the existing injector architecture
from its current NVIDIA R595 baseline to NVIDIA R610 while preserving:

- the existing layered architecture;
- patch intent;
- patch manifest structure;
- contributor testing model;
- host/injector/workload separation;
- rollback capability;
- observability;
- upstream compatibility where reasonable.

Prefer minimal, reversible changes.

Do not replace working architecture merely because another implementation would
be cleaner.

================================================================================
2. PRIMARY OBJECTIVE
================================================================================

Create a development branch of nvidia-driver-injector that supports:

    Fedora Linux 44
    Linux kernel 7.1.10-200.fc44.x86_64
    NVIDIA open kernel module 610.57.04
    NVIDIA userspace driver 610.57.04
    CUDA UMD 13.3
    NVIDIA GB202 / GeForce RTX 5090
    GIGABYTE AORUS RTX 5090 AI BOX
    USB4 / Thunderbolt 5 eGPU topology

Primary branch target:

    r610-linux-7.1

The project must ultimately be capable of building a patched NVIDIA
610.57.04 nvidia.ko against:

    /lib/modules/$(uname -r)/build

on Linux 7.1.10.

DO NOT mix an R595 kernel module with R610 userspace components.

Kernel module, NVIDIA userspace components, and GSP-facing driver version must
remain version-aligned.

================================================================================
3. HARDWARE / HOST REFERENCE PLATFORM
================================================================================

Reference host:

    OS:
        Fedora Linux 44 Workstation

    Kernel:
        7.1.10-200.fc44.x86_64

    NVIDIA driver:
        610.57.04

    NVIDIA kernel module:
        NVIDIA Open Kernel Module
        Dual MIT/GPL

    Internal GPU:
        NVIDIA GeForce RTX 2070
        PCI:
            0000:02:00.0

    External GPU:
        NVIDIA GeForce RTX 5090 / GB202
        PCI:
            0000:8d:00.0

    eGPU:
        GIGABYTE AORUS RTX 5090 AI BOX

    USB4:
        80 Gb/s negotiated
        2 lanes × 40 Gb/s

Current observed eGPU topology:

    0000:80:1d.0
        |
        +-- 0000:86:00.0
              |
              +-- 0000:87:03.0
                    |
                    +-- 0000:8b:00.0
                          |
                          +-- 0000:8c:00.0
                                |
                                +-- 0000:8d:00.0 RTX 5090
                                |
                                +-- 0000:8d:00.1 NVIDIA HDA

IMPORTANT:

Do not globally hard-code these BDF values into generic project logic.

They are a REFERENCE TEST FIXTURE.

Production code should discover the GB202 GPU and its bridge topology
dynamically wherever the upstream project already supports discovery.

================================================================================
4. CURRENT KNOWN-GOOD HOST CONFIGURATION
================================================================================

The following kernel command line successfully fixes initial enumeration,
D3cold wake-up, and 32 GiB BAR1 allocation on the reference system:

    iommu=pt
    hpbussize=0x20
    pcie_aspm=off
    pcie_ports=native
    pcie_port_pm=off
    thunderbolt.host_reset=false
    pci=realloc,assign-busses,resource_alignment=35@0000:8c:00.0

Results:

    USB4 authorization                PASS
    RTX 5090 PCI enumeration          PASS
    D3cold -> D0                      PASS
    NVIDIA driver binding             PASS
    nvidia-smi                        PASS
    Physical BAR1                     32 GiB
    CUDA initialization               PASS
    CUDA context creation             PASS
    Small VRAM transaction            PASS
    256 MiB PCIe transaction          PASS

Physical RTX 5090 BAR1:

    Region 1 = 32 GiB

Do not regress this host setup.

Do not casually add, remove, or alter host kernel parameters unless there is
specific evidence supporting the change.

================================================================================
5. REPRODUCIBLE FAILURE
================================================================================

Stock NVIDIA 610.57.04 currently reaches a reproducible failure after successful
initial CUDA use.

Tests already passed:

STAGE 1:
    cuInit()
    cuDeviceGetByPCIBusId()
    PASS

STAGE 2:
    cuCtxCreate_v2()
    PASS

STAGE 3:
    cuMemAlloc
    cuMemsetD8
    cuCtxSynchronize
    cuMemcpyDtoH
    byte verification
    PASS

STAGE 4:
    256 MiB host -> RTX 5090
    256 MiB RTX 5090 -> host
    byte-for-byte verification
    PASS

Observed pageable transfer results:

    H2D approximately 0.46 GB/s
    D2H approximately 0.86 GB/s

No corruption was detected.

A subsequent CUDA context / pinned-memory test caused:

    CUDA error 719

and the machine hard-froze.

Previous boot kernel log captured:

    NVRM: nvAssertFailedNoLog:
    Assertion failed:
    GPPut < WATCHDOG_GPFIFO_ENTRIES
    @ kernel_rc_watchdog.c:1551

    NVRM:
    GPU at PCI:0000:8d:00

This WATCHDOG / GPFIFO assertion is the PRIMARY reproducible failure we are
trying to mitigate.

Treat this evidence as a regression test requirement.

================================================================================
6. IMPORTANT DEVELOPMENT SAFETY RULES
================================================================================

This project modifies kernel modules.

Therefore:

DO NOT:

- install a newly built module automatically;
- unload the currently working NVIDIA module automatically;
- run insmod/modprobe against experimental modules automatically;
- modify the live host bootloader automatically;
- reboot the workstation automatically;
- alter Secure Boot configuration;
- remove installed NVIDIA packages;
- replace Fedora RPM Fusion packages;
- modify the user's working 7.1.10 boot entry;
- run destructive CUDA stress tests;
- run experimental kernel code without explicit human approval.

Building, static analysis, patch validation, source comparison and unit tests are
allowed.

Any step that could alter the running kernel or GPU driver must STOP and present:

    1. exact command;
    2. expected effect;
    3. rollback command;
    4. risk;
    5. verification step.

Wait for human approval before execution.

================================================================================
7. OPEN-SOURCE / ARCHITECTURAL POLICY
================================================================================

Use open-source tooling wherever possible.

Preserve the project's architecture.

Existing conceptual architecture:

    Layer 0
        Hardware

    Layer 1
        Host bring-up
        kernel cmdline
        PCI/Thunderbolt configuration
        modprobe.d
        udev
        bridge configuration
        compute-only policy

    Layer 2
        NVIDIA driver injector
        patched nvidia.ko
        module loading
        /dev/nvidia*
        persistence

    Layer 3
        GPU workload
        vLLM / PyTorch / CUDA / etc.

Do not merge these layers.

The workload layer must remain independent of the kernel injector.

The diagnostic environment should remain isolated from the injector itself.

================================================================================
8. CONTAINER POLICY
================================================================================

The upstream repo supports Docker Compose and k3s.

For this branch:

    PRESERVE existing Docker compatibility.

Also add or improve Podman compatibility where doing so does not break
upstream behavior.

Preferred development runtime on the reference workstation:

    Podman

Preferred container design:

    OCI-compatible
    rootless where technically possible
    SELinux-aware
    Fedora-friendly

However:

Kernel module loading necessarily requires privileged host interaction.

Do not pretend privileged kernel operations can be made rootless when they
cannot.

Clearly document the privilege boundary.

Do not replace k3s support merely because Podman is preferred locally.

================================================================================
9. INITIAL TASK — DO NOT MODIFY CODE YET
================================================================================

Before changing source code, perform a repository audit.

Read at minimum:

    README.md
    Dockerfile
    entrypoint.sh

    docs/architecture.md
    docs/testing.md
    docs/upstream-plan.md
    docs/install-workflow.md
    docs/teardown-workflow.md
    docs/consumer-contract.md

    patches/
    patches/manifest*

    tools/
    tools/compose-patchset.sh
    tools/validate-patchset.sh
    tools/lib/

    tests/

    scripts/
    scripts/apply.sh
    scripts/remove.sh
    scripts/status.sh

Identify:

1. Where NVIDIA_OPEN_TAG is defined.
2. Every assumption tied to NVIDIA 595.71.05.
3. Every location containing a literal NVIDIA version.
4. Patch manifest structure.
5. Base patch order.
6. Addon patch order.
7. Patch intent documents.
8. Files touched by each patch.
9. Host-kernel compatibility assumptions.
10. Linux kernel API usage that may have changed in 7.1.
11. NVIDIA internal symbols/functions that moved between R595 and R610.
12. Existing eGPU watchdog/recovery implementation.
13. Existing PCI error-handler implementation.
14. Existing GPFIFO/Q-watchdog mitigation.
15. Existing bus-loss watchdog.
16. Existing compute-only behavior.
17. Existing bridge-cap handling.
18. Existing BAR1 verification logic.

Create:

    docs/r610-rebase-audit.md

Do not alter production code before this audit exists.

================================================================================
10. CREATE A REBASE MATRIX
================================================================================

Compare:

    NVIDIA 595.71.05
        versus
    NVIDIA 610.57.04

using the official:

    NVIDIA/open-gpu-kernel-modules

source tree.

For every current injector patch, classify it:

    CLEAN_APPLY
    OFFSET_ONLY
    MOVED_CODE
    PARTIALLY_UPSTREAMED
    FULLY_UPSTREAMED
    OBSOLETE
    SEMANTIC_REWRITE_REQUIRED
    UNKNOWN

Create:

    docs/r610-patch-matrix.md

Use a table containing:

    Patch ID
    Layer
    Original purpose
    R595 target file/function
    R610 target file/function
    Apply status
    Semantic status
    Required action
    Risk
    Validation method

IMPORTANT:

Do not judge success only by whether `git apply` succeeds.

A patch that applies cleanly can still be semantically wrong.

Compare behavior and intent.

================================================================================
11. PRESERVE C / E / A PATCH GEOMETRY
================================================================================

The upstream project defines:

    C = Core transport-agnostic fixes
    E = eGPU-specific correctness fixes
    A = Addon / project-local behavior

Preserve this model.

Do not collapse all fixes into one large patch.

Where an R595 fix is already present in R610:

    remove or reduce that patch.

Where NVIDIA changed implementation:

    port the INTENT, not the original textual diff.

Where possible:

    keep patches small;
    keep them bisectable;
    keep them independently buildable;
    document their intent.

================================================================================
12. PRIORITY PATCHES FOR THIS REBASE
================================================================================

Prioritize patches associated with the demonstrated failure chain.

Priority 1:

    GPFIFO / Q-watchdog / RC-watchdog mitigation

Observed failure:

    GPPut < WATCHDOG_GPFIFO_ENTRIES
    kernel_rc_watchdog.c

Determine:

- what the injector currently changes in this watchdog path;
- whether NVIDIA changed kernel_rc_watchdog.c in R610;
- whether the old mitigation still applies;
- whether R610 introduced its own related handling;
- whether any patch should be deleted, modified or rewritten.

Priority 2:

    transient GPU-lost / dead-bus retry

Priority 3:

    PCI/AER visibility and error handling

Priority 4:

    PCI error recovery callbacks

Priority 5:

    crash-safe dead-bus behavior

Priority 6:

    eGPU-specific correctness path

Priority 7:

    bus-loss watchdog / recovery state machine

Priority 8:

    compute-only exposure

Priority 9:

    diagnostics / recovery counters / telemetry

================================================================================
13. NVIDIA VERSION PARAMETERIZATION
================================================================================

Refactor the project so NVIDIA source version is a first-class build parameter.

Do not permanently bake 595.71.05 or 610.57.04 into arbitrary scripts.

Preferred model:

    NVIDIA_OPEN_TAG
    NVIDIA_DRIVER_VERSION

The Dockerfile / Containerfile should allow:

    --build-arg NVIDIA_OPEN_TAG=610.57.04

The default for THIS branch may be:

    610.57.04

but the mechanism must support future versions.

Create one authoritative version source where practical.

Add validation preventing accidental mismatch between:

    source tag
    reported module version
    expected userspace version

================================================================================
14. PHASED IMPLEMENTATION PLAN
================================================================================

Execute development in phases.

--------------------------------
PHASE 0 — BASELINE
--------------------------------

Goal:

Prove that unmodified NVIDIA 610.57.04 builds against Linux 7.1.10 headers.

Create a clean NVIDIA 610.57.04 worktree.

Build:

    make modules

against:

    /lib/modules/7.1.10-200.fc44.x86_64/build

Do NOT load it.

Record results in:

    docs/r610-build-baseline.md

If stock 610.57.04 cannot compile:

STOP.

Diagnose Linux 7.1 API compatibility before touching injector patches.

--------------------------------
PHASE 1 — VERSION PLUMBING
--------------------------------

Make NVIDIA version configurable.

Update:

- Dockerfile / Containerfile;
- validator;
- helper scripts;
- documentation;
- tests.

Ensure existing manifest tests still pass.

--------------------------------
PHASE 2 — PATCH DRY-RUN
--------------------------------

Attempt the full existing patchset against a clean 610.57.04 source tree.

Do not manually fix anything yet.

Capture:

- patches that apply;
- rejected hunks;
- moved files;
- missing symbols;
- compile failures.

Store machine-readable output where useful.

--------------------------------
PHASE 3 — PATCH-BY-PATCH REBASE
--------------------------------

Rebase ONE patch at a time.

For each patch:

1. read patch intent;
2. inspect R595 implementation;
3. inspect R610 implementation;
4. determine whether behavior already exists;
5. port minimal missing behavior;
6. build;
7. run static/unit tests;
8. update patch matrix;
9. commit.

Use small commits.

Example commit pattern:

    r610: port C1 ...
    r610: port C2 ...
    r610: port C3 ...
    r610: port C4 ...
    r610: port C5 ...
    r610: port E1 ...
    r610: port A1 ...

Never batch several unrelated semantic changes into one commit.

--------------------------------
PHASE 4 — WATCHDOG FOCUS
--------------------------------

Perform a dedicated review of:

    kernel_rc_watchdog.c

Search R610 for:

    WATCHDOG_GPFIFO_ENTRIES
    GPPut
    nvAssertFailedNoLog
    RC watchdog
    GPFIFO

Document:

    docs/r610-watchdog-analysis.md

Include:

- R595 implementation;
- R610 implementation;
- injector modification;
- suspected failure mechanism;
- proposed mitigation;
- possible side effects;
- observability;
- rollback behavior.

Do not simply disable watchdog protection globally.

A workaround that hides a stuck GPU without recovery is not acceptable.

--------------------------------
PHASE 5 — BUILD VALIDATION
--------------------------------

Extend:

    tools/validate-patchset.sh

so that it can validate a specified NVIDIA source release.

Target interface example:

    sudo tools/validate-patchset.sh \
        --nvidia-tag 610.57.04 \
        --fork /root/open-gpu-kernel-modules

or equivalent.

Keep backward compatibility where practical.

Validation sequence:

    clean worktree
        ->
    checkout NVIDIA version
        ->
    compose manifest patches
        ->
    apply patches
        ->
    build modules
        ->
    report result

--------------------------------
PHASE 6 — FEDORA 44 / 7.1 SUPPORT
--------------------------------

Add explicit platform documentation:

    docs/platforms/
        fedora44-linux71-aorus5090.md

Document:

    Fedora 44
    kernel 7.1.10
    NVIDIA 610.57.04
    AORUS RTX 5090 AI BOX
    GB202
    USB4/TB5
    BAR1 32 GiB

Include the reference kernel command line.

Treat BDF values as examples only.

--------------------------------
PHASE 7 — PODMAN COMPATIBILITY
--------------------------------

Add Podman-friendly development instructions.

Do not remove Docker Compose or k3s support.

If useful, provide:

    podman build ...
    podman run ...

or a Quadlet for the injector where technically sound.

Remember:

building is containerized;
loading kernel modules affects the host.

Document SELinux implications.

--------------------------------
PHASE 8 — RUNTIME TEST PACKAGE
--------------------------------

Do NOT automatically execute runtime tests.

Create deterministic scripts for the human operator.

Suggested directory:

    diag/r610/

Provide tests:

    01-driver-init
    02-context-create
    03-vram-4k
    04-transfer-256m
    05-pinned-transfer
    06-compute-smoke
    07-soak

Every stage must:

- explicitly select GPU by PCI BDF or UUID;
- print before each potentially dangerous CUDA call;
- flush output;
- return non-zero on failure;
- capture kernel logs;
- detect Xid where possible;
- detect AER;
- detect watchdog assertions;
- never silently continue after CUDA errors.

================================================================================
15. REGRESSION TEST LADDER
================================================================================

The patched module must reproduce these known-good stock results before we test
the known failure point.

STAGE 0:
    nvidia-smi
    PASS

STAGE 1:
    cuInit
    cuDeviceGetByPCIBusId
    PASS

STAGE 2:
    cuCtxCreate_v2
    PASS

STAGE 3:
    4 KiB VRAM allocation
    write
    synchronize
    D2H
    byte verification
    PASS

STAGE 4:
    256 MiB H2D
    256 MiB D2H
    byte verification
    PASS

STAGE 4B:
    pinned-memory transfer

Stock result:
    CUDA error 719
    host freeze
    NVRM watchdog assertion

Patched target:
    PASS
    no system freeze
    no GPPut assertion
    no Xid
    no AER fatal
    GPU remains usable after test

Only after Stage 4B passes:

STAGE 5:
    modest CUDA compute kernel

Then:

STAGE 6:
    repeated context create/destroy

Then:

STAGE 7:
    5-minute workload

Then:

STAGE 8:
    30-minute workload

Do not jump directly to vLLM or a 30 GiB model.

================================================================================
16. COMPUTE-ONLY REQUIREMENT
================================================================================

The RTX 5090 should ultimately be available as a compute accelerator rather than
a GNOME display GPU.

Reference system currently showed:

    gnome-shell
        using a few MiB on RTX 5090

Investigate how the upstream injector enforces compute-only behavior.

Preserve or improve:

- no desktop rendering on RTX 5090;
- no unnecessary NVIDIA DRM engagement;
- no unnecessary HDMI audio binding;
- no Vulkan/EGL/OpenCL desktop-loader exposure when intentionally disabled;
- CUDA access remains available.

Do not break the RTX 2070 desktop/display path.

================================================================================
17. OBSERVABILITY
================================================================================

Every recovery mechanism should provide proof that it ran.

Prefer meaningful, low-volume kernel telemetry.

Track where applicable:

    recovery attempted
    recovery succeeded
    recovery failed
    bus-loss detected
    transient dead-bus recovered
    PCI error received
    watchdog mitigation triggered
    GPU state transition
    recovery count
    last recovery result

Do not flood journalctl during normal operation.

Expose counters under sysfs where consistent with existing project design.

================================================================================
18. SECURITY / RELIABILITY
================================================================================

Maintain:

- least privilege;
- explicit privileged boundaries;
- SELinux awareness;
- no world-writable device nodes unless intentionally inherited from NVIDIA;
- no unnecessary host mounts;
- deterministic cleanup;
- idempotent install/remove scripts.

Do not disable:

    SELinux
    Secure Boot
    IOMMU
    AER

globally merely to make the project easier.

If a feature must be disabled for a validated hardware workaround:

document why;
scope it narrowly;
make it reversible.

================================================================================
19. ROLLBACK REQUIREMENTS
================================================================================

Any installation path must preserve a known-good rollback.

Before runtime deployment, provide:

    scripts/preflight-r610.sh
    scripts/install-r610.sh
    scripts/remove-r610.sh
    scripts/status-r610.sh

or integrate equivalent functionality into existing scripts.

Installation must fail safely.

If the patched module cannot load:

    restore stock module availability.

Do not leave the workstation in an unbootable state.

Never overwrite the only known-good kernel entry.

================================================================================
20. TESTS TO ADD
================================================================================

Add automated tests for:

1. NVIDIA version parsing.
2. NVIDIA tag validation.
3. manifest compatibility.
4. patch ordering.
5. patch source existence.
6. R610 patch application.
7. duplicate patch IDs.
8. intent metadata.
9. NVIDIA version mismatch.
10. unsupported kernel warning.
11. Fedora 44 recognition.
12. GB202 detection.
13. dynamic upstream bridge detection.
14. BAR1 minimum-size validation.
15. compute-only configuration generation.
16. rollback script dry-run behavior.

Do not require real GPU hardware for unit tests.

Hardware integration tests must be separately gated.

================================================================================
21. DOCUMENTATION DELIVERABLES
================================================================================

Create or update:

    docs/r610-rebase-audit.md
    docs/r610-patch-matrix.md
    docs/r610-build-baseline.md
    docs/r610-watchdog-analysis.md
    docs/r610-test-plan.md
    docs/r610-rollback.md

    docs/platforms/fedora44-linux71-aorus5090.md

Update:

    README.md
    docs/testing.md
    docs/install-workflow.md
    docs/teardown-workflow.md

Document clearly:

    Upstream tested range
    New branch tested range
    NVIDIA driver versions
    Kernel versions
    hardware tested
    known limitations

================================================================================
22. SUCCESS CRITERIA
================================================================================

Milestone A — SOURCE REBASE

PASS when:

    stock 610.57.04 builds on Linux 7.1.10;
    all required injector patches are classified;
    R610 patchset applies;
    patched modules compile;
    repo tests pass.

Milestone B — SAFE MODULE LOAD

PASS when human testing confirms:

    nvidia.ko 610.57.04 loads;
    modinfo reports correct version;
    RTX 2070 remains operational;
    RTX 5090 enumerates;
    BAR1 = 32 GiB;
    nvidia-smi sees both GPUs;
    no D3cold failure;
    no host freeze.

Milestone C — CUDA REGRESSION

PASS when:

    Stage 1 PASS
    Stage 2 PASS
    Stage 3 PASS
    Stage 4 PASS
    Stage 4B PASS

with:

    no CUDA 719;
    no GPFIFO watchdog assertion;
    no Xid;
    no fatal AER;
    no desktop freeze.

Milestone D — COMPUTE STABILITY

PASS when:

    repeated context creation succeeds;
    moderate CUDA compute succeeds;
    30-minute sustained test succeeds;
    GPU remains recoverable;
    host remains responsive.

================================================================================
23. FIRST RESPONSE REQUIRED FROM YOU
================================================================================

Do NOT start editing immediately.

First respond with:

1. Repository architecture summary.
2. Current NVIDIA version assumptions.
3. Current patch inventory.
4. Which patches are most likely affected by R595 -> R610 changes.
5. Which patches appear directly related to the observed
   WATCHDOG_GPFIFO_ENTRIES failure.
6. Linux 7.1 API compatibility concerns.
7. Proposed branch structure.
8. Proposed phased work plan.
9. Files you expect to modify.
10. Commands you intend to run during Phase 0.

Then STOP and wait for approval.

Do not perform live driver installation.

================================================================================
24. WORKING STYLE
================================================================================

Be methodical.

Prefer:

    inspect
    understand
    document
    modify
    compile
    test
    commit

over:

    modify many files
    compile
    hope

When uncertain:

search the source tree;
compare R595 and R610;
read the existing patch intent;
explain the uncertainty.

Do not invent NVIDIA internal behavior.

Do not silently change architectural assumptions.

Protect the working workstation.

The objective is not merely:

    "make the patches compile"

The objective is:

    produce a maintainable R610 injector branch
    whose behavior can be demonstrated to eliminate
    the reproducible Blackwell-over-Thunderbolt
    WATCHDOG/GPU command queue failure
    without regressing normal internal NVIDIA GPUs.

================================================================================
END MASTER PROMPT
================================================================================
