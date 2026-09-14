# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific
meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings;
direct edits are fine. Glossary only, not a spec or catch-all.

## Hosts

### Deployed dotfiles host

A machine where this repo has been stowed into the user's home, so the dotfile symlinks and shell helpers are in place.
Some assertions in this repo's test suite (and some policies declared in shell configuration) are only meaningful on a
deployed dotfiles host — generic CI runners and non-deployed user accounts are not subject to them. Tests that enforce a
deployed-host policy precondition-skip when the host class is not detected; the canonical detection check is whether one
of the stow-deployed symlinks is in place.

Capability checks (is the tool installed at all?) layer before host-class checks (is this host subject to the policy?).
The two compose; neither replaces the other.

### Headless host

An Ubuntu server in the deployment fleet: no GUI, no graphical secret manager, no interactive prompts during install or
operation. Distinguished from the macOS development machine, which has both interactive use and a graphical secret
manager available. Every flow that targets a deployed dotfiles host must work on a headless host without a human in the
loop — the same flow runs on many of them and a manual step does not scale.

When a tool would normally depend on the graphical secret manager (git signing, secret reads), the headless host falls
back to a non-interactive path: ssh-based signing, service-account token reads.

### qmd thin client

A deployed dotfiles host — in practice the macOS workstation, and any other host that is not the qmd brain — that
searches the central qmd corpus over the tailnet and never runs a local qmd index or GGUF process. The *qmd brain host*
is the headless machine that owns the sqlite index, the always-on MCP HTTP process, and the periodic embed jobs. Clients
reach that process through a Tailscale VIP (HTTPS MagicDNS), not through `qmd serve` or a local `qmd` CLI. The split
keeps one vector space: every query is embedded and reranked by the brain host's one llama.cpp, so a second local engine
would fork that space.

## Packages

### Stow package

A directory under `stow/` whose contents deploy into the user's home via GNU stow with its `--dotfiles` flag, so a
`dot-foo` file inside the package becomes `.foo` in the target tree. Every config artifact that lives at a known path in
`$HOME` belongs in a stow package; system-owned paths do not (see *System-level unit*).

Packages split into visibility classes that determine which host classes receive them: shared packages deploy to every
host class, desktop packages only to the development workstation. The split is declared once in the deploy script's
package arrays, not per-package.

### Shared package

A stow package deployed to every host class — the macOS development machine and every headless host alike. Contains
config that is meaningful regardless of whether the host has a GUI.

### Desktop package

A stow package deployed only on the macOS development machine. Contains config for tools that exist only on the
workstation: GUI applications, editors with no headless equivalent, and macOS-native automation surfaces. The split
keeps the headless deploy minimal and avoids surprising failures on hosts that don't have the underlying tool.

### Encrypted package

A stow package whose contents are git-crypt encrypted in the repository and only readable after the repository is
unlocked with the symmetric key. Secrets and credential-bearing config live here. A fresh clone fetches encrypted blobs;
deploying any of these packages requires the repo be unlocked first, after which subsequent checkouts and merges
auto-unlock without manual intervention.

### Cross-package symlink

A relative symlink inside one stow package's source pointing into another stow package's source, committed to git as the
symlink itself (target string, not resolved content). On deploy, the result is a two-hop chain: the home-directory file
links to the consuming package, which links to the source-of-truth file in the owning package. The technique is how one
tool's config dir reads another tool's authoritative file without duplication — edit the source once, every consumer
sees it. Used when two tools follow parallel conventions for the same kind of artifact (e.g. global agent instructions
read from per-tool paths) and the team wants single-source-of-truth across them. The trade-off is that file formats and
directives must be compatible across consumers; tool-specific syntax in the source is inert in consumers that do not
recognize it.

## System configuration

### System-level unit

A systemd unit, AppArmor profile, or similar configuration artifact whose target is a root-owned system path.
System-level units bypass stow — stow targets `$HOME`, and symlinking root-owned paths into a user-owned directory is a
security concern. They live under a non-stow `config/` tree in the repo and ship via dedicated deploy scripts that
elevate, copy, and activate the unit; the repo version is authoritative.

### Per-host override

A configuration file that lives on a single host outside the repo and is not tracked in git, used to capture settings
that legitimately differ per machine (signing-key paths, machine-specific git identity, host-specific shell tweaks). The
repo's tracked config sources or includes the override path so settings layer cleanly: the tracked config is the
default, the per-host override is the deviation, and the override's existence is part of the deployment contract.

## Shell environment

### Shell config chain

The single environment-setup path every login, interactive, and non-interactive shell shares: one universal entry file
that establishes PATH, the package-manager prefix, secrets, and the per-tool config fragments, reached by each shell
through its own startup file. It is the authoritative place to set environment for shells, and it does not run for a
*bare launcher*.

Order within the chain is load-bearing. A per-tool fragment decides whether to apply by testing, at the moment it is
sourced, whether its tool is reachable on PATH. A fragment reached before the chain has finished assembling PATH
therefore finds nothing and silently applies none of its configuration, in every shell that did not inherit a populated
PATH from a parent. Fragments are sourced only after PATH is complete, and the failure this prevents is silent: no error
is raised, and a shell descended from a working shell behaves correctly regardless, which hides it.

Dialect is load-bearing for the same reason. The entry file is reached by more *invocation shapes* than the shells the
fragments are written for, so it has to stay within the syntax common to all of them outside regions explicitly guarded
on a shell's own marker. Order and dialect fail at different scales: a fragment reached too early misconfigures one
tool, while a construct the reading shell rejects ends the entry file where it stands and costs every export below it.
The fragments themselves are sourced only by the shells that can parse them, which is why the entry file's dialect
constraint is stricter than theirs.

### Bare launcher

A process that spawns a shell without sourcing any startup file, so it inherits only the PATH and environment its parent
handed it and never runs the *shell config chain*. Cron, launchd and systemd jobs, GUI applications, git hooks, and the
coding agent's command tool are all bare launchers. A bare launcher that needs a non-default tool on PATH must receive
it from its own process environment (its unit, plist, or launcher configuration), not from the shell config chain.

Automated and remote callers are not bare launchers by default, and assuming they are is a mistake in the expensive
direction. A caller that requests a login shell reads the chain however headless it is, which exposes it to everything
the chain can get wrong rather than exempting it. Whether a caller is a bare launcher is decided by its *invocation
shape*, not by whether a human is watching.

### Invocation shape

The combination of shell dialect, login versus non-login, and interactive versus non-interactive that decides which
startup files a shell process reads. Two processes running the same command reach different environments when their
shapes differ, so the shape is the unit at which shell environment behavior is specified and verified, not the command.

A shape that reads no startup file at all is a *bare launcher*. Verification has to reproduce the caller's exact shape:
a pass obtained under a neighboring shape carries no information about the one that failed, and a shell descended from a
correctly configured parent looks correct regardless of what its own startup files do. Shapes are enumerated
deliberately, because the ones nobody listed are the ones nothing tests.

### Install root

A directory a language toolchain treats as its installation destination — holding binaries, toolchains, or registries
that cannot be regenerated without re-downloading them — as opposed to a cache, which the tool refills on demand.
`CARGO_HOME`, `RUSTUP_HOME`, `PIPX_HOME`, `PNPM_HOME`, `BUN_INSTALL`, and `GOPATH` name install roots; `HOMEBREW_CACHE`,
`UV_CACHE_DIR`, `GOCACHE`, and `NPM_CONFIG_CACHE` name caches. The distinction decides whether deleting the directory is
safe, and it is not visible from the path: several install roots are relocated under `XDG_CACHE_HOME` alongside true
caches.

An install root relocated by the shell config chain diverges for every *bare launcher*, because the relocation applies
at runtime while the tool's installer wrote to the default path. The result is one tree the shell sees and another the
launcher sees, with no error from either.

## Policies

### Supply-chain age gate

The minimum-release-age policy applied to every supported package manager on a deployed dotfiles host: a version newly
published to its upstream registry is not resolvable until it has been public for at least the gate's configured number
of days. Each package manager exposes the policy through its own configuration key (env var, config file, or both), and
each requires a tool version recent enough to honor it — older versions silently ignore the setting, so the gate is
paired with a version floor for every PM it covers. The gate is enforced via shell env vars (covering interactive and
shell-launched processes) and, where the tool supports a global config file, written into that file (covering cron,
systemd units, and other non-shell invocations).
