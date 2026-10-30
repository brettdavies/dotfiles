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

### Canonical checkout

The one clone of this repo that may write into the real home: `~/dotfiles`, resolved to its real path, on every host
class. Every other checkout is non-canonical by definition — an agent scratchpad clone, a `/tmp` clone, a linked git
worktree, whatever its origin URL. A non-canonical checkout reaches the deploy only against a scratch target, through
the script's deploy-target seam; that is how the test suite exercises stow without touching the live symlinks.

Distinct from a *deployed dotfiles host*: that is a host-class check (are the stow links in place?), this is a
checkout-identity check (is this the clone that owns them?). The first governs whether a policy applies; the second
governs who may deploy.

### Headless host

An Ubuntu server in the deployment fleet: no GUI, no graphical secret manager, no interactive prompts during install or
operation. Distinguished from the macOS development machine, which has both interactive use and a graphical secret
manager available. Every flow that targets a deployed dotfiles host must work on a headless host without a human in the
loop — the same flow runs on many of them and a manual step does not scale.

When a tool would normally depend on the graphical secret manager (git signing, secret reads), the headless host falls
back to a non-interactive path: ssh-based signing, service-account token reads.

### qmd daemon host

A deployed dotfiles host that runs its own `qmd serve` bound to loopback and routes CLI queries to it through
`QMD_REMOTE_URL`, so the heavy models stay warm across invocations instead of cold-loading per call. Each such host owns
its own sqlite index and its own embed, rerank and generate models; no query crosses the tailnet. Every host in the
fleet is one of these.

Hosts differ only in resident footprint, which follows the memory available. The VRAM-constrained headless host runs
low-vram mode, disposing and reloading one heavy model at a time to hold the peak down while sharing a GPU with other
work. The workstation has unified-memory headroom and keeps all three resident, spending footprint to avoid the
per-stage reload latency. The scheduled index jobs are the same set on both, expressed as systemd timers on Linux and
launch agents on macOS.

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

### Package set

One of the named arrays in the deploy script that decides what a bare deploy reaches. The sets are the single source of
truth for deployment: a package directory under `stow/` that appears in none of them is never deployed by any normal
run, and lands in the real home only if someone stows it by hand on one machine. That machine then works and the next
one silently lacks the config, with no error pointing back at the omission. A package genuinely outside the sets is
recorded as an exemption with its reason, so the absence is a decision rather than an oversight.

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

### Stowed dispatcher

A small executable in a stow package, deployed to a fixed path under `~/.local/bin`, whose only job is to exec the real
implementation for the running OS. Callers name the dispatcher rather than the implementation, so one path is correct on
every host class and survives the implementation moving. Service units, timers, and launch agents are the callers that
need this most: they resolve a binary once at start and have no shell chain to consult, so a path that differs per
platform has to be branched somewhere, and the dispatcher is the one place to branch it.

The dispatcher also decides which of several installed copies answers. Where a tool exists both as a packaged release
and as a local build, naming the dispatcher pins every caller to the build the repo intends, instead of leaving the
choice to whichever copy `PATH` happens to reach first.

### Stow-managed link

A symlink under the real home whose target path contains a `/stow/` segment: the artefact GNU stow leaves behind for
every file in a deployed package. On a healthy deployed dotfiles host every stow-managed link resolves into the
canonical checkout's `stow/` tree. One that resolves anywhere else, or dangles, is drift, and the signature of a deploy
run from a non-canonical checkout.

## Shared trees

### Foreign subtree

A directory inside one repository's working tree whose contents belong to a different repository, mounted by a symlink
so the containing repo never tracks them.

A foreign subtree is invisible to the containing repo's version control and fully visible to anything that walks the
filesystem, which is what makes it hazardous: a tool that writes rewrites another project's content with no signal,
while the containing repo's status stays clean. Every tool that touches one has to decide deliberately which repository
it is acting for, and the right answer differs by tool. A tool enforcing the containing repo's exclusions has to
describe the file by the path it was reached through, because resolving that path to its real location discards the
prefix those exclusions are written against; a tool meant to judge the content on its owner's terms has to do the
opposite. An exclusion naming a foreign subtree is in force only once the tool demonstrably matches paths the way the
exclusion assumes, so presence of the rule is not evidence that it applies.

### Shared clone

The single local checkout of a repository that several working trees mount as a *foreign subtree* and several concurrent
sessions write to.

One index and one working tree serve every writer, so staging broadly there captures another session's in-progress work:
a writer commits only the paths it authored, and from an isolated checkout rather than the shared one. That checkout
also drifts behind its remote while other writers push, so a safe write syncs first rather than assuming the local tip
is current.

### Phantom copy

A file in a *shared clone*'s working tree whose content already equals the remote's version of that path, left behind
when a writer pushed from an isolated checkout and the shared checkout never fast-forwarded over it.

A phantom copy blocks a fast-forward the way real work does, but discarding it loses nothing, and that is the whole
test: a path is a phantom only when its content matches the remote, and being uncommitted or differing from the remote
does not make it one. Every other uncommitted change in a shared clone is another writer's in-progress work, which a
sync carries across or leaves alone and never reverts.

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

Reach is load-bearing as well. Every program a shell starts inherits what the chain exports, so the chain is the right
home only for a variable all of them should see. A value only one process needs, such as the display a headless service
draws on, belongs in that process's own unit or wrapper: exported from the chain, it reaches every program a shell
launches, and a program that would have failed without it runs instead.

### Bare launcher

A process that spawns a shell without sourcing any startup file, so it inherits only the PATH and environment its parent
handed it and never runs the *shell config chain*. Cron, launchd and systemd jobs, GUI applications, git hooks, and the
coding agent's command tool are all bare launchers. A bare launcher that needs a non-default tool on PATH must receive
it from its own process environment (its unit, plist, or launcher configuration), not from the shell config chain.

On macOS that launcher configuration includes a baseline every GUI application and LaunchAgent shares: the user PATH
launchd reads at boot. The repo declares it with Homebrew first, so a process launchd starts resolves `env bash` and the
rest of `/opt/homebrew/bin` ahead of the system copies. Unset, the baseline holds only the system directories, where
`env bash` finds the system bash 3.2. The baseline is a floor, not the shell's PATH: the chain's other additions, such
as `~/.local/bin`, reach a launchd-started process only through its own plist.

Automated and remote callers are not bare launchers by default, and assuming they are is a mistake in the expensive
direction. A caller that requests a login shell reads the chain however headless it is, which exposes it to everything
the chain can get wrong rather than exempting it. Whether a caller is a bare launcher is decided by its *invocation
shape*, not by whether a human is watching.

### Invocation shape

The combination of shell dialect, login versus non-login, and interactive versus non-interactive that decides which
startup files a shell process reads. Two processes running the same command reach different environments when their
shapes differ, so the shape is the unit at which shell environment behavior is specified and verified, not the command.

Those three flags do not settle it for bash on their own. A non-login, non-interactive bash running a command string
reads its interactive startup file when it counts itself as a top-level shell and its standard input is a socket,
because it takes itself to have been started by a remote shell daemon. A launcher that clears the environment makes
every bash it starts top-level, so where such a shape's standard input comes from is part of the shape.

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

### Shadowed executable

A command installed twice on one host, where `PATH` order alone decides which copy answers. The two are maintained by
different mechanisms — a package manager upgrades one, a self-updater or a hand-made symlink maintains the other — and
neither mechanism can see the other's copy. Nothing reports the split: both respond to `--version`, and only comparing
the two reveals that upgrades have been landing on a binary no caller reaches.

The failure is quiet in both directions. A stale copy earlier on `PATH` answers every call while the maintained one sits
idle, and a copy that merely *could* appear earlier turns a missing file into a silent substitution rather than an
error. Tools are therefore installed from one source per host, and a second copy of the same command is drift to remove,
not a fallback to keep.

A deliberate wrapper is the one sanctioned second copy: a script installed under a tool's own name, earlier on `PATH`,
so every call passes through it (to enforce a guard or supply configuration) before it hands off to the real binary. It
works only while its directory precedes the wrapped copy's in every *invocation shape*. The *shell config chain*
therefore moves such a directory to the front rather than adding it only when absent, since a PATH inherited from a
parent can hold it behind the copy it wraps. When that happens the real binary answers, and nothing reports that the
wrapper's guard never ran.

### Captured environment

The environment or argument list a long-lived process took at start and continues to serve, regardless of what the files
that produced it say now. A multiplexer server hands every new pane the environment it started with; a launch agent runs
the argument list it was bootstrapped with; an already-running process keeps the variables it inherited. Editing the
config that seeds any of them changes what *new* processes get, and changes nothing about what is already running.

This is why removing an export cannot clear an inherited value: the config stops setting the variable, but nothing
unsets it in a process that already holds it. Verification has to start a process from outside the captured state — a
fresh login rather than a new pane — and adopting a change means reloading or restarting whatever holds the old copy.

A multiplexer holds two captured copies, not one. Beside the server-wide environment from its start, each session keeps
its own copy of a set list of variables, refreshed from whichever client creates or attaches to it, and that copy wins
for every new pane. A stale value in the session copy is invisible to a check of the server-wide one, and every server
on the host keeps its own sessions. Both copies can be edited in place, so new panes stop receiving a value without a
restart; only processes already running need one.

## Policies

### Supply-chain age gate

The minimum-release-age policy applied to every supported package manager on a deployed dotfiles host: a version newly
published to its upstream registry is not resolvable until it has been public for at least the gate's configured number
of days. Each package manager exposes the policy through its own configuration key (env var, config file, or both), and
each requires a tool version recent enough to honor it — older versions silently ignore the setting, so the gate is
paired with a version floor for every PM it covers. The gate is enforced via shell env vars (covering interactive and
shell-launched processes) and, where the tool supports a global config file, written into that file (covering cron,
systemd units, and other non-shell invocations).

## Local checks

### Local gate

A check that runs on the developer's own machine at a git lifecycle point and mirrors what continuous integration would
check, so the same verdict is reached before the work leaves the machine. Gates come in a pair that differs in scope and
in nothing else: one runs at commit time over the staged paths and stays fast enough that nobody reaches for a bypass
flag, the other runs at push time over the whole repository. Both route through one shared library, so a check exists
once and the pair cannot drift into different coverage or different execution models.

A local gate is a compensating control rather than a convenience. Where continuous integration has been thinned to one
run per change, the gate is the only check some work ever gets, so a gate that silently passes leaves nothing behind it.
Activation is per clone and does not travel with the checkout, which makes an unwired gate the common failure: it looks
identical to a passing one.

### Guard hook

A hook that inspects a proposed action before it happens and answers allow or deny, as opposed to a *local gate*, which
checks content that already exists. A guard's answer is its entire output: it signals deny by emitting a structured
refusal and allow by emitting nothing at all, so silence is a verdict rather than an absence of one.

That encoding is what makes a guard's failure mode asymmetric. Any path that ends without an explicit refusal reads as
permission, so a guard that errors, exits early, or misreads its own check allows the thing it exists to block, and does
so indistinguishably from a genuine pass. Guards therefore need their allow path tested as deliberately as their deny
path, and a guard whose verdict is derived from an exit status needs that status to be unambiguous.

### Format hook

A hook that rewrites a file's contents immediately after a write, as opposed to a *guard hook*, which decides whether an
action may happen at all, or a *local gate*, which checks content already on disk at a git lifecycle point. It returns
no allow-or-deny verdict, and its principal output is the modified file, so a wrong decision inside one is committed
rather than reported. It may still forward findings a reader can act on, which is a report about the content and not a
verdict on the action.

Which formatting applies is a property of the edited file's own repository rather than of the session the edit was made
from, and a repository may declare that it owns its own formatting, in which case the hook leaves it untouched. Both
facts are settled by walking up from the file itself, so a hook that settles them from the session's directory instead
formats files in one repository under another's rules, and does so silently, because the rewrite it leaves behind looks
like the file's own style. A format hook also decides whether to run at all from the same lookup, which means a
mis-resolution can disable the exclusions a repository relies on without any signal that they stopped applying.

## File hand-off

### Hand-off route

The path a file takes when yazi on the headless host opens it on the Mac the operator is sitting at, chosen by what the
file is rather than by a key. The *edit route* covers every file yazi would otherwise hand to the editor: the Mac's
editor opens the host's file in place over Remote-SSH, so a save is a write to the host's disk. The *view route* covers
everything else (PDFs, images, audio, video, office documents): the Mac opens the file with its default application, in
place through the Taildrive share when the file lives under a shared root, from a copy when it does not. Both routes are
fire-and-forget. A hand-off happens only when the session is driven from the Mac; otherwise, and whenever the Mac is
unreachable or the hand-off fails, the file goes to the host's local opener where one exists, with the reason shown.

## Parallel agents

### Agent slot

A clone of a repo, at a stable numbered path (`~/slots/<repo>/<N>`) on the headless host, that holds exactly one agent
task at a time. A slot is set up like the repo's *prime checkout* (the operator's own clone under `~/dev`, or
`~/dotfiles`, which is never part of the slot pool and never changed by it): the repo's hooks run from the slot's own
copy, the `docs/solutions` symlink is present, Claude reads and writes the repo's single auto memory, the prime's local
permission grants apply, and a prime that is a partial clone gives the slot a partial clone with the same filter. A slot
path is either empty or holds one task. The task keeps its slot through review rounds until it has finished: none of its
PRs is open or closed without merging and one has merged, the operator finished it, whatever state its PRs are in, or
its agent released it with no PR open. A
task's PRs are those opened from its branches after its slot was made, and an older one whose head a branch of the slot
holds beyond the base, such as the PR a review round works on. The slot's agent ends its task with a *release*: once it
has run the closing skills that record its learnings and stopped every background job it no longer needs, it hands the
slot's teardown upstream, to a finish outside the slot that waits for the agent to go idle. An agent still waiting on
something, such as CI, never stops that wait to release: it records why the slot is *not yet* ready, which keeps the
slot off the needs-you list while the agent is there and gets the agent reminded later. Of the agent's release and its
not-yet, the newer stands: a not-yet withdraws an earlier release, and the finish that release started stands down. It
never undoes the operator's finish, which is the operator's decision rather than the agent's. A *slot sweep* deletes the
clone, moving it to the trash and purging it from there at once, only when nothing in it is missing from GitHub (a PR's
head, origin, or the fork on origin's host that one of its branches tracks or pushes to) and its agent is idle or gone;
the *automatic sweep*, which a timer runs, deletes only a slot its agent released or the operator finished, and first
reminds the agent of a finished slot held back only by files left in it to clean them up. A slot that fails that check
stays put on the *needs-you list*, which names each blocker, and is never deleted. A slot whose tmux sessions are gone
after a server reboot is *dormant* until resume restarts them and its conversation.

### Agent state

What a slot's agent is doing as the slot tooling reads it, from Claude Code's own list of sessions joined on the slot's
path: *idle* at its prompt, *busy* mid-turn, *waiting* on a permission prompt or a question, or *absent*, with no
session and no process using the slot other than the slot's own terminal panes. Only idle and absent let an *agent slot*
be torn down.

The state is *unknown*, and the teardown refused, whenever it cannot be read with certainty: the session list cannot be
read, more than one session matches, the session reports a status other than idle, busy, or waiting, a Claude process in
the slot's panes runs with no session matching the slot, or a process outside the slot's panes has its working directory
or an open file in the slot. A process counts as the panes' own when it descends from one, or when it is the prompt's
`gitstatusd` daemon and its environment names the slot's terminal server and one of its panes. Every process a pane
starts inherits that environment, so it marks only `gitstatusd` as the panes' own: a job a pane's command left running,
such as one a test run in the slot leaked, holds the slot until it exits, like anything else in the slot.

## Flagged ambiguities

- "Gate" names two different things: a *supply-chain age gate* is a policy applied to package resolution, while a *local
  gate* is a check that runs at a git lifecycle point. These are distinct.
- A *guard hook* answers allow or deny about an action that has not happened yet, a *format hook* rewrites a file just
  after it is written, and a *local gate* checks content that already exists at a git lifecycle point. All three are
  sometimes called "hooks" informally, since all three are installed as such.
- A *cross-package symlink* and a *foreign subtree* are both symlinks into another source, and they differ in how far
  they reach: the first stays inside this repo, pointing from one stow package's source into another's, while the second
  points at a separate repository whose files this repo does not track.
- A *canonical checkout* is the one clone of this repo, `~/dotfiles`, that may deploy into the real home. A *prime
  checkout* is the operator's own clone of any repo, as opposed to its *agent slots*. The two do not interchange.
