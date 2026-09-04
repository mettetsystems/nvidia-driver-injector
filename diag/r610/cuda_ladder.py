#!/usr/bin/env python3
"""CUDA driver-API ladder for diag/r610. Operator-run only."""
from __future__ import annotations

import argparse
import ctypes
import os
import sys
import time


CUDA_SUCCESS = 0
CUDA_ERROR_LAUNCH_FAILED = 719


def flush() -> None:
    sys.stdout.flush()
    sys.stderr.flush()


def log(msg: str) -> None:
    print(msg, flush=True)


class CudaError(RuntimeError):
    def __init__(self, code: int, where: str) -> None:
        super().__init__(f"{where} -> CUDA {code}")
        self.code = code
        self.where = where


class Cuda:
    def __init__(self) -> None:
        try:
            self.lib = ctypes.CDLL("libcuda.so.1")
        except OSError as exc:
            raise SystemExit(f"cannot load libcuda.so.1: {exc}") from exc
        self.lib.cuInit.argtypes = [ctypes.c_uint]
        self.lib.cuInit.restype = ctypes.c_int
        self.lib.cuDeviceGetByPCIBusId.argtypes = [
            ctypes.POINTER(ctypes.c_int),
            ctypes.c_char_p,
        ]
        self.lib.cuDeviceGetByPCIBusId.restype = ctypes.c_int
        self.lib.cuCtxCreate_v2.argtypes = [
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_uint,
            ctypes.c_int,
        ]
        self.lib.cuCtxCreate_v2.restype = ctypes.c_int
        self.lib.cuMemAlloc_v2.argtypes = [
            ctypes.POINTER(ctypes.c_ulonglong),
            ctypes.c_size_t,
        ]
        self.lib.cuMemAlloc_v2.restype = ctypes.c_int
        self.lib.cuMemsetD8_v2.argtypes = [
            ctypes.c_ulonglong,
            ctypes.c_ubyte,
            ctypes.c_size_t,
        ]
        self.lib.cuMemsetD8_v2.restype = ctypes.c_int
        self.lib.cuCtxSynchronize.argtypes = []
        self.lib.cuCtxSynchronize.restype = ctypes.c_int
        self.lib.cuMemcpyDtoH_v2.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulonglong,
            ctypes.c_size_t,
        ]
        self.lib.cuMemcpyDtoH_v2.restype = ctypes.c_int
        self.lib.cuMemcpyHtoD_v2.argtypes = [
            ctypes.c_ulonglong,
            ctypes.c_void_p,
            ctypes.c_size_t,
        ]
        self.lib.cuMemcpyHtoD_v2.restype = ctypes.c_int
        self.lib.cuMemHostAlloc.argtypes = [
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.c_size_t,
            ctypes.c_uint,
        ]
        self.lib.cuMemHostAlloc.restype = ctypes.c_int
        self.lib.cuMemFree_v2.argtypes = [ctypes.c_ulonglong]
        self.lib.cuMemFree_v2.restype = ctypes.c_int
        self.lib.cuMemFreeHost.argtypes = [ctypes.c_void_p]
        self.lib.cuMemFreeHost.restype = ctypes.c_int
        self.lib.cuCtxDestroy_v2.argtypes = [ctypes.c_void_p]
        self.lib.cuCtxDestroy_v2.restype = ctypes.c_int
        self.lib.cuLaunchKernel.argtypes = [
            ctypes.c_void_p,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
        ]
        self.lib.cuLaunchKernel.restype = ctypes.c_int

    def check(self, code: int, where: str) -> None:
        if code != CUDA_SUCCESS:
            raise CudaError(code, where)


def pci_bus_id(bdf: str) -> bytes:
    # sysfs uses 0000:8d:00.0 ; CUDA wants 0000:8D:00.0 or 8d:00.0
    return bdf.encode("ascii")


def stage_init_ctx(cu: Cuda, bdf: str):
    log(f"BEFORE cuInit(0) on BDF {bdf}")
    cu.check(cu.lib.cuInit(0), "cuInit")
    dev = ctypes.c_int()
    log(f"BEFORE cuDeviceGetByPCIBusId({bdf})")
    cu.check(
        cu.lib.cuDeviceGetByPCIBusId(ctypes.byref(dev), pci_bus_id(bdf)),
        "cuDeviceGetByPCIBusId",
    )
    log(f"device ordinal={dev.value}")
    ctx = ctypes.c_void_p()
    log("BEFORE cuCtxCreate_v2")
    cu.check(cu.lib.cuCtxCreate_v2(ctypes.byref(ctx), 0, dev.value), "cuCtxCreate_v2")
    return ctx


def memcpy_roundtrip(cu: Cuda, nbytes: int, pinned: bool) -> None:
    dptr = ctypes.c_ulonglong()
    log(f"BEFORE cuMemAlloc {nbytes} bytes")
    cu.check(cu.lib.cuMemAlloc_v2(ctypes.byref(dptr), nbytes), "cuMemAlloc")
    host: ctypes.Array[ctypes.c_ubyte] | ctypes.c_void_p
    raw: ctypes.c_void_p | None = None
    if pinned:
        raw = ctypes.c_void_p()
        log(f"BEFORE cuMemHostAlloc {nbytes} bytes (PINNED)")
        cu.check(cu.lib.cuMemHostAlloc(ctypes.byref(raw), nbytes, 0), "cuMemHostAlloc")
        buf = (ctypes.c_ubyte * nbytes).from_address(raw.value)
    else:
        buf = (ctypes.c_ubyte * nbytes)()
        raw = None
    for i in range(min(nbytes, 4096)):
        buf[i] = (i * 17) & 0xFF
    if nbytes > 4096:
        buf[nbytes - 1] = 0x5A
    log(f"BEFORE cuMemcpyHtoD {nbytes}")
    t0 = time.perf_counter()
    src = raw if pinned else ctypes.cast(buf, ctypes.c_void_p)
    if not pinned:
        src = ctypes.addressof(buf)
        cu.check(cu.lib.cuMemcpyHtoD_v2(dptr, src, nbytes), "cuMemcpyHtoD")
    else:
        cu.check(cu.lib.cuMemcpyHtoD_v2(dptr, raw, nbytes), "cuMemcpyHtoD")
    h2d = time.perf_counter() - t0
    log(f"BEFORE cuMemsetD8 pattern check prep skip; H2D {h2d:.4f}s")
    # Clear a host verify buffer
    if pinned:
        verify_ptr = ctypes.c_void_p()
        cu.check(
            cu.lib.cuMemHostAlloc(ctypes.byref(verify_ptr), nbytes, 0),
            "cuMemHostAlloc verify",
        )
        vbuf = (ctypes.c_ubyte * nbytes).from_address(verify_ptr.value)
        ctypes.memset(verify_ptr, 0, nbytes)
        log(f"BEFORE cuMemcpyDtoH {nbytes} (pinned)")
        t1 = time.perf_counter()
        cu.check(cu.lib.cuMemcpyDtoH_v2(verify_ptr, dptr, nbytes), "cuMemcpyDtoH")
        d2h = time.perf_counter() - t1
        cu.check(cu.lib.cuCtxSynchronize(), "cuCtxSynchronize")
        if vbuf[0] != buf[0] or vbuf[min(nbytes, 4096) - 1] != buf[min(nbytes, 4096) - 1]:
            raise SystemExit("byte verification FAILED")
        if nbytes > 4096 and vbuf[nbytes - 1] != 0x5A:
            raise SystemExit("byte verification FAILED (tail)")
        log(f"D2H {d2h:.4f}s verify OK")
        cu.lib.cuMemFreeHost(verify_ptr)
        cu.lib.cuMemFreeHost(raw)
    else:
        vbuf = (ctypes.c_ubyte * nbytes)()
        log(f"BEFORE cuMemcpyDtoH {nbytes} (pageable)")
        t1 = time.perf_counter()
        cu.check(
            cu.lib.cuMemcpyDtoH_v2(ctypes.addressof(vbuf), dptr, nbytes),
            "cuMemcpyDtoH",
        )
        d2h = time.perf_counter() - t1
        cu.check(cu.lib.cuCtxSynchronize(), "cuCtxSynchronize")
        if vbuf[0] != buf[0] or vbuf[min(nbytes, 4096) - 1] != buf[min(nbytes, 4096) - 1]:
            raise SystemExit("byte verification FAILED")
        if nbytes > 4096 and vbuf[nbytes - 1] != 0x5A:
            raise SystemExit("byte verification FAILED (tail)")
        log(f"D2H {d2h:.4f}s verify OK  H2D={nbytes / h2d / 1e9:.3f} GB/s D2H={nbytes / d2h / 1e9:.3f} GB/s")
    cu.lib.cuMemFree_v2(dptr)


def vram_4k(cu: Cuda) -> None:
    nbytes = 4096
    dptr = ctypes.c_ulonglong()
    log("BEFORE cuMemAlloc 4096")
    cu.check(cu.lib.cuMemAlloc_v2(ctypes.byref(dptr), nbytes), "cuMemAlloc")
    log("BEFORE cuMemsetD8 0xAB")
    cu.check(cu.lib.cuMemsetD8_v2(dptr, 0xAB, nbytes), "cuMemsetD8")
    log("BEFORE cuCtxSynchronize")
    cu.check(cu.lib.cuCtxSynchronize(), "cuCtxSynchronize")
    host = (ctypes.c_ubyte * nbytes)()
    log("BEFORE cuMemcpyDtoH 4096")
    cu.check(cu.lib.cuMemcpyDtoH_v2(ctypes.addressof(host), dptr, nbytes), "cuMemcpyDtoH")
    cu.check(cu.lib.cuCtxSynchronize(), "cuCtxSynchronize")
    if any(b != 0xAB for b in host):
        raise SystemExit("4k byte verification FAILED")
    log("4 KiB verify OK")
    cu.lib.cuMemFree_v2(dptr)


def soak(cu: Cuda, bdf: str, seconds: int, cycles: int) -> None:
    end = time.time() + seconds
    n = 0
    while time.time() < end and (cycles <= 0 or n < cycles):
        ctx = stage_init_ctx(cu, bdf)
        vram_4k(cu)
        cu.lib.cuCtxDestroy_v2(ctx)
        n += 1
        log(f"soak cycle {n}")
    log(f"soak done cycles={n}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--stage", required=True)
    p.add_argument("--bdf", required=True)
    p.add_argument("--seconds", type=int, default=0)
    p.add_argument("--cycles", type=int, default=0)
    args = p.parse_args()
    cu = Cuda()
    try:
        if args.stage == "init-ctx":
            ctx = stage_init_ctx(cu, args.bdf)
            log("PASS init+context")
            cu.lib.cuCtxDestroy_v2(ctx)
        elif args.stage == "vram-4k":
            ctx = stage_init_ctx(cu, args.bdf)
            vram_4k(cu)
            log("PASS vram-4k")
            cu.lib.cuCtxDestroy_v2(ctx)
        elif args.stage == "xfer-256m":
            ctx = stage_init_ctx(cu, args.bdf)
            memcpy_roundtrip(cu, 256 * 1024 * 1024, pinned=False)
            log("PASS xfer-256m pageable")
            cu.lib.cuCtxDestroy_v2(ctx)
        elif args.stage == "xfer-pinned":
            ctx = stage_init_ctx(cu, args.bdf)
            memcpy_roundtrip(cu, 256 * 1024 * 1024, pinned=True)
            log("PASS xfer-pinned")
            cu.lib.cuCtxDestroy_v2(ctx)
        elif args.stage == "compute-smoke":
            ctx = stage_init_ctx(cu, args.bdf)
            vram_4k(cu)
            log("PASS compute-smoke (memset as stand-in; no fatbin kernel shipped)")
            cu.lib.cuCtxDestroy_v2(ctx)
        elif args.stage == "soak":
            soak(cu, args.bdf, args.seconds, args.cycles)
            log("PASS soak")
        else:
            raise SystemExit(f"unknown stage {args.stage}")
    except CudaError as exc:
        log(f"FAIL {exc}")
        if exc.code == CUDA_ERROR_LAUNCH_FAILED:
            log("CUDA 719 — this is the stock failure mode. Dump kernel logs.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
