#!/usr/bin/env bash
# Rebuild node-llama-cpp prebuilt bindings against the current system libs.
#
# When: run after an NVIDIA driver branch swap (or any change to Vulkan/CUDA
# ICDs) if qmd queries become slow or `nvidia-smi --query-compute-apps` no
# longer shows the qmd bun process as a GPU client.
#
# What: downloads the matching llama.cpp source for the installed
# node-llama-cpp version, compiles fresh bindings, and verifies CUDA +
# Vulkan availability. Then restarts qmd-serve.
#
# This is the belt-and-suspenders companion to the
# `Environment=NODE_LLAMA_CPP_GPU=cuda` pin in the qmd-serve systemd unit.
# The env var pin is sufficient on its own when the CUDA prebuilt is
# healthy; this script makes Vulkan healthy too as a fallback path.
#
# Note: the CUDA compile is ~5x faster when `config/shell/build-flags.sh` is
# sourced before this script runs, since its CMAKE_CUDA_ARCHITECTURES=86 pins
# nvcc to Ampere only. The dotfiles .profile auto-loader sources it on every
# interactive and SSH-driven zsh, so this normally happens for free. The CPU
# backend needs no compiler flags: a local llama.cpp build compiles for this
# host on its own (GGML_NATIVE).

set -euo pipefail

QMD_DIR="${QMD_DIR:-$HOME/dev/qmd}"

for cmd in npx cmake gcc make; do
  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd is required but not on PATH (try: brew install $cmd)" >&2
    exit 1
  }
done

[ -d "$QMD_DIR/node_modules/node-llama-cpp" ] || {
  echo "ERROR: $QMD_DIR/node_modules/node-llama-cpp not found" >&2
  echo "Run \`bun install\` (or \`npm install\`) in \$QMD_DIR first." >&2
  exit 1
}

echo "==> stopping qmd-serve so node-llama-cpp files can be rewritten"
systemctl --user stop qmd-serve.service || true

cd "$QMD_DIR"

echo "==> downloading llama.cpp source for the installed node-llama-cpp version"
npx --no node-llama-cpp source download

echo "==> compiling bindings against current system libraries"
npx --no node-llama-cpp source build

echo "==> verifying backends"
npx --no node-llama-cpp inspect gpu || true

echo "==> restarting qmd-serve"
systemctl --user start qmd-serve.service
sleep 2
systemctl --user status qmd-serve.service --no-pager | head -5 || true

echo
echo "Done. Run a qmd query and watch \`nvidia-smi --query-compute-apps\` to"
echo "confirm the qmd bun PID appears as a CUDA client."
