#!/usr/bin/env bats
# run-tests: parallel
# Tests for scripts/nvidia-deploy.sh, which copies config/apt/preferences.d/
# into /etc/apt/preferences.d/, and for the NVIDIA guard it deploys.
#
# The guard tests drive real apt against a throwaway flat repository of stub
# packages, with every apt state, cache, and config path inside
# BATS_FILE_TMPDIR, so they test what apt does with the guard's patterns rather
# than what a grep thinks it does. Each stub carries the source package its
# real package is built from (none means the package's own name), so the
# guard's src: pattern meets the sources it is written for. They need apt, so
# they skip off Linux.
#
# Run: bats tests/nvidia-deploy.bats

load lib/platform

SCRIPT="$BATS_TEST_DIRNAME/../scripts/nvidia-deploy.sh"
SRC_DIR="$BATS_TEST_DIRNAME/../config/apt/preferences.d"
GUARD_NAME=00-nvidia-server-branch.pref
GUARD="$SRC_DIR/$GUARD_NAME"

# Non-server driver packages, versioned and unversioned, that conflict with the
# -server driver, each as "<package> <source>". The unversioned names and the
# nvidia-open and cuda-drivers metapackages are the CUDA repository's.
MUST_BLOCK=(
  "libnvidia-encode-580 nvidia-graphics-drivers-580"
  "libnvidia-decode-580 nvidia-graphics-drivers-580"
  "libnvidia-compute-580 nvidia-graphics-drivers-580"
  "libnvidia-gl-580 nvidia-graphics-drivers-580"
  "libnvidia-gpucomp-580 nvidia-graphics-drivers-580"
  "nvidia-utils-580 nvidia-graphics-drivers-580"
  "nvidia-headless-580-open nvidia-graphics-drivers-580"
  "nvidia-headless-no-dkms-580-open nvidia-graphics-drivers-580"
  "nvidia-driver-580-open nvidia-graphics-drivers-580"
  "nvidia-dkms-580-open nvidia-graphics-drivers-580"
  "nvidia-kernel-common-580 nvidia-graphics-drivers-580"
  "nvidia-firmware-580-580.178.04 nvidia-graphics-drivers-580"
  "nvidia-kernel-open-575 nvidia-graphics-drivers-575"
  "libnvidia-encode-620 nvidia-graphics-drivers-620"
  "libnvidia-encode nvidia-graphics-drivers"
  "libnvidia-compute nvidia-graphics-drivers"
  "nvidia-driver-open nvidia-graphics-drivers"
  "nvidia-dkms-open nvidia-graphics-drivers"
  "nvidia-open nvidia-open"
  "nvidia-open-580 nvidia-open"
  "cuda-drivers cuda-drivers"
  "cuda-drivers-580 cuda-drivers"
)

# Packages the -server driver, the container stack, and the CUDA toolkit need.
MUST_ALLOW=(
  "libnvidia-encode-580-server nvidia-graphics-drivers-580-server"
  "libnvidia-decode-580-server nvidia-graphics-drivers-580-server"
  "libnvidia-compute-580-server nvidia-graphics-drivers-580-server"
  "libnvidia-gl-580-server nvidia-graphics-drivers-580-server"
  "libnvidia-gpucomp-580-server nvidia-graphics-drivers-580-server"
  "nvidia-utils-580-server nvidia-graphics-drivers-580-server"
  "nvidia-headless-580-server-open nvidia-graphics-drivers-580-server"
  "nvidia-headless-no-dkms-580-server-open nvidia-graphics-drivers-580-server"
  "nvidia-driver-580-server-open nvidia-graphics-drivers-580-server"
  "nvidia-dkms-580-server-open nvidia-graphics-drivers-580-server"
  "nvidia-kernel-common-580-server nvidia-graphics-drivers-580-server"
  "nvidia-kernel-source-580-server-open nvidia-graphics-drivers-580-server"
  "nvidia-firmware-580-server-580.178.04 nvidia-graphics-drivers-580-server"
  "nvidia-headless-615-server-open nvidia-graphics-drivers-615-server"
  "libnvidia-encode-615-server nvidia-graphics-drivers-615-server"
  "libnvidia-encode-620-server nvidia-graphics-drivers-620-server"
  "nvidia-fabricmanager-580 fabric-manager-580"
  "libnvidia-nscq-580 fabric-manager-580"
  "libnvidia-egl-wayland1 egl-wayland"
  "libnvidia-container1 libnvidia-container"
  "nvidia-container-toolkit nvidia-container-toolkit"
  "cuda-toolkit-12-8 cuda-toolkit-12-8"
  "nvidia-gds-12-8 nvidia-gds-12-8"
)

BLOCK_NAMES=()
for entry in "${MUST_BLOCK[@]}"; do BLOCK_NAMES+=("${entry%% *}"); done
ALLOW_NAMES=()
for entry in "${MUST_ALLOW[@]}"; do ALLOW_NAMES+=("${entry%% *}"); done
unset entry

setup_file() {
  stub_uname "$BATS_FILE_TMPDIR/stubs"
  [ "$(uname -s)" = Linux ] && command -v apt-get >/dev/null || return 0

  local box="$BATS_FILE_TMPDIR/apt"
  mkdir -p "$box/repo" "$box/state/lists/partial" "$box/cache/archives/partial" \
    "$box/etc/sources.list.d" "$box/etc/apt.conf.d" "$box/prefs-none"
  : >"$box/state/status"
  local entry
  for entry in "${MUST_BLOCK[@]}" "${MUST_ALLOW[@]}"; do
    printf 'Package: %s\nSource: %s\nVersion: 1.0\nArchitecture: all\nDescription: stub\n\n' "${entry%% *}" "${entry#* }"
  done >"$box/repo/Packages"
  # The shape of the file NVIDIA's nvidia-driver-pinning-580 package installs,
  # which pins the non-server source and the metapackages at 1000, beside the
  # guard it must not override.
  mkdir -p "$box/prefs-pinned"
  cp "$GUARD" "$box/prefs-pinned/"
  printf 'Package: src:nvidia-graphics-drivers-580 src:nvidia-graphics-drivers-575 src:nvidia-graphics-drivers-620 src:nvidia-graphics-drivers src:cuda-drivers src:nvidia-open\nPin: version *\nPin-Priority: 1000\n' \
    >"$box/prefs-pinned/nvidia-driver-pin"
  printf 'deb [trusted=yes] file:%s ./\n' "$box/repo" >"$box/etc/sources.list"
  export APT_BOX="$box"
  sandbox_apt_get update -qq
}

setup() {
  STUBS="$BATS_FILE_TMPDIR/stubs"
  DEST="$BATS_TEST_TMPDIR/preferences.d"
  mkdir -p "$DEST"
  export STUB_UNAME=Linux
  PATH="$STUBS:$PATH"
}

# Run an apt tool against the sandbox: <tool> <preferences dir> <args...>.
sandbox_apt() {
  local tool="$1" prefs="$2"
  shift 2
  "$tool" \
    -o "Dir::State=$APT_BOX/state" \
    -o "Dir::State::status=$APT_BOX/state/status" \
    -o "Dir::Cache=$APT_BOX/cache" \
    -o "Dir::Etc=$APT_BOX/etc" \
    -o "Dir::Etc::SourceParts=$APT_BOX/etc/sources.list.d" \
    -o "Dir::Etc::Parts=$APT_BOX/etc/apt.conf.d" \
    -o "Dir::Etc::Preferences=$APT_BOX/etc/preferences" \
    -o "Dir::Etc::PreferencesParts=$prefs" \
    -o Debug::NoLocking=1 \
    -o APT::Architecture=amd64 \
    "$@"
}

sandbox_apt_get() { sandbox_apt apt-get "$APT_BOX/prefs-none" "$@"; }

# Print "<package> <candidate>" for each name, under the given preferences dir.
candidates() {
  local prefs="$1"
  shift
  sandbox_apt apt-cache "$prefs" policy "$@" |
    awk '/^[^ ].*:$/ { pkg = substr($0, 1, length($0) - 1) } $1 == "Candidate:" { print pkg, $2 }'
}

require_apt() {
  require_linux "the guard tests drive real apt"
  command -v apt-get >/dev/null || skip "apt-get not installed"
}

# assert_blocked <preferences dir>: apt offers no must-block package under it.
assert_blocked() {
  run candidates "$1" "${BLOCK_NAMES[@]}"
  [ "$status" -eq 0 ]
  local name
  for name in "${BLOCK_NAMES[@]}"; do
    [[ $'\n'"$output"$'\n' == *$'\n'"$name (none)"$'\n'* ]] || {
      echo "the guard does not block $name:"
      echo "$output"
      return 1
    }
  done
}

@test "--dest copies the guard byte for byte, mode 0644" {
  run "$SCRIPT" --dest "$DEST"
  [ "$status" -eq 0 ]
  cmp "$GUARD" "$DEST/$GUARD_NAME"
  [ -n "$(find "$DEST/$GUARD_NAME" -perm 0644)" ]
  [[ "$output" == *"NOTE: copied $GUARD_NAME to $DEST"* ]]
  [[ "$output" == *"nvidia-gpu-verify"* ]]
}

@test "a second --dest run reports nothing to copy" {
  "$SCRIPT" --dest "$DEST" >/dev/null
  run "$SCRIPT" --dest "$DEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to copy"* ]]
  [[ "$output" != *"NOTE: copied"* ]]
}

@test "--dest overwrites a guard that differs from the repo" {
  printf 'Package: nothing\nPin: version *\nPin-Priority: 500\n' >"$DEST/$GUARD_NAME"
  run "$SCRIPT" --dest "$DEST"
  [ "$status" -eq 0 ]
  cmp "$GUARD" "$DEST/$GUARD_NAME"
}

@test "--dest into a missing directory fails the pre-flight (exit 1)" {
  run "$SCRIPT" --dest "$BATS_TEST_TMPDIR/absent"
  [ "$status" -eq 1 ]
  [[ "$output" == *"destination not found: $BATS_TEST_TMPDIR/absent"* ]]
}

@test "--check passes when the deployed guard matches the repo" {
  cp "$GUARD" "$DEST/"
  NVIDIA_DEPLOY_PREFERENCES_DIR="$DEST" run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK: $DEST/$GUARD_NAME matches the repo"* ]]
}

@test "--check fails naming the guard when it differs or is missing" {
  printf 'Package: nothing\nPin: version *\nPin-Priority: 500\n' >"$DEST/$GUARD_NAME"
  NVIDIA_DEPLOY_PREFERENCES_DIR="$DEST" run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: $DEST/$GUARD_NAME differs from config/apt/preferences.d/$GUARD_NAME"* ]]
  [[ "$output" == *"deploy with: sudo"* ]]
  rm -f "$DEST/$GUARD_NAME"
  NVIDIA_DEPLOY_PREFERENCES_DIR="$DEST" run "$SCRIPT" --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: $DEST/$GUARD_NAME is not deployed"* ]]
}

@test "--check and deploy are no-ops on macOS" {
  export STUB_UNAME=Darwin
  run "$SCRIPT" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do on Darwin"* ]]
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to do on Darwin"* ]]
}

@test "deploying without root fails the pre-flight and names sudo (exit 1)" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: This script must be run as root (use sudo)"* ]]
}

@test "unknown flag, bare --dest, and extra arguments are usage errors (exit 2)" {
  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  run "$SCRIPT" --dest
  [ "$status" -eq 2 ]
  run "$SCRIPT" --check --dest "$DEST"
  [ "$status" -eq 2 ]
}

@test "without the guard, apt offers every package the guard must block" {
  require_apt
  run candidates "$APT_BOX/prefs-none" "${BLOCK_NAMES[@]}"
  [ "$status" -eq 0 ]
  local name
  for name in "${BLOCK_NAMES[@]}"; do
    [[ $'\n'"$output"$'\n' == *$'\n'"$name 1.0"$'\n'* ]] || {
      echo "no candidate for $name without the guard: the fixture is broken"
      return 1
    }
  done
}

@test "with the guard, apt offers no non-server driver package" {
  require_apt
  assert_blocked "$SRC_DIR"
}

@test "the guard still wins over a later file pinning the non-server source at 1000" {
  require_apt
  assert_blocked "$APT_BOX/prefs-pinned"
}

@test "with the guard, apt still offers every -server, container, and CUDA package" {
  require_apt
  run candidates "$SRC_DIR" "${ALLOW_NAMES[@]}"
  [ "$status" -eq 0 ]
  local name
  for name in "${ALLOW_NAMES[@]}"; do
    [[ $'\n'"$output"$'\n' == *$'\n'"$name 1.0"$'\n'* ]] || {
      echo "the guard blocks $name:"
      echo "$output"
      return 1
    }
  done
}
