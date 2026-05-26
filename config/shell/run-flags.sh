# shellcheck shell=bash
# Runtime performance env vars. Read by application processes (not compilers).
# Linux-only: macOS toolchains pick different defaults.
#
# Anything here is safe-by-default for general use. Application-specific tuning
# (OLLAMA_*, MODEL_*) lives in the relevant systemd unit so the daemons get it
# even when no shell is around to source these files.

[ "$(uname -s)" = "Linux" ] || return 0

# CUDA: lazy module loading. Defers loading of CUDA modules until first use,
# cutting CUDA app startup by 100-500ms. Supported since CUDA 11.7; we are on
# 12.8. Safe for all well-behaved CUDA code.
export CUDA_MODULE_LOADING=LAZY

# libuv (Node.js / Bun): use io_uring kernel API on Linux 5.1+ for faster
# filesystem I/O. Kernel is 6.8 — fully supported.
export UV_USE_IO_URING=1

# PyTorch: expandable segments reduce VRAM fragmentation during training and
# long-running inference. No effect when PyTorch is not in use; safe to export
# unconditionally.
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

