# shellcheck shell=bash
# Build-flag defaults for local compilation on this host. Anything built here
# will also run here, so we trade portability of the resulting binaries for
# CPU-specific optimization (AVX-512, BMI2, etc on Zen 4 / Ryzen 7800X3D).
#
# Linux-only: macOS toolchains pick up native tuning through Xcode and brew
# without needing these env vars, and aggressive flags occasionally break
# brew formulas on macOS.

[ "$(uname -s)" = "Linux" ] || return 0

# -march=native     emit instructions specific to the build host (AVX-512 on Zen 4)
# -mtune=native     schedule instructions for the build host microarchitecture
# -O3               aggressive optimization (loop unrolling, vectorization)
# -pipe             use pipes between compile stages instead of temp files
#
# Prepended so a downstream caller can still override by re-exporting CFLAGS.
export CFLAGS="-O3 -march=native -mtune=native -pipe ${CFLAGS:-}"
export CXXFLAGS="-O3 -march=native -mtune=native -pipe ${CXXFLAGS:-}"

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

# Rust: target the build host CPU (equivalent of CFLAGS -march=native for cargo).
# Affects every `cargo build` on this host.
export RUSTFLAGS="${RUSTFLAGS:-} -C target-cpu=native"

# Go: amd64 microarch level. v4 = AVX-512 + AVX2 + SSE4.2 + BMI2 (Zen 4 supports).
# Without this, `go build` defaults to GOAMD64=v1 (baseline, no SIMD).
export GOAMD64=v4
