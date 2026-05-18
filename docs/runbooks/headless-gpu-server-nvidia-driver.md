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
- **Manual-marked packages** (so autoremove cannot strip them): `dkms`, `linux-headers-generic`.

If `nvidia-smi` reports the GPU and `dkms status` shows the nvidia module built for the running kernel, the box is
healthy — no action needed.

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
sudo NEEDRESTART_MODE=a apt install -y nvidia-headless-580-server-open
```

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
```

### A.4 Lock in the toolchain against autoremove

```bash
sudo apt-mark manual dkms linux-headers-generic
```

That is the entire "lockdown". No apt pinning, no unattended-upgrades blacklist, no systemd timers.

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

The pattern generalizes: if you find another app falling back to CPU after a driver swap, look for its backend-pin
env var (`OLLAMA_*`, `CUDA_VISIBLE_DEVICES`, `GGML_CUDA_FORCE_MMQ`, etc.) and set it explicitly in the unit file
rather than relying on auto-detect.

---

## Procedure B — future kernel upgrade health check

Unattended-upgrades will install future kernels automatically. DKMS will rebuild the nvidia module as part of the kernel
install; if the build fails, apt aborts. The next time you log in:

```bash
# 1. Confirm DKMS has a module for the running kernel.
sudo dkms status | grep nvidia

# 2. Confirm GPU is alive.
nvidia-smi -L
```

If both succeed, nothing to do. If `dkms status` shows the module is built for an *older* kernel only, the most recent
kernel install hit a DKMS build failure — see Procedure C.

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

## Concerns that will resurface on any rerun

- `lsof /dev/nvidia*` must be empty before any `modprobe` swap. Any leaked handle from a previous driver generation will
  block the load.
- `NEEDRESTART_MODE=a` matters in scripted contexts; in an interactive shell it is fine to answer the prompt manually.
- DKMS builds for **every** installed kernel on `dkms autoinstall`. `apt autoremove --purge` does NOT always drop stale
  kernels (it only removes leaves that became unreferenced naturally); kernels installed explicitly may need `apt remove
  --purge linux-image-6.8.0-N-generic linux-modules-6.8.0-N-generic` to clear.
- Installing `linux-headers-generic` (or upgrading it) can transitively pull in a newer `linux-image-*` package as a
  dependency. This is expected and fine — DKMS will build for the new kernel as part of its install — but be ready for a
  "Pending kernel upgrade!" notice from needrestart afterward.
- The A.2 swap does NOT remove the prior branch's `nvidia-headless-no-dkms-NNN-server-open` package. A.5 cleanup is
  required; skipping it leaves harmless cruft on disk but does not break the new install.
- If apt aborts mid-swap (network loss, disk full, signal), `dpkg --audit` will reveal it; rerun apt to finish or use
  `dpkg --configure -a` to recover partially-configured packages.

---

## What this runbook deliberately does not do

- Install or configure a probe/alert/timer. Failure mode is "apt aborts on kernel install" — visible the next time the
  operator runs `apt` or logs in. The carrying cost of a probe was not worth the value for this user's workflow.
- Pin the kernel or block kernel upgrades. The point of DKMS is to make kernel upgrades safe; pinning would defeat the
  design.
- Touch the CUDA toolkit. Driver and toolkit upgrade on independent schedules.
