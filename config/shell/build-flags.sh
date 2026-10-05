# shellcheck shell=bash
# Build defaults for local compilation on this host: job parallelism for make
# and CMake, the GPU architectures nvcc targets, and Go's amd64 level.
#
# It exports no CFLAGS, CXXFLAGS or RUSTFLAGS. Every cargo build script sees
# those: cc-rs places CFLAGS after a crate's own flags, so a host-wide -O3
# breaks crates that must compile a file at -O0
# (https://github.com/aws/aws-lc-rs/issues/1252), and each distinct RUSTFLAGS
# value is a separate build of every dependency, apart from the builds CI and
# the pre-push hooks make. llama.cpp's CMake already compiles its CPU backend
# for this host (GGML_NATIVE defaults on outside node-llama-cpp's CI mode).
#
# Linux-only: `nproc`, the CUDA architecture and the amd64 level describe the
# Linux dev box.

[ "$(uname -s)" = "Linux" ] || return 0

# Parallelize make and CMake by default. Both honor their own env vars.
if [ -z "${MAKEFLAGS:-}" ]; then
  MAKEFLAGS="-j$(nproc)"
  export MAKEFLAGS
fi
if [ -z "${CMAKE_BUILD_PARALLEL_LEVEL:-}" ]; then
  CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)"
  export CMAKE_BUILD_PARALLEL_LEVEL
fi

# CUDA: target only the GPU compute capabilities actually present in this host.
# 86 = Ampere (RTX 3090 Ti). Any cmake-based CUDA project picks this up and
# skips fat-binary generation for other architectures, cutting compile time
# 5-10x. Update this list when adding GPUs of other generations.
export CMAKE_CUDA_ARCHITECTURES=86

# Go: amd64 microarch level. v4 = AVX-512 + AVX2 + SSE4.2 + BMI2 (Zen 4 supports).
# Without this, `go build` defaults to GOAMD64=v1 (baseline, no SIMD).
export GOAMD64=v4
