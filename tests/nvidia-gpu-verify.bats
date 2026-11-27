#!/usr/bin/env bats
# run-tests: parallel
# Tests for stow/local/dot-local/bin/nvidia-gpu-verify, which checks that the
# NVIDIA -server userspace matches the loaded kernel module, that no non-server
# driver package is installed, that DKMS built the module for every kernel, and
# that NVENC, NVDEC, Vulkan, and the apt guard answer.
#
# dpkg-query, apt-cache, vulkaninfo, python3, timeout, and dkms are stubs that
# answer from files under $FIXTURE, so a test writes only the answer it is
# about, and systemd-notify logs its arguments to $FIXTURE/notify. The python3 stub runs the real interpreter when the test writes no
# canned probe answer, and the timeout stub runs its command unless the test
# asks it to time out. The loaded module comes from a fixture file through
# NVIDIA_GPU_VERIFY_PROC_VERSION, the kernels from a shared /boot stand-in, and
# the deployed guard from a shared copy of the repo's, which
# scripts/nvidia-deploy.sh --check compares for real.
#
# Run: bats tests/nvidia-gpu-verify.bats

load lib/platform

CHECK="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/nvidia-gpu-verify"
ADDONS=(nvidia-utils libnvidia-compute libnvidia-gl libnvidia-encode libnvidia-decode)
DKMS_NEXT="next: /usr/sbin/dkms status nvidia"
GUARD_NAME=00-nvidia-server-branch.pref
KERNELS=(6.8.0-146-generic 6.8.0-151-generic)

setup_file() {
  local stubs="$BATS_FILE_TMPDIR/stubs"
  stub_uname "$stubs"
  REAL_PYTHON3="$(command -v python3 || true)"
  export REAL_PYTHON3

  cat >"$stubs/dpkg-query" <<'EOF'
#!/bin/sh
# dpkg-query -W -f=FORMAT PATTERN..., answered from $FIXTURE/dpkg
# ("<package> <version> [<source>]"), with dpkg's three-character status "ii ".
# A line without a source has the package's own name as its source, as dpkg
# reports for a package built from a source of the same name.
format=$2
shift 2
found=1
for pattern in "$@"; do
  while read -r pkg ver src; do
    case $pkg in
      $pattern)
        case $format in
          *source:Package*) printf 'ii  %s %s %s\n' "$pkg" "$ver" "${src:-$pkg}" ;;
          *Package*) printf 'ii  %s %s\n' "$pkg" "$ver" ;;
          *Version*) printf 'ii  %s\n' "$ver" ;;
          *) printf 'ii \n' ;;
        esac
        found=0
        ;;
    esac
  done <"$FIXTURE/dpkg"
done
[ "$found" -eq 0 ] || { echo "dpkg-query: no packages found matching $*" >&2; exit 1; }
EOF
  cat >"$stubs/apt-cache" <<'EOF'
#!/bin/sh
# apt-cache policy PACKAGE..., answered from $FIXTURE/apt ("<package> <candidate>").
shift
for name in "$@"; do
  while read -r pkg cand; do
    [ "$pkg" = "$name" ] && printf '%s:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "$pkg" "$cand"
  done <"$FIXTURE/apt"
done
exit 0
EOF
  cat >"$stubs/vulkaninfo" <<'EOF'
#!/bin/sh
# Exit 127, as the shell does for a missing command, when the test writes no summary.
[ -f "$FIXTURE/vulkaninfo" ] || exit 127
cat "$FIXTURE/vulkaninfo"
EOF
  cat >"$stubs/python3" <<'EOF'
#!/bin/sh
if [ -f "$FIXTURE/probe" ]; then
  cat "$FIXTURE/probe"
else
  exec "$REAL_PYTHON3" "$@"
fi
EOF
  cat >"$stubs/timeout" <<'EOF'
#!/bin/sh
# timeout DURATION COMMAND...: exit 124 when $FIXTURE/timeout-COMMAND exists,
# as GNU timeout does when the limit passes; otherwise run the command.
shift
[ -f "$FIXTURE/timeout-$1" ] && exit 124
exec "$@"
EOF
  cat >"$stubs/dkms" <<'EOF'
#!/bin/sh
# dkms status nvidia, answered from $FIXTURE/dkms.
[ ! -f "$FIXTURE/dkms" ] || cat "$FIXTURE/dkms"
EOF
  cat >"$stubs/systemd-notify" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FIXTURE/notify"
EOF
  chmod 555 "$stubs/dpkg-query" "$stubs/apt-cache" "$stubs/vulkaninfo" "$stubs/python3" "$stubs/timeout" "$stubs/dkms" \
    "$stubs/systemd-notify"

  mkdir -p "$BATS_FILE_TMPDIR/boot" "$BATS_FILE_TMPDIR/prefs"
  : >"$BATS_FILE_TMPDIR/boot/vmlinuz-6.8.0-146-generic"
  : >"$BATS_FILE_TMPDIR/boot/vmlinuz-6.8.0-151-generic"
  cp "$BATS_TEST_DIRNAME/../config/apt/preferences.d/$GUARD_NAME" "$BATS_FILE_TMPDIR/prefs/"
}

setup() {
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE"
  : >"$FIXTURE/dpkg"
  : >"$FIXTURE/apt"
  export NVIDIA_GPU_VERIFY_PROC_VERSION="$FIXTURE/version"
  export NVIDIA_GPU_VERIFY_BOOT_DIR="$BATS_FILE_TMPDIR/boot"
  export NVIDIA_GPU_VERIFY_DKMS="$BATS_FILE_TMPDIR/stubs/dkms"
  export NVIDIA_DEPLOY_PREFERENCES_DIR="$BATS_FILE_TMPDIR/prefs"
  export STUB_UNAME=Linux
  unset NOTIFY_SOCKET
  PATH="$BATS_FILE_TMPDIR/stubs:$PATH"
}

# loaded_module <version>: the first line /proc/driver/nvidia/version shows.
loaded_module() {
  printf 'NVRM version: NVIDIA UNIX Open Kernel Module for x86_64  %s  Release Build  (dvs-builder@U22)  Tue Jul  7 12:18:12 UTC 2026\n' "$1" >"$FIXTURE/version"
}

# installed <branch> <debian version> [package...]: dpkg holds the kernel
# common package and each named add-on (all five by default) at that version,
# each built from the branch's -server driver source.
installed() {
  local branch="$1" ver="$2" name
  shift 2
  [ "$#" -gt 0 ] || set -- "${ADDONS[@]}"
  for name in nvidia-kernel-common "$@"; do
    printf '%s-%s-server %s nvidia-graphics-drivers-%s-server\n' "$name" "$branch" "$ver" "$branch" >>"$FIXTURE/dpkg"
  done
}

# dkms_built <version> [kernel...]: dkms status lists the module as installed
# for each kernel (both in the /boot stand-in by default).
dkms_built() {
  local ver="$1" kernel
  shift
  [ "$#" -gt 0 ] || set -- "${KERNELS[@]}"
  : >"$FIXTURE/dkms"
  for kernel in "$@"; do
    printf 'nvidia/%s, %s, x86_64: installed\n' "$ver" "$kernel" >>"$FIXTURE/dkms"
  done
}

vulkan_devices() {
  : >"$FIXTURE/vulkaninfo"
  printf 'Devices:\n========\n' >>"$FIXTURE/vulkaninfo"
  local i=0 entry
  for entry in "$@"; do
    printf 'GPU%d:\n\tdriverName         = %s\n\tdriverInfo         = %s\n' "$i" "${entry%%:*}" "${entry#*:}" >>"$FIXTURE/vulkaninfo"
    i=$((i + 1))
  done
}

# healthy <version> <debian version>: everything a passing run needs.
healthy() {
  local branch="${1%%.*}"
  loaded_module "$1"
  installed "$branch" "$2"
  printf 'nvidia-dkms-%s-server-open %s nvidia-graphics-drivers-%s-server\n' "$branch" "$2" "$branch" >>"$FIXTURE/dpkg"
  dkms_built "${2%%-*}"
  printf 'nvenc ok 13.0\nnvdec ok h264=yes/4096 hevc=yes/8192 av1=yes/8192\n' >"$FIXTURE/probe"
  vulkan_devices "NVIDIA:$1" "llvmpipe:Mesa 25.2.8"
  printf 'libnvidia-encode-%s (none)\nlibnvidia-encode (none)\n' "$branch" >"$FIXTURE/apt"
}

# The pending-reboot shape: one FAIL pointing at DKMS, no install or reboot
# line, and the three engine steps skipped.
assert_userspace_mismatch() {
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  no -580-server package is at the loaded module's version 580.178.04; the installed -server userspace is at $1"* ]]
  [[ "$output" == *"$DKMS_NEXT"* ]]
  [[ "$output" != *"apt-get install"* ]]
  [[ "$output" != *"next: sudo reboot"* ]]
  [[ "$output" != *"is not installed"* ]]
  [[ "$output" == *"SKIP  NVENC not probed"* ]]
  [[ "$output" == *"SKIP  NVDEC not probed"* ]]
  [[ "$output" == *"SKIP  Vulkan not checked"* ]]
}

@test "a healthy 580 host passes every check (exit 0)" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  run "$CHECK"
  [ "$status" -eq 0 ]
  local name
  for name in "${ADDONS[@]}"; do
    [[ "$output" == *"PASS  $name-580-server 580.178.04-0ubuntu0.24.04.1"* ]]
  done
  [[ "$output" == *"PASS  NVENC answers: API 13.0"* ]]
  [[ "$output" == *"PASS  NVDEC answers: h264=yes/4096 hevc=yes/8192 av1=yes/8192"* ]]
  [[ "$output" == *"PASS  Vulkan lists the NVIDIA device at 580.178.04"* ]]
  [[ "$output" == *"PASS  2 other -580-server package(s) at 580.178.04"* ]]
  [[ "$output" == *"PASS  no package the apt guard refuses is installed"* ]]
  [[ "$output" == *"PASS  DKMS has built nvidia 580.178.04 for every kernel: ${KERNELS[*]}"* ]]
  [[ "$output" == *"PASS  the apt guard in $NVIDIA_DEPLOY_PREFERENCES_DIR matches the repo's copy"* ]]
  [[ "$output" == *"PASS  apt guard in effect"* ]]
  [[ "$output" == *"nvidia-gpu-verify: all checks passed"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "a missing add-on fails with an install pinned to the loaded version" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  : >"$FIXTURE/dpkg"
  installed 580 580.178.04-0ubuntu0.24.04.1 nvidia-utils libnvidia-compute libnvidia-gl libnvidia-decode
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  libnvidia-encode-580-server is not installed"* ]]
  [[ "$output" == *'next: sudo NEEDRESTART_MODE=l apt-get install "libnvidia-encode-580-server=580.178.04-0ubuntu0.24.04.1"'* ]]
}

@test "a 615 host with its -615-server set passes, so nothing is pinned to 580" {
  healthy 615.71.09 615.71.09-0ubuntu0.24.04.1
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  kernel module 615.71.09 loaded (branch 615)"* ]]
  [[ "$output" == *"PASS  libnvidia-encode-615-server 615.71.09-0ubuntu0.24.04.1"* ]]
}

@test "a userspace upgraded past the loaded module fails once, pointing at DKMS" {
  healthy 580.178.04 580.196.07-0ubuntu0.24.04.1
  run "$CHECK"
  assert_userspace_mismatch 580.196.07
  [[ "$output" == *"SKIP  other -580-server packages not checked"* ]]
  [[ "$output" == *"PASS  DKMS has built nvidia 580.196.07 for every kernel"* ]]
}

@test "a partial upgrade with encode and decode missing fails once, with no install line" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  : >"$FIXTURE/dpkg"
  installed 580 580.196.07-0ubuntu0.24.04.1 nvidia-utils libnvidia-compute libnvidia-gl
  run "$CHECK"
  assert_userspace_mismatch 580.196.07
}

@test "the branch trap's leftover 615 kernel-common fails naming 615, with no install or reboot line" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'nvidia-kernel-common-615-server 615.71.09-0ubuntu0.24.04.1\n' >"$FIXTURE/dpkg"
  run "$CHECK"
  assert_userspace_mismatch 615.71.09
}

@test "one add-on at another version fails naming it and both versions" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  : >"$FIXTURE/dpkg"
  installed 580 580.178.04-0ubuntu0.24.04.1 nvidia-utils libnvidia-compute libnvidia-gl libnvidia-decode
  printf 'libnvidia-encode-580-server 580.126.20-0ubuntu0.24.04.2\n' >>"$FIXTURE/dpkg"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  libnvidia-encode-580-server is 580.126.20-0ubuntu0.24.04.2 and the loaded module is 580.178.04"* ]]
  [[ "$output" == *'apt-get install "libnvidia-encode-580-server=580.178.04-0ubuntu0.24.04.1"'* ]]
}

@test "a -server package of another branch, or older firmware, fails with a remove line each" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf '%s\n' \
    'nvidia-utils-570-server 570.211.01-0ubuntu1.24.04.1 nvidia-graphics-drivers-570-server' \
    'nvidia-firmware-580-server-580.126.20 580.126.20-0ubuntu0.24.04.2 nvidia-graphics-drivers-580-server' \
    >>"$FIXTURE/dpkg"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  nvidia-utils-570-server 570.211.01-0ubuntu1.24.04.1 is from branch 570, and the loaded module is branch 580"$'\n'"      next: sudo apt-get remove nvidia-utils-570-server"* ]]
  [[ "$output" == *"FAIL  nvidia-firmware-580-server-580.126.20 is firmware for driver 580.126.20, and the loaded module is 580.178.04"$'\n'"      next: sudo apt-get remove nvidia-firmware-580-server-580.126.20"* ]]
  [[ "$output" == *"nvidia-gpu-verify: 2 check(s) failed"* ]]
}

@test "a -server package of the loaded branch at another version fails pointing at DKMS, with no install line" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'nvidia-compute-utils-580-server 580.196.07-0ubuntu0.24.04.1 nvidia-graphics-drivers-580-server\n' >>"$FIXTURE/dpkg"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  nvidia-compute-utils-580-server is 580.196.07-0ubuntu0.24.04.1 and the loaded module is 580.178.04: a reboot is pending, or an upgrade stopped partway"$'\n'"      $DKMS_NEXT"* ]]
  [[ "$output" != *"apt-get install"* ]]
  [[ "$output" == *"nvidia-gpu-verify: 1 check(s) failed"* ]]
}

@test "an installed package the guard refuses fails naming its source; NVIDIA packages it allows pass" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf '%s\n' \
    'libnvidia-encode-580 580.196.11-1ubuntu1 nvidia-graphics-drivers-580' \
    'nvidia-open-580 580.196.11-1 nvidia-open' \
    'cuda-drivers 620.70.10-1 cuda-drivers' \
    'nvidia-fabricmanager-580 580.178.04-1 fabric-manager-580' \
    'libnvidia-egl-wayland1 1:1.1.21-1ubuntu1 egl-wayland' \
    'libnvidia-container1 1.20.1-1 libnvidia-container' \
    >>"$FIXTURE/dpkg"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  libnvidia-encode-580 580.196.11-1ubuntu1 is a non-server driver package (source nvidia-graphics-drivers-580), which conflicts with the -server driver"$'\n'"      next: sudo apt-get remove libnvidia-encode-580"* ]]
  [[ "$output" == *"FAIL  nvidia-open-580 580.196.11-1 is a non-server driver package (source nvidia-open)"* ]]
  [[ "$output" == *"FAIL  cuda-drivers 620.70.10-1 is a non-server driver package (source cuda-drivers)"* ]]
  [[ "$output" == *"nvidia-gpu-verify: 3 check(s) failed"* ]]
}

@test "a guard missing from, or different in, the preferences directory fails naming the deploy" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  export NVIDIA_DEPLOY_PREFERENCES_DIR="$BATS_TEST_TMPDIR/prefs"
  mkdir -p "$NVIDIA_DEPLOY_PREFERENCES_DIR"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  $NVIDIA_DEPLOY_PREFERENCES_DIR/$GUARD_NAME is not deployed"$'\n'"      next: sudo ~/dotfiles/scripts/nvidia-deploy.sh"* ]]
  printf 'Package: *\nPin: version *\nPin-Priority: 500\n' >"$NVIDIA_DEPLOY_PREFERENCES_DIR/$GUARD_NAME"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  $NVIDIA_DEPLOY_PREFERENCES_DIR/$GUARD_NAME differs from config/apt/preferences.d/$GUARD_NAME"$'\n'"      next: sudo ~/dotfiles/scripts/nvidia-deploy.sh"* ]]
}

@test "a kernel without an installed DKMS build fails naming it; no nvidia-dkms package skips" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  dkms_built 580.178.04 6.8.0-146-generic
  printf 'nvidia/580.178.04, 6.8.0-151-generic, x86_64: built\n' >>"$FIXTURE/dkms"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  DKMS has not built nvidia 580.178.04 for kernel 6.8.0-151-generic, so a boot into it comes up with no GPU"$'\n'"      next: sudo dkms install nvidia/580.178.04 -k 6.8.0-151-generic"* ]]
  [[ "$output" != *"for kernel 6.8.0-146-generic"* ]]
  dkms_built 580.126.20
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  DKMS has not built nvidia 580.178.04 for kernel 6.8.0-146-generic"* ]]
  grep -v '^nvidia-dkms-' "$FIXTURE/dpkg" >"$FIXTURE/dpkg.new"
  cp "$FIXTURE/dpkg.new" "$FIXTURE/dpkg"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  no nvidia-dkms package installed; DKMS builds not checked"* ]]
}

@test "under systemd a failed run sets the unit's status to its first FAIL and that FAIL's next command" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'nvidia-utils-570-server 570.211.01-0ubuntu1.24.04.1 nvidia-graphics-drivers-570-server\n' >>"$FIXTURE/dpkg"
  printf 'libnvidia-encode-580 580.196.11-1ubuntu1\n' >"$FIXTURE/apt"
  run env NOTIFY_SOCKET="$BATS_TEST_TMPDIR/notify.sock" "$CHECK"
  [ "$status" -eq 1 ]
  [ "$(cat "$FIXTURE/notify")" = "--status=nvidia-utils-570-server 570.211.01-0ubuntu1.24.04.1 is from branch 570, and the loaded module is branch 580; next: sudo apt-get remove nvidia-utils-570-server" ]
  rm -f "$FIXTURE/notify"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [ ! -e "$FIXTURE/notify" ]
}

@test "under systemd a passing run sets no status" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  run env NOTIFY_SOCKET="$BATS_TEST_TMPDIR/notify.sock" "$CHECK"
  [ "$status" -eq 0 ]
  [ ! -e "$FIXTURE/notify" ]
}

@test "an installed driver with no loaded module fails, pointing at DKMS" {
  installed 580 580.178.04-0ubuntu0.24.04.1
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  the NVIDIA driver is installed but its kernel module is not loaded"* ]]
  [[ "$output" == *"$DKMS_NEXT"* ]]
}

@test "a host with no NVIDIA driver notes it and exits 0 without other checks" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == "NOTE  no NVIDIA driver on this host; nothing to check" ]]
}

@test "macOS notes the check is Linux-only and exits 0" {
  export STUB_UNAME=Darwin
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Linux-only; nothing to check on Darwin"* ]]
}

@test "an encode or decode library that fails to load fails its step" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'nvenc load-failed libnvidia-encode.so.1: cannot open shared object file\nnvdec load-failed libnvcuvid.so.1: cannot open shared object file\n' >"$FIXTURE/probe"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  NVENC does not answer: nvenc load-failed libnvidia-encode.so.1"* ]]
  [[ "$output" == *"next: /sbin/ldconfig -p | grep libnvidia-encode"* ]]
  [[ "$output" == *"FAIL  NVDEC does not answer: nvdec load-failed libnvcuvid.so.1"* ]]
  [[ "$output" == *"next: /sbin/ldconfig -p | grep libnvcuvid"* ]]
}

@test "a probe that dies with a traceback fails on one line per engine" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'Traceback (most recent call last):\n  File "<string>", line 3, in <module>\nRuntimeError: probe died\n' >"$FIXTURE/probe"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  NVENC does not answer: no answer from the probe: RuntimeError: probe died"* ]]
  [[ "$output" == *"FAIL  NVDEC does not answer: no answer from the probe: RuntimeError: probe died"* ]]
  [[ "$output" != *Traceback* ]]
  [[ "$output" != *'File "<string>"'* ]]
}

@test "a CUDA failure in the decode probe names the CUDA error and points at nvidia-smi" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'nvenc ok 13.0\nnvdec cuda-failed cuDevicePrimaryCtxRetain=CUDA_ERROR_OUT_OF_MEMORY\n' >"$FIXTURE/probe"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  NVDEC does not answer: nvdec cuda-failed cuDevicePrimaryCtxRetain=CUDA_ERROR_OUT_OF_MEMORY"$'\n'"      next: nvidia-smi"* ]]
}

@test "a probe or vulkaninfo that outlives the timeout fails, pointing at nvidia-smi" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  : >"$FIXTURE/timeout-python3"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  the NVENC and NVDEC probe did not finish within 30 s; the GPU may be wedged"$'\n'"      next: nvidia-smi"* ]]
  [[ "$output" == *"PASS  Vulkan lists the NVIDIA device"* ]]
  rm -f "$FIXTURE/timeout-python3"
  : >"$FIXTURE/timeout-vulkaninfo"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  vulkaninfo did not finish within 30 s; the GPU may be wedged"$'\n'"      next: nvidia-smi"* ]]
}

@test "the real probe reports the loader's reason on a host without the NVIDIA libraries" {
  [ -n "$REAL_PYTHON3" ] || skip "python3 not installed"
  ! "$REAL_PYTHON3" -I -c 'import ctypes; ctypes.CDLL("libnvidia-encode.so.1")' 2>/dev/null ||
    skip "libnvidia-encode.so.1 loads on this host"
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  rm -f "$FIXTURE/probe"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  NVENC does not answer: nvenc load-failed libnvidia-encode.so.1"* ]]
  [[ "$output" == *"FAIL  NVDEC does not answer: nvdec load-failed lib"* ]]
}

@test "Vulkan listing only llvmpipe fails; vulkaninfo absent skips" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  vulkan_devices "llvmpipe:Mesa 25.2.8"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  Vulkan lists no NVIDIA device at 580.178.04"* ]]
  rm -f "$FIXTURE/vulkaninfo"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  vulkaninfo not found"* ]]
}

@test "apt offering the non-server encode library fails naming the deploy" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'libnvidia-encode-580 580.196.11-1ubuntu1\n' >"$FIXTURE/apt"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  apt offers libnvidia-encode-580 580.196.11-1ubuntu1, which removes the -server driver"* ]]
  [[ "$output" == *"next: sudo ~/dotfiles/scripts/nvidia-deploy.sh"* ]]
}

@test "apt offering only the unversioned encode library fails naming the deploy" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  printf 'libnvidia-encode 580.105.08-0ubuntu1\n' >"$FIXTURE/apt"
  run "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  apt offers libnvidia-encode 580.105.08-0ubuntu1, which removes the -server driver"* ]]
  [[ "$output" == *"next: sudo ~/dotfiles/scripts/nvidia-deploy.sh"* ]]
}

@test "apt knowing neither non-server encode name skips the guard step" {
  healthy 580.178.04 580.178.04-0ubuntu0.24.04.1
  : >"$FIXTURE/apt"
  run "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  apt knows no non-server encode package"* ]]
}

@test "--help prints usage (exit 0); an unknown argument is a usage error (exit 2)" {
  run "$CHECK" --help
  [ "$status" -eq 0 ]
  [[ "$output" == "usage: nvidia-gpu-verify"* ]]
  [[ "$output" == *"read-only"* ]]
  [[ "$output" == *"starts with sudo needs root"* ]]
  run "$CHECK" --bogus
  [ "$status" -eq 2 ]
}
