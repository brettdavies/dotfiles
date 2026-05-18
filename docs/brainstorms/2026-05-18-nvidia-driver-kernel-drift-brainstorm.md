# NVIDIA Driver / Kernel Drift on Headless GPU Server — Requirements

**Date:** 2026-05-18 **Status:** Ready for execution (no separate `/ce-plan` step needed — runbook is the plan)
**Artifacts:**

- Runbook: `docs/runbooks/headless-gpu-server-nvidia-driver.md`
- Solutions pattern: `docs/solutions/configuration-fixes/nvidia-driver-dkms-headless-gpu-server-2026-05-18.md`

## Goal

Restore GPU acceleration on the headless ML/AI server and make the configuration self-healing against future unattended
kernel upgrades. The current driver branch (`nvidia-headless-no-dkms-570-server-open`) is pinned to pre-built kernel
modules that Ubuntu's SRU pipeline did not ship for kernel `6.8.0-111`. The GPU is dark and Ollama is CPU-bound until
either a matching module ships or we migrate off the no-DKMS pattern.

## Decisions

- **Driver branch:** migrate to `nvidia-headless-580-server-open` (Server LTS Open variant, DKMS-backed).
- **CUDA toolkit:** stay on 12.8.1. Driver 580 is backward-compatible. Defer any CUDA 13 toolkit migration until a
  specific framework demands it.
- **Self-healing mechanism:** DKMS. Future kernel installs rebuild the nvidia module locally; apt rolls back if the
  build fails (loud failure beats silent drift).
- **Lockdown surface:** intentionally minimal. Just `apt-mark manual dkms linux-headers-generic` so autoremove cannot
  strip the toolchain. No apt pinning, no unattended-upgrades blacklist, no health probe.
- **Execution mode:** live, no reboot. Pre-flight verifies no process holds `/dev/nvidia*` handles, then a `modprobe`
  brings the new module up.
- **Documentation:** runbook (in this repo) for execution + recovery; solutions entry (in `~/dev/solutions-docs`, via
  symlink) for the pattern + root cause.

## In scope

- Driver branch migration via live apt swap.
- DKMS toolchain present and pinned `manual` against autoremove.
- Pre-flight, verification, and rollback commands captured in the runbook.
- Pattern doc explaining why the no-DKMS server-open variant is fragile and when DKMS is the right answer.

## Out of scope

- Reboot-required strategies (deliberately avoided; current sessions must stay alive).
- Containerizing Ollama or moving CUDA workload into NVIDIA Container Toolkit (separate decision, not needed for this
  fix).
- CUDA 13 toolkit migration (capability arrives with the driver, adoption deferred).
- Health probes / alerting / systemd timers (rejected — DKMS fails loud during apt, which is enough signal).
- Ollama config changes (`KEEP_ALIVE=-1`, flash attention, q8_0 KV cache stay as-is).

## Concerns and mitigations

| Concern                                                                                                                               | Mitigation                                                                                                                                                                                    |
| ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DKMS autoinstall builds nvidia for every installed kernel (eight currently). ~10-20 minutes on first run.                             | Run `sudo apt autoremove --purge` *before* the swap to drop unused kernels to current + prior. DKMS work drops to ~2 builds.                                                                  |
| `needrestart` prompts interactively for service restarts during apt.                                                                  | Prefix apt commands with `NEEDRESTART_MODE=a` for auto-restart of flagged services.                                                                                                           |
| Package swap (remove no-DKMS, install DKMS) is not atomic across the apt transaction. Mid-transaction abort leaves neither installed. | `dpkg --audit` after the install; rollback path is `apt install nvidia-headless-570-server-open` (DKMS variant of the old branch) which is the minimum-viable known-good state.               |
| `modprobe nvidia` fails if any process holds an open handle to `/dev/nvidia*`.                                                        | Pre-flight `lsof /dev/nvidia*` returns nothing today because the module is unloaded — verify before swap.                                                                                     |
| DKMS build for current kernel could fail (missing headers, gcc ABI).                                                                  | Install `linux-headers-$(uname -r)` explicitly first. If DKMS fails post-install, GPU stays dark — same state as today, no regression. Old kernels still present for emergency boot fallback. |

## Success criteria

- `nvidia-smi` reports the RTX 3090 Ti and driver 580.x running on kernel 6.8.0-111.
- `dkms status` shows the nvidia-580-server-open module built for the current kernel.
- Ollama reports `size_vram > 0` on the next model query (model loads into VRAM, not CPU RAM).
- A future unattended kernel upgrade (when it lands) triggers a DKMS rebuild automatically and the GPU stays available
  across reboot.

## Recurrence guard

Documented in the solutions pattern doc. Summary: choose DKMS variants of NVIDIA Ubuntu packages on headless servers
where kernel upgrades come in via unattended-upgrades. The `nvidia-headless-no-dkms-NNN-...` packages tie GPU
availability to Ubuntu's SRU schedule, which has gaps; DKMS removes that coupling.
