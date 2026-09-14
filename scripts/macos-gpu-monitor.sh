#!/usr/bin/env bash
# macos-gpu-monitor.sh — trace Metal GPU usage around any command on macOS.
#
# GPU-bound work (LLM inference, ML, rendering, transcode) is invisible to
# `ps`/`%cpu`: the heavy phase can show a few percent CPU while the GPU is
# pinned near 100%. This wraps a command, traces GPU active residency and power
# via powermetrics for its duration, optionally samples a target process's
# CPU/RSS, then prints peak figures.
#
# Usage:
#   ./macos-gpu-monitor.sh -- <command...>
#   ./macos-gpu-monitor.sh --proc '<pgrep -f pattern>' -- <command...>
#   ./macos-gpu-monitor.sh --no-gpu --proc '<pattern>' -- <command...>   # no sudo
#
# Examples:
#   ./macos-gpu-monitor.sh -- ffmpeg -i in.mov -c:v hevc_videotoolbox out.mp4
#   ./macos-gpu-monitor.sh --proc 'src/cli/qmd.ts serve' -- qmd query "hybrid search"
set -euo pipefail

GPU=1
PROC_PAT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-gpu)
      GPU=0
      shift
      ;;
    --proc)
      PROC_PAT="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done
[[ $# -eq 0 ]] && {
  echo "usage: $0 [--no-gpu] [--proc PATTERN] -- <command...>" >&2
  exit 2
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/gpu-monitor.XXXXXX")"
PS_LOG="$WORKDIR/ps.log"
GPU_LOG="$WORKDIR/gpu.log"
cleanup() {
  [[ -n "${PS_PID:-}" ]] && kill "$PS_PID" 2>/dev/null || true
  [[ -n "${PM_PID:-}" ]] && sudo kill "$PM_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

PM_PID=""
if [[ "$GPU" == 1 ]]; then
  echo "Caching sudo for powermetrics (one prompt)..."
  sudo -v
  # GPU log is a user-owned temp file; the redirect stays user-side (only
  # powermetrics needs root) so reads and cleanup need no sudo.
  # shellcheck disable=SC2024
  sudo powermetrics --samplers gpu_power -i 500 -n 600 >"$GPU_LOG" 2>/dev/null &
  PM_PID=$!
fi

PS_PID=""
if [[ -n "$PROC_PAT" ]]; then
  (while true; do
    P="$(pgrep -f "$PROC_PAT" | head -n1 || true)"
    [[ -n "$P" ]] && ps -o %cpu=,rss= -p "$P" 2>/dev/null
    sleep 1
  done >>"$PS_LOG") &
  PS_PID=$!
fi

echo "Running: $*"
echo "------------------------------------------------------------"
START="$(date +%s.%N)"
"$@" || true
END="$(date +%s.%N)"
echo "------------------------------------------------------------"

[[ -n "$PS_PID" ]] && {
  kill "$PS_PID" 2>/dev/null || true
  PS_PID=""
}
[[ -n "$PM_PID" ]] && {
  sudo kill "$PM_PID" 2>/dev/null || true
  PM_PID=""
}
sleep 1 # let powermetrics flush its last sample

TOTAL="$(awk -v a="$START" -v b="$END" 'BEGIN{printf "%.2f", b-a}')"

PEAK_RES="n/a"
PEAK_PW="n/a"
if [[ "$GPU" == 1 && -s "$GPU_LOG" ]]; then
  PEAK_RES="$(grep -i 'active residency' "$GPU_LOG" | grep -oE '[0-9]+\.[0-9]+%' | tr -d '%' | sort -gr | head -n1 || true)"
  PEAK_MW="$(grep -iE '^GPU Power' "$GPU_LOG" | grep -oE '[0-9]+' | sort -gr | head -n1 || true)"
  [[ -n "$PEAK_RES" ]] && PEAK_RES="${PEAK_RES}%"
  [[ -n "$PEAK_MW" ]] && PEAK_PW="$(awk -v m="$PEAK_MW" 'BEGIN{printf "%.2f W", m/1000}')"
fi

PROC_SUM="(no --proc)"
if [[ -n "$PROC_PAT" && -s "$PS_LOG" ]]; then
  PROC_SUM="$(awk '{if($1+0>c)c=$1+0; if($2+0>r)r=$2+0} END{printf "peak CPU %.1f%%, peak RSS %.0f MB", c, r/1024}' "$PS_LOG")"
fi

cat <<EOF

==================== macOS GPU monitor summary ====================
Command            : $*
total (wall)       : ${TOTAL}s
peak GPU residency : ${PEAK_RES}     <- ~100% = GPU is the bottleneck
peak GPU power     : ${PEAK_PW}
target process     : ${PROC_PAT:-<none>}  ${PROC_SUM}
Logs: $WORKDIR  (gpu.log  ps.log)
===================================================================
EOF
