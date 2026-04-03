# TODOS

## Infrastructure

### Harden qmd-update.service against NAS mount failures

**What:** Make qmd-update.service gracefully handle unavailable NAS-backed collections instead of crashing with ENOENT.

**Why:** qmd-update crashes when `/mnt/nas` is unavailable (mount failed, NAS offline, network down). The automount fix
(#006) makes this unlikely at boot, but the service remains fragile if the NAS goes offline mid-scan or is physically
unreachable.

**Context:** qmd-update scans 8 NAS-backed collections under `/mnt/nas/bigdaddy-backup/`. When any path is unavailable,
the service crashes immediately. Options: (1) add `After=mnt-nas.automount` dependency to the service unit, (2) add
retry/skip logic in the qmd update command for unreachable collections, (3) wrap the scan in a mount-check guard. The
automount fix landed in the NAS mount PR, so this is now a resilience improvement, not a critical fix.

**Effort:** S **Priority:** P2 **Depends on:** NAS automount fix (#006)
