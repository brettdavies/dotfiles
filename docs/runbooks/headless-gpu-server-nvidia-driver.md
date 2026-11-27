# Headless GPU Server — NVIDIA Driver Runbook

Step-by-step procedure for installing, upgrading, or recovering the NVIDIA driver on a headless Ubuntu 24.04 ML/AI
server. Written for the user's RTX 3090 Ti (GA102, Ampere) box; the procedure generalizes to any consumer GPU on a
recent driver branch.

For the *why* behind these choices, see
[`docs/solutions/configuration-fixes/nvidia-driver-dkms-headless-gpu-server-2026-05-18.md`](../solutions/configuration-fixes/nvidia-driver-dkms-headless-gpu-server-2026-05-18.md)
(symlinked from `~/dev/solutions-docs`).

## Current canonical state

- **Driver package:** `nvidia-headless-580-server-open` (Server LTS, open kernel module, **DKMS-backed**).
- **CUDA toolkit:** 12.8.x (driver 580 is backward-compatible).
- **Kernel updates:** unattended-upgrades stays enabled; DKMS rebuilds the nvidia module on every kernel install and apt
  fails loud if the build cannot complete.
- **Manual-marked packages** (so autoremove cannot strip them): `dkms`, `linux-headers-generic`, and any add-on that
  only another branch's package depends on (on the Linux server, `nvidia-utils-580-server`).
- **Add-on userspace:** `nvidia-utils`, `libnvidia-compute`, `libnvidia-gl`, `libnvidia-encode`, and `libnvidia-decode`,
  each as `-580-server` at the loaded driver's exact version. The driver install brings the first three; Procedure D
  adds the encode and decode libraries.
- **apt guard:** `config/apt/preferences.d/00-nvidia-server-branch.pref`, deployed to `/etc/apt/preferences.d/` by
  `sudo ~/dotfiles/scripts/nvidia-deploy.sh`, refuses every package built from the non-server driver source, so a plain
  name such as `libnvidia-encode-580` or NVIDIA's `cuda-drivers` cannot swap out the `-server` userspace.
  `~/dotfiles/scripts/nvidia-deploy.sh --check` reports drift without root.
- **The check:** `nvidia-gpu-verify` is the arbiter of a healthy box.

### The check

`nvidia-gpu-verify` and its daily timer come with the `local` stow package. A `git pull` relinks only the `claude` and
`secrets` packages, so a host that pulls them for the first time sets them up in this order:

```bash
# 1. Link the command and the units.
cd ~/dotfiles && scripts/stow-deploy --headless --only local

# 2. Deploy the apt guard, run the check, and run the `next:` lines it prints. On the Linux server those are the
#    three below. nvidia-utils-580-server is marked auto-installed and only the empty transitional package of the
#    retired 570 branch depends on it, so it is marked manual before that package goes; otherwise the next autoremove
#    takes nvidia-smi. The firmware is from an older 580 release.
sudo ~/dotfiles/scripts/nvidia-deploy.sh
nvidia-gpu-verify
sudo apt-mark manual nvidia-utils-580-server
sudo apt-get remove nvidia-utils-570-server nvidia-firmware-580-server-580.126.20

# 3. Enable the timers (the Linux server only), then expect "nvidia-gpu-verify: all checks passed".
bash ~/dotfiles/scripts/host-jobs-enable.sh
nvidia-gpu-verify
```

The timers' units carry the Linux server's `ConditionHost`, so another host skips `host-jobs-enable.sh`, and runs only
the `next:` lines its own check prints.

It reads the branch and version from the loaded kernel module, then checks:

- the five add-on packages at that version;
- that apt autoremove keeps each add-on: one marked auto-installed needs a package other than another branch's to depend
  on it;
- every other installed package of a `-server` driver source, which must be of the loaded branch at that version;
- that no package the guard refuses is installed;
- that DKMS has built the installed `nvidia-dkms` package's module for every kernel in `/boot`, and that dpkg has
  configured the package;
- NVENC and NVDEC, through two session-free driver calls, and the Vulkan device;
- that `/etc/apt/preferences.d` holds the repo's guard byte for byte, and that apt honours it.

It changes nothing and opens no encode or decode session, so it is safe while encodes run. A healthy run on 580
(abridged):

```text
PASS  kernel module 580.178.04 loaded (branch 580)
PASS  nvidia-utils-580-server 580.178.04-0ubuntu0.24.04.1
...
PASS  apt autoremove keeps every -580-server add-on, with or without other branches' packages
PASS  9 other -580-server package(s) at 580.178.04
PASS  no package the apt guard refuses is installed
PASS  DKMS has built nvidia 580.178.04 for every kernel: 6.8.0-146-generic 6.8.0-151-generic
PASS  NVENC answers: API 13.0; ffmpeg built against nv-codec-headers 13.0 or older can encode
PASS  NVDEC answers: h264=yes/4096 hevc=yes/8192 av1=yes/8192 (supported/max width)
PASS  Vulkan lists the NVIDIA device at 580.178.04
PASS  the apt guard in /etc/apt/preferences.d matches the repo's copy
PASS  apt guard in effect: no candidate for libnvidia-encode-580 or libnvidia-encode

nvidia-gpu-verify: all checks passed
```

Each FAIL is followed by a `next:` line holding one command that is safe to paste. A missing library's line is its
install, pinned to the loaded driver's Debian version so it cannot resolve to the non-server build:

```text
FAIL  libnvidia-encode-580-server is not installed
      next: sudo NEEDRESTART_MODE=l apt-get install "libnvidia-encode-580-server=580.178.04-0ubuntu0.24.04.1"
```

A `next:` line that starts with `sudo` is the operator's to run; an agent without root hands it over. Exit 0 means no
FAIL, 1 at least one. When no package of the loaded branch is at the loaded version, the check prints one FAIL for it
and points at `/usr/sbin/dkms status nvidia`: either a reboot is pending, and DKMS shows the new module built for the
running kernel, or another branch's package replaced this one (see Procedure D), and a reboot would come up with no
module. A DKMS build that failed for any kernel stops the `nvidia-dkms` package's postinst. The check then fails first
on that package, so the status text says not to reboot, and the DKMS step fails on each kernel without a build: reboot
only once those pass. When the guard step fails while `~/dotfiles/scripts/nvidia-deploy.sh --check` reports the guard
deployed, a preferences file that sorts before it overrides it, and `apt-cache policy libnvidia-encode-580` shows the
winning pin.

A package of another branch, such as the empty transitional `nvidia-utils-570-server` an old branch leaves behind, or a
firmware package for an older driver version, fails with its `sudo apt-get remove` line. When such a package is all that
depends on an add-on apt marked auto-installed, the add-on fails too, with `sudo apt-mark manual` as its `next:` line,
and every remove line runs that mark first, so the next autoremove keeps the add-on. Each point release of the branch
installs its own `nvidia-firmware-580-server-<version>` and leaves the previous one installed, so after every point
release the check fails on the old firmware until its remove line runs.

On the Linux server the `nvidia-gpu-verify` user timer runs the check daily. A run with a FAIL fails the unit and sets
its status text to the number of FAILs, the first FAIL, and that FAIL's `next:` command; `nvidia-gpu-verify` lists them
all. On the Linux server, with the guard not yet deployed and nothing else wrong, the failed-units notice at session
start reads: `nvidia-gpu-verify.service (2 check(s) failed, first: /etc/apt/preferences.d/00-nvidia-server-branch.pref
is not deployed; next: sudo ~/dotfiles/scripts/nvidia-deploy.sh)`. The unit stays failed until a run passes, the timer's
next or `systemctl --user start nvidia-gpu-verify.service`. A run that hangs, as a probe can on a wedged GPU, fails the
unit after 5 minutes.

---

## Procedure A — initial migration to the canonical state

Run when the box is currently on the no-DKMS variant (`nvidia-headless-no-dkms-NNN-server-open`) or any other non-DKMS
NVIDIA driver setup.

### A.1 Pre-flight

```bash
# 1. Verify nothing holds an open handle to the GPU device nodes (must be empty).
sudo lsof /dev/nvidia* 2>/dev/null

# 2. Inventory current state.
dpkg -l | grep -E '^ii.*nvidia-(headless|driver)' | awk '{print $2, $3}'
uname -r
nvidia-smi 2>&1 | head -3        # may report "driver not loaded" — expected if drifted

# 3. Drop stale kernels so DKMS will not have to build for every one of them.
#    Note: autoremove only drops kernels that became leaves naturally. Kernels installed
#    explicitly (or held by linger metadata) survive. Inspect with `ls /boot/vmlinuz-*` after.
sudo apt autoremove --purge -y

# 4. Confirm headers for the running kernel are present (DKMS dependency).
#    HEADS UP: installing `linux-headers-generic` will upgrade it to the LATEST kernel ABI
#    available — which can drag a newer linux-image-* in as a transitive dependency. That is
#    fine (DKMS will build for it in step A.2) but expect to see a kernel install here and a
#    "Pending kernel upgrade!" message from needrestart afterward.
sudo apt install -y dkms linux-headers-generic "linux-headers-$(uname -r)"
```

### A.2 Swap

```bash
# Installs the DKMS-backed package. NEEDRESTART_MODE=a auto-restarts services flagged by
# needrestart (no interactive prompt). Note: this does NOT automatically remove the
# `nvidia-headless-no-dkms-NNN-server-open` package from the prior branch — they coexist.
# Explicit cleanup happens in A.5.
sudo NEEDRESTART_MODE=a apt install -y \
    nvidia-headless-580-server-open \
    libnvidia-gl-580-server \
    vulkan-tools
```

The `libnvidia-gl-NNN-server` package ships the matching Vulkan ICD (`/usr/share/vulkan/icd.d/nvidia_icd.json`). Without
it, Vulkan-using apps on the box (anything built on `node-llama-cpp`, LM Studio, etc.) silently fall back to CPU or fail
to enumerate the GPU as a Vulkan device. `vulkan-tools` is a 3 MB diagnostic kit (`vulkaninfo`, `vkcube`) — optional but
handy when debugging.

DKMS builds the nvidia module for **every installed kernel**, not just the running one. On a typical box with current +
prior + (possibly) a newly-pulled latest kernel, expect 3-9 minutes of CPU and three "Building initial module
nvidia/X.Y.Z for 6.8.0-N-generic" blocks.

### A.3 Verify

```bash
# 1. apt finished cleanly.
sudo dpkg --audit
dpkg -l | grep -E '^ii.*nvidia-(headless|driver)' | awk '{print $2, $3}'

# 2. DKMS shows the module built for the current kernel.
sudo dkms status | grep nvidia

# 3. Module loads and the GPU responds.
sudo modprobe nvidia
nvidia-smi

# 4. Ollama re-acquires the GPU.
sudo systemctl restart ollama
sleep 2
# Run a tiny model query, then:
curl -s localhost:11434/api/ps | jaq '.models[]? | {name, size_vram}'
# size_vram > 0 confirms the model is in VRAM, not CPU RAM.

# 5. nvidia-persistenced daemon is running. The nvidia-headless-NNN-server-open
#    package pulls it in as a dependency and systemd starts it automatically,
#    but verify it survived the swap. Keeps the driver state loaded between
#    processes so cold CUDA app starts skip the ~1-3s driver re-init cost.
#    Idle power impact on consumer GPUs (e.g., 3090 Ti) is negligible (~0 W).
systemctl status nvidia-persistenced.service --no-pager | head -5
nvidia-smi --query-gpu=persistence_mode --format=csv
# Note: persistence_mode reports "Disabled" because nvidia-persistenced uses
# a different mechanism than the legacy `nvidia-smi -pm 1` flag. That is
# expected; the daemon is the modern recommended approach.
```

### A.4 Lock in the toolchain against autoremove

```bash
sudo apt-mark manual dkms linux-headers-generic
```

With the apt guard (`config/apt/preferences.d/00-nvidia-server-branch.pref`, deployed by
`sudo ~/dotfiles/scripts/nvidia-deploy.sh`) as the one apt pin, that is the entire "lockdown": no unattended-upgrades
blacklist and no hold. The two daily timers in the `local` package (see "The check") report drift; they change nothing.

### A.5 Cleanup orphaned packages from the prior driver branch

The A.2 swap leaves the old `nvidia-headless-no-dkms-NNN-server-open` package and its
`nvidia-kernel-source-NNN-server-open` dependency installed (they were not strict conflicts with the new DKMS variant).
Remove them explicitly, then a final autoremove for stale kernels that may now be eligible:

```bash
# Replace NNN with the prior branch number (e.g., 570 if you migrated from 570 → 580).
sudo apt remove --purge -y nvidia-headless-no-dkms-NNN-server-open nvidia-kernel-source-NNN-server-open
sudo apt autoremove --purge -y
```

After this, `dpkg -l | grep nvidia-headless` should show only the new `nvidia-headless-NNN-server-open` and
`nvidia-headless-no-dkms-NNN-server-open` (the latter pulled in as a dep of the former — leave it).

---

### A.6 Verify downstream GPU consumers picked up the new driver

Driver branch swaps can silently regress applications that detect the GPU through Vulkan / OpenCL / OpenGL prebuilt
binaries. Their auto-selected backend may now be linked against ICDs that no longer match the installed driver branch.
The app keeps running — it falls back to CPU or a slower backend — and the failure is silent.

Quick check per GPU consumer, run a representative workload and watch:

```bash
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

The consumer process should appear in the list while it is using the GPU. If the workload runs but the process never
appears, the auto-selected backend is not CUDA and is probably broken or has fallen through to CPU.

**Known cases on this box:**

- `node-llama-cpp` (used by qmd and similar inference servers) prefers Vulkan when both Vulkan and CUDA prebuilt
  binaries are present. Vulkan ICDs ship per driver branch, so a 570 -> 580 swap (or any branch change) leaves the
  Vulkan binary linked against the wrong ICD. The fix is to pin the backend via env var in the systemd unit:

  ```ini
  Environment=NODE_LLAMA_CPP_GPU=cuda
  ```

  Then `systemctl --user daemon-reload && systemctl --user restart <service>`. Verified with
  `nvidia-smi --query-compute-apps` showing the bun PID as a CUDA client.

  **Belt-and-suspenders:** rebuild node-llama-cpp prebuilt bindings against the current system libs so both Vulkan
  and CUDA paths are healthy. Use the included script:

  ```bash
  ~/dotfiles/scripts/qmd-llama-rebuild.sh
  ```

  The env-var pin remains the load-bearing fix; the rebuild adds a working Vulkan fallback so a future regression
  on the CUDA prebuilt does not strand the box again. Re-run the script after any future driver branch change.

The pattern generalizes: if you find another app falling back to CPU after a driver swap, look for its backend-pin env
var (`OLLAMA_*`, `CUDA_VISIBLE_DEVICES`, `GGML_CUDA_FORCE_MMQ`, etc.) and set it explicitly in the unit file rather than
relying on auto-detect.

---

## Procedure B — future kernel upgrade health check

Unattended-upgrades will install future kernels automatically. DKMS will rebuild the nvidia module as part of the kernel
install; if the build fails, apt aborts. The next time you log in:

```bash
# 1. Confirm DKMS has a module for the running kernel.
sudo dkms status | grep nvidia

# 2. Confirm GPU is alive.
nvidia-smi -L

# 3. Confirm the userspace matches the module and the video engines answer.
nvidia-gpu-verify
```

If all three succeed, nothing to do. If `dkms status` shows the module is built for an *older* kernel only, the most
recent kernel install hit a DKMS build failure — see Procedure C.

---

## Procedure C — recovery when DKMS fails on a new kernel

Symptom: `dkms status` shows nvidia built for kernel N-1 but not N (the currently running kernel), or `nvidia-smi`
reports the driver is not loaded after a kernel upgrade.

```bash
# 1. Capture the failure.
sudo journalctl -u dkms --since "1 day ago" | tail -50
ls /var/lib/dkms/nvidia*/*/build/make.log 2>/dev/null | xargs tail -30

# 2a. Common cause: missing headers for the new kernel.
sudo apt install -y "linux-headers-$(uname -r)"
sudo dkms autoinstall

# 2b. Common cause: gcc / toolchain ABI mismatch.
sudo apt install -y gcc make
sudo dkms install -m nvidia-580-server-open -v "$(dkms status | awk -F'[,/]' '/nvidia/{print $2; exit}')" -k "$(uname -r)"

# 3. Last-resort: reboot into the prior kernel (still in grub) where DKMS already has a built module.
#    From a GRUB menu select "Advanced options for Ubuntu" → the N-1 kernel. After boot:
sudo modprobe nvidia
nvidia-smi
# Then resolve the toolchain issue on the booted prior kernel without time pressure.

# 4. Rollback to the prior driver branch if 580 itself is the problem.
sudo NEEDRESTART_MODE=a apt install -y nvidia-headless-570-server-open
sudo dkms autoinstall
sudo modprobe nvidia
```

The prior kernel is always retained because `apt autoremove` keeps current + one prior by default. That is the intended
boot-time fallback.

---

## Procedure D: add an optional NVIDIA userspace library

Use this for NVENC and NVDEC (`libnvidia-encode`, `libnvidia-decode`) or any other optional `libnvidia-*` package. The
encode and decode libraries are part of the canonical set; until Procedure D installs them, `nvidia-gpu-verify` reports
them missing, and its `next:` lines are the install commands this procedure builds by hand.

The driver is the `-server` branch, so take the `-server` package at the loaded driver's exact version. The plain name
(`libnvidia-encode-580`) is the non-server branch, and the NVIDIA CUDA apt repository on this box
(`/etc/apt/preferences.d/cuda-repository-pin-600` sets priority 600 for it) makes that build the default candidate. A
simulated install of the plain name removes `nvidia-headless-580-server-open` and `libnvidia-compute-580-server`; the
apt guard refuses it.

Every name below carries the loaded branch, and the simulation is what catches the trap the guard cannot: an add-on of
another branch (`nvidia-fabricmanager-615`, `libnvidia-encode-615-server`) is a `-server`-side package, so the guard
lets it through, yet it installs that branch's `nvidia-kernel-common` and removes the loaded branch (a simulated
`nvidia-fabricmanager-615` removes 11 packages).

```bash
# 1. Loaded branch and the Debian version of its packages.
B=$(cut -d. -f1 /sys/module/nvidia/version)
V=$(dpkg-query -W -f='${Version}' "nvidia-kernel-common-$B-server")

# 2. Confirm the -server packages are available at that version (Ubuntu's archive).
apt-cache policy "libnvidia-encode-$B-server" "libnvidia-decode-$B-server"

# 3. Simulate without root. Expect "0 upgraded, 2 newly installed, 0 to remove"; any Remv line means stop.
apt-get install -s "libnvidia-encode-$B-server=$V" "libnvidia-decode-$B-server=$V" | grep -E '^(Inst|Remv)|upgraded'

# 4. Baseline the GPU consumers, then install. NEEDRESTART_MODE=l lists services without restarting any.
~/.local/bin/qmd-gpu-verify
sudo NEEDRESTART_MODE=l apt-get install -y "libnvidia-encode-$B-server=$V" "libnvidia-decode-$B-server=$V"

# 5. Verify the libraries and re-run the consumer checks.
nvidia-gpu-verify
~/.local/bin/qmd-gpu-verify
```

Naming both libraries marks both as manually installed, so a later autoremove cannot take the decode library. Running
processes do not map the new libraries, so nothing restarts. Remove the same way: `apt-get remove -s` with the package
names must list only those packages under `Remv`. For the why, see
[`docs/solutions/configuration-fixes/nvidia-addon-userspace-packages-match-driver-branch-and-version.md`](../solutions/configuration-fixes/nvidia-addon-userspace-packages-match-driver-branch-and-version.md).

### NVENC API version and ffmpeg builds

The driver supports one NVENC API version, and an ffmpeg build encodes only when the nv-codec-headers it was built
against ask for that version or older. The check's NVENC line prints the driver's version. Branch 580 supports 13.0
[measured]; 615 and 620 are at or above the 610.0 floor of 13.1.

| NVENC API | Minimum driver | nv-codec-headers                | Builds                                                                    |
| --------- | -------------- | ------------------------------- | ------------------------------------------------------------------------- |
| 13.1      | 610.0          | `master`                        | BtbN `n9.0-latest` and `master-latest`                                    |
| 13.0      | 570.0          | `sdk/13.0` branch, `n13.0.19.1` | BtbN `ffmpeg-n8.1-latest-linux64-gpl`; a local build against `n13.0.19.1` |
| 12.1      | 530.41.03      | 12.1.14                         | Ubuntu `ffmpeg` 6.1.1 (noble universe, `libffmpeg-nvenc-dev` 12.1.14)     |
| 12.0      | 520.56.06      | `n12.0.16.1`                    | jellyfin-ffmpeg 8.1.3-2                                                   |

A build whose headers are newer than the driver fails at encoder open with "Driver does not support the required nvenc
API version. Required: 13.1 Found: 13.0". BtbN picks the headers by ffmpeg version in its `scripts.d/50-ffnvcodec.sh`:
`sdk/11.1` below 8.0, `sdk/13.0` for 8.0 and 8.1, and `master` from 9.0.

---

## Procedure E: change driver branch

Run with the branch number as `B`, after the GPU consumers can take a reboot. Prefer an NVIDIA Long Term Support or
Production branch whose candidate comes from noble-updates or noble-security: Ubuntu transitions a New Feature Branch to
the next supported branch on its own.

Name every add-on with the new branch. Naming only the headless metapackage removes `libnvidia-gl-<old>-server` and
`nvidia-utils-<old>-server` with nothing replacing them, which leaves Vulkan on `llvmpipe` and removes `nvidia-smi`.

```bash
# 1. The candidate must come from noble-updates or noble-security; nvidia-lts-watch fails the day 620's does.
B=620
apt-cache policy "nvidia-headless-$B-server-open"

# 2. Simulate the whole set. Expect only the old branch's -server packages under Remv, and no package
#    without "-server" under Inst (for 615 from 580: 14 newly installed, 12 to remove).
apt-get install -s "nvidia-headless-$B-server-open" "libnvidia-gl-$B-server" "libnvidia-encode-$B-server" \
  "libnvidia-decode-$B-server" "nvidia-utils-$B-server" | grep -E '^(Inst|Remv)|upgraded'

# 3. Install without restarting services, then confirm DKMS built the new module for every installed kernel.
sudo NEEDRESTART_MODE=l apt-get install -y "nvidia-headless-$B-server-open" "libnvidia-gl-$B-server" \
  "libnvidia-encode-$B-server" "libnvidia-decode-$B-server" "nvidia-utils-$B-server"
/usr/sbin/dkms status nvidia

# 4. Reboot onto the new module.
sudo systemctl reboot

# 5. After the reboot.
nvidia-gpu-verify
~/dotfiles/scripts/qmd-llama-rebuild.sh
~/.local/bin/qmd-gpu-verify
```

Between step 3 and the reboot, `nvidia-gpu-verify` reports that no package of the loaded branch is at the loaded
version; that is the pending reboot, and its DKMS step shows the new module built for every kernel. Rollback is this
procedure with the old branch as `B` and a reboot. The daily check's unit fails on the pending reboot too, until the
reboot.

`nvidia-lts-watch` is the daily systemd user timer that waits for 620 on the Linux server. Once `apt-cache policy` lists
`nvidia-headless-620-server-open` from a `-updates` or `-security` pocket, the unit fails, and the failed-units notice
at session start shows its status text, which names this runbook's driver move as ready; `nvidia-lts-watch --help` names
this procedure. Once the host runs 620, retire it: `systemctl --user disable --now nvidia-lts-watch.timer`, then a PR
that removes its two units, its script, its suite, and its lines in `scripts/host-jobs-enable.sh` and
`tests/host-scheduled-jobs.bats`.

The guard serves hosts on the `-server` driver only. Moving a host to the non-server family starts with
`sudo rm /etc/apt/preferences.d/00-nvidia-server-branch.pref`, since the guard refuses every package of that family.

---

## Concerns that will resurface on any rerun

- `lsof /dev/nvidia*` must be empty before any `modprobe` swap. Any leaked handle from a previous driver generation will
  block the load.
- `NEEDRESTART_MODE=a` matters in scripted contexts; in an interactive shell it is fine to answer the prompt manually.
- DKMS builds for **every** installed kernel on `dkms autoinstall`. `apt autoremove --purge` does NOT always drop stale
  kernels (it only removes leaves that became unreferenced naturally); kernels installed explicitly may need
  `apt remove --purge linux-image-6.8.0-N-generic linux-modules-6.8.0-N-generic` to clear.
- Installing `linux-headers-generic` (or upgrading it) can transitively pull in a newer `linux-image-*` package as a
  dependency. This is expected and fine — DKMS will build for the new kernel as part of its install — but be ready for a
  "Pending kernel upgrade!" notice from needrestart afterward.
- The A.2 swap does NOT remove the prior branch's `nvidia-headless-no-dkms-NNN-server-open` package. A.5 cleanup is
  required; skipping it leaves harmless cruft on disk but does not break the new install.
- If apt aborts mid-swap (network loss, disk full, signal), `dpkg --audit` will reveal it; rerun apt to finish or use
  `dpkg --configure -a` to recover partially-configured packages.

---

## What this runbook deliberately does not do

- Alert outside a session. The daily `nvidia-gpu-verify` run reports through the failed-units notice when a session
  starts, and nothing mails or pages. A kernel that DKMS cannot build for still fails `apt` loudly at install. The other
  timer here, `nvidia-lts-watch`, watches for the 620 release, not the host's health.
- Pin the kernel or block kernel upgrades. The point of DKMS is to make kernel upgrades safe; pinning would defeat the
  design.
- Touch the CUDA toolkit. Driver and toolkit upgrade on independent schedules.
