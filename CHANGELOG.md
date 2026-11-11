# Changelog

All notable changes to this project will be documented in this file.

## [2026.11.09] - 2026-11-10

### Breaking changes

- Remove launching a slot without a model: `agent-slot launch` and `agent-slot reopen` require `--model opus` or `--model sonnet`. by @brettdavies in [#458](https://github.com/brettdavies/dotfiles/pull/458)
- Require `Touches:` and `Adds:` lines in a slot brief; `launch` and `reopen` refuse a brief without them with `brief-incomplete`. by @brettdavies in [#464](https://github.com/brettdavies/dotfiles/pull/464)
- Remove `mux`, `mux-all`, `tmux-new-session`, and the `stow/tmuxinator` projects. Press the new-agent key in a repo's Rex session, or run `agent-slot prime <repo>`, to start its prime. On the Mac, start local sessions with `tmux new -s` by hand. by @brettdavies in [#466](https://github.com/brettdavies/dotfiles/pull/466)
- Change the new-agent key's first press in every repo session with no tab holding its prime: it now starts and opens the prime, and the next press starts a slot. `agent-slot-rex launch --repo <repo>` starts a slot without opening the prime first.
- Remove the Playwright version argument of `scripts/playwright-browsers-deploy.sh`; the browser set now comes from `config/playwright/browsers.pin`, and a run that passes a version exits 2 naming the pin. by @brettdavies in [#470](https://github.com/brettdavies/dotfiles/pull/470)

### Added

- Add `agent-slot`, which gives each Claude Code agent its own full clone of a repo at `~/slots/<repo>/<N>` on the Linux server, runs Claude, yazi, and lazygit there in tmux, and deletes a finished slot only when nothing in it would be lost. by @brettdavies in [#308](https://github.com/brettdavies/dotfiles/pull/308)
- Add `agent-slot-rex` and the `rex` package on the Mac: `cmd+alt+n` starts an agent in a background Rex tab, `cmd+alt+r` restores every slot's tab, and `cmd+alt+f` finishes the focused tab's task.
- Add Claude Code hooks that show a slot agent's state (working, waiting on you, done) on its Rex tab and give the agent its slot's rules.
- Add a dedicated `agent-slots` tmux server config (`slots.conf`, sharing `base.conf` with `tmux.conf`) and a timer that prunes its orphaned clients.
- Add `agent-slot schema`, which prints the JSON Schema of every success and error object and the full table of error reasons; each verb's `--help` now names the fields it returns. by @brettdavies in [#309](https://github.com/brettdavies/dotfiles/pull/309)
- Add allow rules so agents run `agent-slot repos`, `list`, `whoami`, `check`, `doctor`, and `schema` without a permission prompt.
- Add an amber tint to the whole tmux view while its terminal pane is unfocused, matching the tint tmux already gives inactive panes, on both the default and agent-slots servers. by @brettdavies in [#313](https://github.com/brettdavies/dotfiles/pull/313)
- Add bypass permissions mode for slot agents: `agent-slot launch` and `agent-slot resume` start each slot's Claude with `--dangerously-skip-permissions`. by @brettdavies in [#315](https://github.com/brettdavies/dotfiles/pull/315)
- Add an `agent-slot doctor` warning, `bypass-mode-unaccepted`, raised when Claude's settings have not accepted bypass permissions mode.
- Add the `reconcile-busy` error reason and the `AGENT_SLOT_REX_LOCK_WAIT` setting (300 s), the longest a restore, sweep, or finish waits for the one ahead of it. by @brettdavies in [#326](https://github.com/brettdavies/dotfiles/pull/326)
- Add `~/.local/state/agent-slot-rex/reconcile.log` on the Mac: one JSON line for each restore, sweep, or finish pass, giving when it ran, what ran it, the tabs it planned to open, relabel, and close, and `ok` or the error that stopped it. Past 1 MiB it moves to `reconcile.log.1`. by @brettdavies in [#332](https://github.com/brettdavies/dotfiles/pull/332)
- Add a server push: `agent-slot launch`, `sweep --yes`, and `finish --yes` ask each Mac in `AGENT_SLOT_REX_CLIENTS` to restore its Rex tabs in the background, so a slot launched or torn down on the server opens or closes its tab with no key press. Each push is logged to `~/.local/state/agent-slot/push.log`. by @brettdavies in [#334](https://github.com/brettdavies/dotfiles/pull/334)
- Add `agent-slot-rex follow`, which Rex starts at load: it restores once a minute (`AGENT_SLOT_REX_POLL_INTERVAL`), and at once when the server answers after the Mac slept or a call could not reach it, logging its events to `~/.local/state/agent-slot-rex/follow.log`.
- Add `scripts/sysctl-deploy.sh`, which copies `config/sysctl.d/` into `/etc/sysctl.d/`, applies it, and verifies each value; `--check` reports drift without root. by @brettdavies in [#335](https://github.com/brettdavies/dotfiles/pull/335)
- Add `agent-slot release`: a slot's agent runs it as its last step, after `ce-compound` and `ce-compound-refresh`, and the slot is torn down once the agent is idle and its task has finished. It refuses with `compound-not-run` until both skills have run. by @brettdavies in [#336](https://github.com/brettdavies/dotfiles/pull/336)
- Add `agent-slot-sweep.timer`, which runs `agent-slot sweep --yes --auto` every ten minutes to tear down released slots, types a finished slot's idle agent its closing steps, and lists a slot with no agent to release it as `not-released`. Enable it with `bash scripts/host-jobs-enable.sh`.
- Add `~/.local/state/agent-slot/teardown.log`, one line per release, `finish --yes`, and `sweep --yes` pass, and the `sweep-timer-inactive` doctor finding.
- Add a standing review sequence for every plan an agent writes: `/plan-eng-review`, `/plan-devex-review`, then `/compound-engineering:ce-doc-review`, with the plan committed and pushed after it is written and after each review. by @brettdavies in [#342](https://github.com/brettdavies/dotfiles/pull/342)
- Add slot context that sends a decision only a person can make to the session the slot's brief reports to as one `SendMessage`, instead of asking in a tab nobody watches.
- Add `agent-slot release --not-yet '<why>'`, which records why a slot is not ready to release; the automatic sweep keeps that slot off the needs-you list and reminds its agent once after `AGENT_SLOT_RELEASE_REMIND` seconds (1800). by @brettdavies in [#343](https://github.com/brettdavies/dotfiles/pull/343)
- Add a cleanup reminder: the automatic sweep types the idle agent of a finished slot kept only by leftover files one message naming them, before listing the slot.
- Add `scripts/rex-login-server-deploy.sh`, which serves the Rex login server on port 7297 of the host's tailnet addresses and lets the Tailscale login given by `--login` in as the account that runs `sudo`. by @brettdavies in [#348](https://github.com/brettdavies/dotfiles/pull/348)
- Add a Claude Code hook that refuses a `git commit` whose output is piped when a later step in the same command deletes or moves its message file, and offers the same command without the pipe. by @brettdavies in [#356](https://github.com/brettdavies/dotfiles/pull/356)
- Add `branches` to agent-slot's teardown ledger event: each local branch other than the base, with its commit, the remote it pushes to, and that remote's URL. by @brettdavies in [#359](https://github.com/brettdavies/dotfiles/pull/359)
- Add a global Claude Code rule that the account's email address is never sent to an outside service, including in a `User-Agent` header an API's etiquette asks for. by @brettdavies in [#365](https://github.com/brettdavies/dotfiles/pull/365)
- Add a Claude Code hook that refuses any tool call, MCP and subagent calls included, carrying the account's email address, its local part, or an entry of the git-crypt-encrypted never-send list the `secrets` package stows, and tells the model how to finish without it. The built-in Grep and Glob tools, which only read local files, are exempt. It blocks the call when the hook itself cannot run. by @brettdavies in [#368](https://github.com/brettdavies/dotfiles/pull/368)
- Add `~/.claude/never-send-guard.sh --check`, which shows which values the guard protects, which list lines it skips, and whether the list is still locked, without printing any of them.
- Add `agent-slot launch <repo> --pr <ref>` and `--issue <ref>`: the slot is named `<repo>-pr<N>-<slug>` or `<repo>-issue<N>-<slug>` and starts on the PR's head branch from the remote that holds it. by @brettdavies in [#369](https://github.com/brettdavies/dotfiles/pull/369)
- Add `agent-slot adopt <repo>/<N> (--pr|--issue) <ref>` to attach a PR or issue to a running slot. Slots also take a PR's name when `check` adopts it, and their Claude sessions are renamed to match.
- Add `agent-slot reopen <repo> (--pr|--issue) <ref>` to bring a torn-down slot's work back in a fresh slot on its head branch with the prior Claude conversation resumed. `--dry-run` reports the plan, and `--session <id>` reopens a slot torn down before work items were recorded.
- Add `agent-slot finish <key> --yes --allow-open-pr` to finish a task whose PR stays open.
- Add `jaq` to the Brewfile. Run `brew bundle --file=~/dotfiles/stow/brew/Brewfile` after pulling. by @brettdavies in [#371](https://github.com/brettdavies/dotfiles/pull/371)
- Add a `.context/repo-recon` link to each new or reopened agent slot whose repo has a repo-recon store at `~/dev/repo-recon/<owner>/<repo>`, found from the prime checkout's `origin` remote and then its `upstream`, so repo-recon runs inside a slot. `agent-slot check` and teardown accept the link while it points at that store, and a teardown deletes only the link, never the store. `AGENT_SLOT_REPO_RECON` overrides the store root. by @brettdavies in [#372](https://github.com/brettdavies/dotfiles/pull/372)
- Add `scripts/stow-deploy --only <package>...`, which deploys exactly the named packages instead of adding them to the shared set. by @brettdavies in [#374](https://github.com/brettdavies/dotfiles/pull/374)
- Add a per-slot worktree of the solutions repo: every new agent slot's `docs/solutions` links to its own detached worktree under `~/slots/<repo>/.solutions/`, which the slot's teardown removes. by @brettdavies in [#375](https://github.com/brettdavies/dotfiles/pull/375)
- Add the `solutions-unpublished` teardown blocker, which keeps a slot while its solutions worktree holds a file, commit, or rebase `origin/main` lacks, and the `agent-slot doctor` warning `solutions-worktree-orphaned` for a worktree whose slot is gone.
- Add a session-start report of the changes `~/dev/solutions-docs` holds that `origin/main` lacks, shown to the person in a repo's own checkout.
- Add a `Canonical version` stamp to the global PR template, so a repository's copy shows which version it started from. by @brettdavies in [#378](https://github.com/brettdavies/dotfiles/pull/378)
- Add a macOS `hex` stow package that deploys the Hex dictation app's `settings.json`, encrypted with git-crypt. by @brettdavies in [#384](https://github.com/brettdavies/dotfiles/pull/384)
- Add `--shard I/N` to `scripts/run-tests`, which runs shard I of N of what `--all`, `--perf-only`, or `--no-perf` runs, so the bats suite can be split across machines. by @brettdavies in [#385](https://github.com/brettdavies/dotfiles/pull/385)
- Add the `# run-tests: parallel` declaration: a test file carrying it on a line of its own has up to four of its tests run at once by `scripts/run-tests`.
- Add `config/hex/hex.config.ts` and `scripts/hex-config.sh`, which copies Hex's transforms into `~/.config/hex`; macOS deploys report when the two differ. by @brettdavies in [#386](https://github.com/brettdavies/dotfiles/pull/386)
- Add a `dotfiles` Hex transform to the Coding mode, so a spoken "dot files" pastes as `dotfiles` in terminals, editors, claude.ai, and github.com.
- Add a CI caching rule to the global Claude instructions: every CI job caches its downloads and installs wherever a measured cache saves time. by @brettdavies in [#387](https://github.com/brettdavies/dotfiles/pull/387)
- Add the `com.user.bd-tunnel` LaunchAgent, which keeps the dev-port forwards to the Linux server open on the Mac's localhost with no SSH tab open, reconnects after sleep or a network change, and logs any forward refused because its local port is busy to `~/Library/Logs/bd-tunnel.error.log`. by @brettdavies in [#389](https://github.com/brettdavies/dotfiles/pull/389)
- Add `rex-server.service`, a user unit on the Linux server that keeps the account's Rex server running with no client connected and takes the account socket back after the Rex login server's own server exits; `scripts/host-jobs-enable.sh` enables it. by @brettdavies in [#390](https://github.com/brettdavies/dotfiles/pull/390)
- Start the agent-slots tmux server in a transient systemd user scope of its own, so stopping the timer or Rex service that started it no longer ends the agents.
- Add server-side checks to `agent-slot-rex doctor`: a Rex server that is down or that `rex-server.service` did not start, a restart pending after a Rex upgrade, the reconcile timer, the tab-number watcher, the login server, rexurrect, a stale reconcile journal, the slot tmux server's cgroup and responsiveness, and own tabs left unrestored. by @brettdavies in [#393](https://github.com/brettdavies/dotfiles/pull/393)
- Add a macOS forwarder to `agent-slot-rex`: `launch`, `restore`, `finish`, `sweep`, and `doctor` run on the Linux server's helper over ssh, and the verbs that drive a Rex server of their own stop with `wrong-host`.
- Add ask rules for `agent-slot-rex finish` and `agent-slot-rex sweep`.
- Add `slot-unattended.sh`, a Claude hook that denies, inside an agent slot, every permission request and every `AskUserQuestion`, `EnterPlanMode`, and `ExitPlanMode` call, with a message telling the agent how to go on, so a slot never stalls on a dialog nobody answers. Outside a slot, dialogs show as before. by @brettdavies in [#395](https://github.com/brettdavies/dotfiles/pull/395)
- Add `prompt-denied` and `prompt-waiting` events to the agent-slot ledger, one per denied dialog and one per dialog still waiting after about 6 s.
- Add `agent-slot-reconcile.timer`, which keeps agent slot tabs on the Linux server's Rex server matched to the live slots every minute. by @brettdavies in [#397](https://github.com/brettdavies/dotfiles/pull/397)
- Add the Rex start-up step, `agent-slot-rex restore --at-start`, which restores the operator's own tabs with rexurrect once per server instance before it gives every live slot its tab.
- Add a yazi package step to `scripts/stow-deploy`: a deploy to `$HOME` that stows yazi runs `ya pkg install`, so each host gets the plugin and flavor revisions `package.toml` pins. A failed install prints a warning with the rerun command and does not fail the deploy. by @brettdavies in [#399](https://github.com/brettdavies/dotfiles/pull/399)
- Add `rex-tab-numbers.service`, which shows each tab's position number at the start of its label on the Linux server's Rex server, for every client. by @brettdavies in [#400](https://github.com/brettdavies/dotfiles/pull/400)
- Add `ya pkg install` to the daily brew job on Linux and macOS, so installed yazi plugins and the flavor match `package.toml` every day; a failed install is a warning, not a failed run. by @brettdavies in [#404](https://github.com/brettdavies/dotfiles/pull/404)
- Add automatic yazi plugin pin bumps on the Linux server: when Homebrew's yazi differs from the version the pins were last proven on, the brew job moves the pins to upstream revisions that reached their branch at least seven days ago, proves them in a running yazi, merges the PR into `dev`, and pulls `~/dotfiles` when it can.
- Add `yazi_pins` to the brew job's `run.end`, with the bump's outcome, reason, PR, host pull result, and next step.
- Add the repo's prime to the new-agent key: in a Linux server session named after a repo listed in `config/agent-slot-rex/primes.tsv`, the key opens the prime tmux session as the session's first tab when no tab is attached to it, and starts a slot once one is. by @brettdavies in [#413](https://github.com/brettdavies/dotfiles/pull/413)
- Add `agent-slot-rex prime <repo>`, which attaches to the repo's prime session from `$HOME` and drops to a login shell on detach.
- Add a "Failed systemd user units" section to the Claude session context, listed only when a user unit has failed. by @brettdavies in [#420](https://github.com/brettdavies/dotfiles/pull/420)
- Add a `primes` field to each `reconcile.log` line, holding each repo's prime re-attach outcome from the start-up step on a new Rex server instance, and the `AGENT_SLOT_REX_PRIME_WAIT` setting (5 s) for how long the step waits for a re-attached prime's client. by @brettdavies in [#421](https://github.com/brettdavies/dotfiles/pull/421)
- Add `scripts/playwright-browsers-deploy.sh --check`, which reports a missing or incomplete browser, an alias that no longer resolves, or an unregistered set, and names the command that restores it. by @brettdavies in [#431](https://github.com/brettdavies/dotfiles/pull/431)
- Add `key_to_ready` to `agent-slot doctor`: the time from the new-agent key's tab opening to the slot's Claude starting, with the median of each step between, over the last 20 key presses. by @brettdavies in [#432](https://github.com/brettdavies/dotfiles/pull/432)
- Add `--opened-at` and `--shown-at` to `agent-slot launch`, which the new-agent key's tab passes and the launch's ledger line keeps.
- Add `agent-slot warm --all`, which trusts the slot paths of every repo `agent-slot repos` lists and fails with `prime-untrusted`, naming each repo whose prime checkout Claude does not trust. by @brettdavies in [#439](https://github.com/brettdavies/dotfiles/pull/439)
- Add `agent-slot-warm.timer`, which runs `agent-slot warm --all` every ten minutes, so a new repo's slots start warm within ten minutes of its prime being trusted.
- Add the `warm-timer-inactive` doctor check.
- Add a dependency install to agent slot setup: a new slot on its base branch gets a frozen install of its `bun.lock`, `pnpm-lock.yaml`, or `package-lock.json` before its agent starts, when its prime has `node_modules` and Claude trusts the prime, so the repo's tool-backed hooks pass on the first push. The launch reports the outcome in `deps`, and an install that does not finish keeps the slot. by @brettdavies in [#445](https://github.com/brettdavies/dotfiles/pull/445)
- Add `AGENT_SLOT_DEPS_TIMEOUT`, the seconds a new slot's dependency install may take (60).
- Add primes for agent-skills, meum-api, meum-sdk, meum-ios, meum-sites, meum-id-dot-github, and meum-control, so the new-agent key opens each repo's prime tab rather than starting a slot. by @brettdavies in [#446](https://github.com/brettdavies/dotfiles/pull/446)
- Add the Obsidian vault as an agent-slot repo: `agent-slot launch obsidian-vault` makes a slot, and several can run at once, each committing its own work on main and rebasing on `origin/main` before each push. by @brettdavies in [#447](https://github.com/brettdavies/dotfiles/pull/447)
- Accept a prime checkout whose git directory lives outside it (`git clone --separate-git-dir`), while still refusing linked worktrees.
- Add `agent-slot probe <pr>` and `agent-slot close-probe <pr>`, so a slot can mark an open draft it pushed, titled `test(probe): <what it probes>`, as a throwaway probe and close it without an operator. A marked probe closed unmerged no longer blocks the slot's teardown. by @brettdavies in [#452](https://github.com/brettdavies/dotfiles/pull/452)
- Add `config/agent-slot/trusted-owners` and `AGENT_SLOT_TRUSTED_OWNERS`, the GitHub owners whose heads count as the operator's own. An empty override trusts no owner. by @brettdavies in [#453](https://github.com/brettdavies/dotfiles/pull/453)
- Add `head_foreign` and `head_owner` to `agent-slot launch`, `reopen`, `whoami`, and their ledger lines.
- Add the `brief-incomplete` refusal for a launch brief without its `Scope:`, `Limits:`, `Reviews:`, and `Reports to:` lines. by @brettdavies in [#457](https://github.com/brettdavies/dotfiles/pull/457)
- Add `--model` to `agent-slot launch` and `reopen`: each slot starts on that model at `--effort xhigh`, a Sonnet one with Opus as its advisor. by @brettdavies in [#458](https://github.com/brettdavies/dotfiles/pull/458)
- Add branch pruning to `agent-slot resume`: it deletes the slot's branches whose PRs merged or closed, in the slot and on origin, and reports them in `pruned_branches`. by @brettdavies in [#459](https://github.com/brettdavies/dotfiles/pull/459)
- Add `slot-review-cap.sh`, which denies a slot agent's third `ce-code-review` round per branch and records each allowed round in the agent-slot ledger. by @brettdavies in [#463](https://github.com/brettdavies/dotfiles/pull/463)
- Add `agent-slot grant-review <repo>/<N>`, which allows one more round on the slot's current branch and refuses from inside a slot with `review-grant-from-slot`.
- Add `scope.touches` and `scope.adds` to the slot record, taken from the brief's `Touches:` and `Adds:` lines. by @brettdavies in [#464](https://github.com/brettdavies/dotfiles/pull/464)
- Add `slot-scope-guard.sh`, which denies a slot agent's `git push` of a path no `Touches:` glob or scope grant covers.
- Add `agent-slot grant-scope <repo>/<N> <pathspec>`, which lets a slot's PR change the paths a pathspec matches once a person types the slot's key at a terminal. by @brettdavies in [#465](https://github.com/brettdavies/dotfiles/pull/465)
- Add the reasons `scope-grant-from-slot`, `grant-needs-terminal`, and `grant-not-confirmed`. A pathspec with exclude magic or a control character, or one that covers none of the paths the branch changes, is refused with `usage`.
- Add `agent-slot prime <repo>`, which starts whichever of a repo's prime sessions is missing and says where the prime runs. A start cut off before a session's program is typed in leaves that session named `<name>-starting-p<pid>`, and the next start kills it and lists it in `cleared`. by @brettdavies in [#466](https://github.com/brettdavies/dotfiles/pull/466)
- Add `primes[]` and `primes_unread[]` to `agent-slot list`, and a `prime` field to `launch`, `reopen`, and `resume` output, so a slot start reports its prime or why it did not start, and a list says which server's primes it could not read.
- Add `streams-control` and `gbrain` to the repos `agent-slot repos` lists.
- Add a pinned system browser set (Chrome for Testing, WebKit, ffmpeg) with an alias for every revision a Playwright release from 1.57 to the pin's `source-release` asks for, deployed on the Linux server and on Apple silicon Macs. by @brettdavies in [#470](https://github.com/brettdavies/dotfiles/pull/470)
- Add `--check`, `--pin PATH`, and `--help` to the browser deploy, with a stable reason on every failure and a reason table in the Playwright runbook.
- Add `agent-slot resume <repo>/<N> --model (opus | sonnet)`, which switches a live slot's model and restarts an idle Claude on it, resuming its conversation by session ID. The JSON gains `model`, `previous_model`, and `restarted`. by @brettdavies in [#473](https://github.com/brettdavies/dotfiles/pull/473)
- Add the `agent-busy` reason: a `resume --model` found the agent busy, waiting, unreadable, or running commands, or ran inside the slot's own agent, and changed nothing.
- Add `skill-listing-refresh` and its daily timer, which keep skills no session used in 30 days listed by name only and restore a skill's description once it is used again. by @brettdavies in [#475](https://github.com/brettdavies/dotfiles/pull/475)
- Add `agent-slot retask`, which gives a live slot a new task in a new Claude session. by @brettdavies in [#477](https://github.com/brettdavies/dotfiles/pull/477)
- Add a read-discipline line to every agent slot's startup context: search before reading, read a line range rather than a whole file, and do not re-read a file that has not changed. by @brettdavies in [#478](https://github.com/brettdavies/dotfiles/pull/478)
- Add `scripts/openseo-deploy.sh` (`render`, `up`, `down`, `serve`, `status`, `create-admin`) to run OpenSEO's standalone Docker stack on the Linux server, pinned by image digest, behind the `svc:openseo` tailnet service. by @brettdavies in [#480](https://github.com/brettdavies/dotfiles/pull/480)
- Add the `svc:openseo` binding to `scripts/tailscale-serve-setup.sh`, applied only on a host that holds `~/.config/openseo/local.env` and only once OpenSEO has an account.
- Add a `task:` segment to a prime's status line, showing the branch or PR it is working on. by @brettdavies in [#481](https://github.com/brettdavies/dotfiles/pull/481)
- Add `session-title.sh`, a `UserPromptSubmit` hook that titles a session outside the slots from its branch or open PR.

### Changed

- Change `agent-slot launch` to report `prompt_delivered`, to point its next step at the new slot's `check`, and to tell a retry whose slot is still setting up to retry. by @brettdavies in [#309](https://github.com/brettdavies/dotfiles/pull/309)
- Change teardown to stop the agent and every process still below it, and the teardown check to count commits only a local tag reaches.
- Change the agent-slot verified versions to Claude Code 2.1.311 and Rex 0.0.1793047680-g2db882, so `agent-slot doctor` and `agent-slot-rex doctor` no longer warn on them. by @brettdavies in [#310](https://github.com/brettdavies/dotfiles/pull/310)
- Change the reconcile log: each line records `ms` and `changed`, and `by` names `push`, `reconnect`, and `poll` passes. `agent-slot-rex restore` takes `--by push|poll|reconnect`. by @brettdavies in [#334](https://github.com/brettdavies/dotfiles/pull/334)
- Change the slot startup context to end every task with the closing sequence (compound, refresh, release, report and stop), and point `checked-by-own-agent` at `agent-slot release`. by @brettdavies in [#336](https://github.com/brettdavies/dotfiles/pull/336)
- Change the stowed Claude Code settings to deliver messages from other local Claude sessions without an approval hold (`crossSessionInbound: "accept"`), so agent-slot hand-offs reach a session running in a different permission mode. by @brettdavies in [#338](https://github.com/brettdavies/dotfiles/pull/338)
- Change `agent-slot release` to refuse with `background-jobs-running` while the slot's Claude still runs a background Bash tool command, naming each job's PID and command. by @brettdavies in [#343](https://github.com/brettdavies/dotfiles/pull/343)
- Change the closing steps in a slot's startup context and the sweep's closing text to delete scratch files, commit real work, and stop unneeded background jobs before release.
- Change the subagent watchdog rule: the parent stops a subagent's watchdog as soon as its completion notice arrives, and the guide's watchdog command exits on its own once the output file shows the subagent finished, keeping the 10-minute quiet rule only for a stall. by @brettdavies in [#344](https://github.com/brettdavies/dotfiles/pull/344)
- Change an operator finish to end a slot's task even while one of its PRs is still open. Teardown still keeps the slot until every commit is in a PR head or on GitHub. by @brettdavies in [#360](https://github.com/brettdavies/dotfiles/pull/360)
- Change `agent-slot release --not-yet` on a slot the operator finished to refuse with `finished-by-operator` rather than report a hold it cannot keep. by @brettdavies in [#364](https://github.com/brettdavies/dotfiles/pull/364)
- Change Claude Code's transcript retention to 365 days so torn-down work stays resumable. by @brettdavies in [#369](https://github.com/brettdavies/dotfiles/pull/369)
- Change the teardown ledger event to record the slot's work items, name, and checked-out branch.
- Change `scripts/stow-deploy --headless` to refuse only a package that needs `--adopt` while its own `stow/<package>/` has uncommitted changes, listing it under `FAILURES` with the fix, instead of refusing the whole run when anything under `stow/` is uncommitted. by @brettdavies in [#374](https://github.com/brettdavies/dotfiles/pull/374)
- Change `sd-commit-doc` to publish in place from the caller's own worktree, deletions and renames included, with `reason:`, `state:`, and `next:` lines on every failure and a `--help`; a repo's own checkout keeps publishing from the shared clone by copy-out. by @brettdavies in [#375](https://github.com/brettdavies/dotfiles/pull/375)
- Change the nightly autocommit job to only fast-forward `~/dev/solutions-docs` and log what it holds that `origin/main` lacks; edits there are no longer committed automatically and need a manual commit.
- Name the `generic` variant on the markdownlint, EditorConfig, and gitattributes stamps. by @brettdavies in [#378](https://github.com/brettdavies/dotfiles/pull/378)
- Change the global PR template to offer six changelog headings: `### Removed` is gone, so a removal that breaks a repo's contract goes under `### Breaking changes` and any other removal under `### Changed`. by @brettdavies in [#383](https://github.com/brettdavies/dotfiles/pull/383)
- Change the PR template's breaking-change box to point at `### Breaking changes` instead of promising a major version bump.
- Run the `bats` CI check as eight parallel shards, cutting its slowest test step from a median of 226 s to under a minute. by @brettdavies in [#385](https://github.com/brettdavies/dotfiles/pull/385)
- Run `scripts/lint-shell`'s ShellCheck sweep over its files concurrently; `--all` takes about 11 s instead of 56 s.
- Show each test file's wall time on its `# <file> (<seconds> s)` marker in the output of a parallel `scripts/run-tests` run.
- Change the SSH config so the dev-port forwards live on a dedicated tunnel host entry, and the interactive host entry forwards nothing. by @brettdavies in [#389](https://github.com/brettdavies/dotfiles/pull/389)
- Change `agent-slot-rex` to run on the Linux server: it calls `agent-slot` locally, attaches slot panes to the local `agent-slots` tmux server, never starts a Rex server, and reads its host, path, and unit defaults from `lib/settings.sh`. by @brettdavies in [#393](https://github.com/brettdavies/dotfiles/pull/393)
- Change the verified Rex build to the Linux server's, `0.1.0-preview.10`.
- Change Claude Code's default effort for Opus 5.5 to xhigh on every host and agent slot. by @brettdavies in [#394](https://github.com/brettdavies/dotfiles/pull/394)
- Mark a slot's Rex tab blocked when Claude Code reports a permission prompt, elicitation, or input request still waiting after about 6 s. by @brettdavies in [#395](https://github.com/brettdavies/dotfiles/pull/395)
- Change agent-slot's push after a launch or teardown to run the local Rex helper's restore instead of ssh to each Mac, and log a pass that changed nothing on purpose as `deferred` in `push.log`. by @brettdavies in [#397](https://github.com/brettdavies/dotfiles/pull/397)
- Change every timer, push, sweep, and finish pass to change nothing and exit 0 when no Rex server answers or its start-up step has not finished, journaling why under `skipped`; a restore asked for by hand reports `rex-server-down` or `startup-pending`.
- Change the `rex` stow package to deploy on the Linux server as well as the Mac, with the Rex start-up step that restores the operator's own tabs and then every slot tab only on the Linux server. by @brettdavies in [#398](https://github.com/brettdavies/dotfiles/pull/398)
- Change the new-agent key (`cmd+alt+n`) to always bring its tab forward, asking which repo to use outside a repo's session, including every session on the Mac.
- Change yazi's git sign for a modified file to follow `git status -s`: `M ` when the change is staged, ` M` when it is not. by @brettdavies in [#399](https://github.com/brettdavies/dotfiles/pull/399)
- Change the agent-slot reconcile and finish key to match and relabel slot tabs past their number, keeping it, so the number and the slot label never overwrite each other. by @brettdavies in [#400](https://github.com/brettdavies/dotfiles/pull/400)
- Change the new-agent key in a Linux server session named after a repo to start a slot with no picker once the prime is open, or right away for a repo with no prime. by @brettdavies in [#413](https://github.com/brettdavies/dotfiles/pull/413)
- Change the default per-test time limit in `scripts/run-tests` from 180 s to 60 s; a hung test now fails as `not ok N <name> # timeout after 60s`. by @brettdavies in [#414](https://github.com/brettdavies/dotfiles/pull/414)
- Change compound-engineering's reviews to run only in-process on every host: no review is sent to Codex or another external model. by @brettdavies in [#424](https://github.com/brettdavies/dotfiles/pull/424)
- Change the failed systemd user units notice at Claude session start: it shows on screen under the startup banner as well as in Claude's context, and leaves the session-context output. by @brettdavies in [#428](https://github.com/brettdavies/dotfiles/pull/428)
- Change agent-slot's git calls that reach a remote to run ssh's config `Match exec` lines with `/bin/sh` instead of the account's zsh, which saves about 0.37 s per connection. by @brettdavies in [#433](https://github.com/brettdavies/dotfiles/pull/433)
- Change a slot launch to fetch the shared solutions repo while it clones the slot, instead of after.
- Change the new-agent key's tab to read the repo list while it waits for Rex.app to show it, which takes 0.1 to 0.3 s off each key press. by @brettdavies in [#438](https://github.com/brettdavies/dotfiles/pull/438)
- Change the failed-units notice at session start to show each failed unit's own status text beside its name. by @brettdavies in [#439](https://github.com/brettdavies/dotfiles/pull/439)
- Change `agent-slot warm`'s default count from 3 to the per-repo slot limit.
- Change `agent-slot doctor`'s key to ready to report the launch's `deps` phase. by @brettdavies in [#445](https://github.com/brettdavies/dotfiles/pull/445)
- Change `agent-slot check` to report `draft` and `probe` on each of a slot's PRs, and to count a marked probe closed unmerged toward neither finishing the task nor blocking it. by @brettdavies in [#452](https://github.com/brettdavies/dotfiles/pull/452)
- Change a slot on a head someone else owns so nothing from it runs: Claude starts with user settings only, the tree's Claude and tool config stays off disk, git gets no hooks and treats no directory in the tree as a repository, git-crypt stays locked, auto-format stays off, and the files session does not start yazi. by @brettdavies in [#453](https://github.com/brettdavies/dotfiles/pull/453)
- Agent slots may write files meant for Brett to their prime's `.context/` folder; the rest of the prime stays read-only for them. by @brettdavies in [#455](https://github.com/brettdavies/dotfiles/pull/455)
- Change `agent-slot release` to count only `ce-compound mode:refresh` as the closing refresh run. The deprecated `ce-compound-refresh` still passes, through the `ce-compound mode:refresh` call it makes. by @brettdavies in [#456](https://github.com/brettdavies/dotfiles/pull/456)
- Change each agent slot's session context to carry the agent-slot skill's "Inside a slot" rules and closing steps.
- Change the Claude settings to run every model at `xhigh` effort. by @brettdavies in [#458](https://github.com/brettdavies/dotfiles/pull/458)
- Change the Claude settings to deny the `code-review`, `codex`, `review`, and `security-review` skills. by @brettdavies in [#460](https://github.com/brettdavies/dotfiles/pull/460)
- Change the CI-watch guidance to watch only with `gh run watch`, for the runs the session's own action started.
- Change the local test gates to fail when the machine's Bun differs from `.bun-version`, the version CI installs; bump `.bun-version` in its own PR when Homebrew moves Bun. by @brettdavies in [#462](https://github.com/brettdavies/dotfiles/pull/462)
- Change the slot context to name the paths the brief let the PR change and the surface it may add. by @brettdavies in [#464](https://github.com/brettdavies/dotfiles/pull/464)
- Change `agent-slot launch`, `reopen`, and `resume` to start the repo's prime when it is not running. A prime that fails to start never fails the slot. by @brettdavies in [#466](https://github.com/brettdavies/dotfiles/pull/466)
- Change reconcile to keep a tab for every running prime, first in its repo's session, creating the Rex session when there is none. Closing a running prime's tab brings it back within a minute.
- Change the start-up step to replace a restored three-pane prime tab with a fresh one holding the prime, and to clear a session holding only tabs a pass opened, prime tabs included, before rexurrect runs.
- Change `agent-slot launch` to refuse a task ending in `-prime`, since a repo's prime would resume a conversation of that name at its next start.
- Change the next step `tmux-unresponsive` names to `agent-slot list --output json`, since a bare tmux client hangs a caller capturing its output on the server it reports.
- Run the shell-startup perf gate only when a commit or push changes a file that shell startup reads. by @brettdavies in [#469](https://github.com/brettdavies/dotfiles/pull/469)
- Change `scripts/playwright-deps-deploy.sh` to deploy the browser set on a Mac instead of exiting. by @brettdavies in [#470](https://github.com/brettdavies/dotfiles/pull/470)
- Change the system browser set's WebKit to the revision the repos' pinned Playwright names (2311), with no WebKit aliases; a pin carrying `webkit-aliases` is rejected as malformed. by @brettdavies in [#472](https://github.com/brettdavies/dotfiles/pull/472)
- Change the Mac WebKit archive for macOS 26 and later to `webkit-mac-15-arm64.zip`, the build Playwright 1.61.1 downloads there.
- Change Claude Code sessions to read `git-and-github.md` on demand instead of loading all of it on every call. `CLAUDE.md` keeps the hard rules. by @brettdavies in [#474](https://github.com/brettdavies/dotfiles/pull/474)
- Change the session-start hook to print installed tools as one line of command names, leaving out dependency formulas and the bunx cache.
- Change 56 unused skills to list by name only, cutting the skill listing by 14.2k characters on every call. by @brettdavies in [#475](https://github.com/brettdavies/dotfiles/pull/475)
- Change every Claude Code session to compact at a 400k window instead of about 967k. by @brettdavies in [#476](https://github.com/brettdavies/dotfiles/pull/476)
- Change agent slots to start with idle compaction off.
- Change a slot's push guard to deny a branch unrelated to the slot's other branches, so a new task can't start in the old session. by @brettdavies in [#477](https://github.com/brettdavies/dotfiles/pull/477)
- Change `item-held-by-slot` to name `retask` for a new task.
- Change `agent-slot resume --model` to refuse only a busy, waiting, or unreadable agent: it no longer checks the Claude's process tree for running commands or refuses the slot's own agent in every state. by @brettdavies in [#479](https://github.com/brettdavies/dotfiles/pull/479)
- Change the answer of a `resume --model` run by the slot's own agent mid-turn from `own-agent` with `ask-operator` to `busy` with `retry`.
- Start each agent slot's Claude without the `Artifact`, `AskUserQuestion`, `ScheduleWakeup`, and `ReportFindings` tools, with the skills slots rarely or never call and the obsidian and cloudflare plugins off, so the first call of every slot session and its subagents carries less. A slot on a repo with a Cloudflare config keeps the cloudflare plugin. by @brettdavies in [#482](https://github.com/brettdavies/dotfiles/pull/482)
- Change the default LanguageTool server to the `languagetool` Tailscale Service, addressed by the tailnet's full MagicDNS name read at call time. by @brettdavies in [#483](https://github.com/brettdavies/dotfiles/pull/483)
- Count a slot's `ce-code-review` run as `claude -p` from a Bash call toward its review cap, as a `Skill` call already counts. by @brettdavies in [#485](https://github.com/brettdavies/dotfiles/pull/485)
- Let a coordinating prime grant a slot one more review round with `agent-slot grant-review`; a slot's own pane is still refused, and the cap hook denies a slot's own grant command.
- Check a slot's `git push` run under `timeout` with options against the brief's `Touches:`.
- Add the "Code reviews" and "Smallest change" rules and a wait rule to the global CLAUDE.md, and have plans run the reviews they need, one round each.
- Turn off gstack's `/verify` skill in every Claude Code session, slots included, and with it the `/verify` line in the Bash tool description. by @brettdavies in [#491](https://github.com/brettdavies/dotfiles/pull/491)

### Fixed

- Fix the markdown format hook applying the session repo's line width and ignore list to files in other repos. It reads the config that governs the edited file, so a repo that opts out with `MD013.line_length: 9999` is left alone from any session. by @brettdavies in [#306](https://github.com/brettdavies/dotfiles/pull/306)
- Fix the format hook forwarding markdownlint's banner and file-count lines after every markdown edit; a clean file now reports nothing.
- Fix table alignment for cells containing emoji or CJK text, which left MD060 misalignment errors in place after formatting.
- Fix values typed into a slot's shell, which are now shell-quoted, and refuse `--output` before the verb so no flag order skips the ask rules for `sweep` and `finish`. by @brettdavies in [#309](https://github.com/brettdavies/dotfiles/pull/309)
- Fix the new-agent key's repo picker opening behind the current tab: in a session not named after a repo, its tab now comes forward. by @brettdavies in [#310](https://github.com/brettdavies/dotfiles/pull/310)
- Fix sweep tabs piling up in the agent-slots session: each launch reruns the one sweep tab, and `r` in it sweeps again.
- Fix `agent-slot list` printing a `/proc/<pid>/environ` error when a process under a slot exits mid-scan.
- Fix `agent-slot resume` leaving a slot with no agent when its Claude never received a message: such a slot now starts a fresh conversation under its session ID.
- Fix `agent-slot doctor` warning about an untrusted slot path past the per-repo limit when every slot of a repo is taken.
- Fix `rex config check` starting the agent-slots restore against the running Rex server: restore at Rex start now runs only when a Rex server started it. by @brettdavies in [#311](https://github.com/brettdavies/dotfiles/pull/311)
- Fix the git guide's PR-body filename colliding across agent slots: `<repo>` now comes from the origin remote instead of the checkout's directory, which is a number in a slot. by @brettdavies in [#314](https://github.com/brettdavies/dotfiles/pull/314)
- Fix `agent-slot check` reporting a slot as unfinished when its PR merged with `gh pr merge --delete-branch` before any check recorded the PR; the slot's HEAD reflog now supplies the deleted branch's name, so the merged PR counts and a sweep can tear the slot down. by @brettdavies in [#316](https://github.com/brettdavies/dotfiles/pull/316)
- Fix `agent-slot check` reporting `uncommitted-changes` for the `docs/solutions` link that slot setup re-points, which kept every finished dotfiles slot from tearing down. by @brettdavies in [#317](https://github.com/brettdavies/dotfiles/pull/317)
- Fix `agent-slot check` reporting `untracked-files` for ignored build output it can regenerate: Astro, Wrangler, Blume, and SwiftPM caches, ignored files inside a tool directory that also holds tracked files, and ignored byte-for-byte copies of files `HEAD` tracks. by @brettdavies in [#318](https://github.com/brettdavies/dotfiles/pull/318)
- Fix `agent-slot finish --yes` and `agent-slot sweep --yes` keeping a finished slot whose only change is setup pointing a tracked `docs/solutions` link at the shared solutions repo, after `agent-slot check` had reported it could be torn down. by @brettdavies in [#319](https://github.com/brettdavies/dotfiles/pull/319)
- Fix the slot trust step ending up to a second before `AGENT_SLOT_TRUST_TIMEOUT` and resending a Down the trust dialog missed after as little as half a second; it now times both to the microsecond. by @brettdavies in [#321](https://github.com/brettdavies/dotfiles/pull/321)
- Fix `agent-slot check` run from inside a slot reporting a false agent-state-unknown; the check no longer counts its own `/proc` scan as a process outside the slot's panes. by @brettdavies in [#322](https://github.com/brettdavies/dotfiles/pull/322)
- Fix `agent-slot sweep --yes` and `agent-slot finish --yes` recording a kept slot's `stash-present` blocker without the `count` field that `agent-slot check` reports for the same stash. by @brettdavies in [#324](https://github.com/brettdavies/dotfiles/pull/324)
- Fix slot agents chasing teardown blockers they cannot clear: the SessionStart context now ends an agent's job at a finished task, tells it to report and stop, and leaves teardown to the operator's sweep or finish instead of pointing it at `agent-slot check`. by @brettdavies in [#325](https://github.com/brettdavies/dotfiles/pull/325)
- Fix the Mac helper opening a second or third tab for one slot when restores, sweeps, and finishes ran at once: each now waits for the one ahead of it, and a pane that starts during a snapshot counts as running. by @brettdavies in [#326](https://github.com/brettdavies/dotfiles/pull/326)
- Fix `agent-slot check`, `sweep`, and `finish` keeping a finished slot for `.claude/scheduled_tasks.lock` or `.claude/scheduled_tasks.json`, the files Claude Code writes when an agent uses scheduled tasks. Any other file under a slot's `.claude/` still keeps the slot. by @brettdavies in [#327](https://github.com/brettdavies/dotfiles/pull/327)
- Fix `agent-slot check` run by a slot's own agent reporting `agent-not-idle`: it now reports `checked-by-own-agent`, with a message and `next_step` saying teardown happens from outside, when the operator runs sweep or finish. by @brettdavies in [#328](https://github.com/brettdavies/dotfiles/pull/328)
- Fix the slot SessionStart context printing nothing when a context line contains an apostrophe.
- Fix `git push` with its output piped (for example `git push 2>&1 | tail`) failing in the pre-push hook with `cat: write error: Resource temporarily unavailable` when every check had passed. by @brettdavies in [#329](https://github.com/brettdavies/dotfiles/pull/329)
- Fix slot agents keeping a watcher on a slot they launched, which held the parent slot busy until the child finished: the SessionStart context now says a launched slot is independent and gets no watchdog or watcher, while an agent's own PRs and CI are still watched to the end. by @brettdavies in [#330](https://github.com/brettdavies/dotfiles/pull/330)
- Fix `agent-slot-rex` restore, sweep, and finish failing on every pass, and closing no tabs, while any slot's needs-you message made its tab label longer than Rex's 128-character limit. A long label is cut at the end of its needs-you message and ends in `…`, keeping the key and task in front. by @brettdavies in [#332](https://github.com/brettdavies/dotfiles/pull/332)
- Fix a failed `rex` call reporting Rex's `--help` pointer instead of the `Error:` line that says why it failed.
- Fix tools hanging on large writes into pipes on Linux hosts with many open processes: `config/sysctl.d/60-pipe-user-pages.conf` turns off `fs.pipe-user-pages-soft`, so new pipes keep the 64 KiB default instead of dropping to 8 KiB once the user holds more than about 1,000 pipes. by @brettdavies in [#335](https://github.com/brettdavies/dotfiles/pull/335)
- Fix a check run inside a slot's own agent putting `checked-by-own-agent` on the slot's needs-you list and its Rex tab, where it stayed until a check from outside replaced it. by @brettdavies in [#336](https://github.com/brettdavies/dotfiles/pull/336)
- Fix Linux shells on a headless-Obsidian host exporting `DISPLAY=:99` and `XAUTHORITY`, which let any GUI program started from a shell, such as an Electron app run by a version probe, open invisible windows on the Obsidian Xvfb display and keep running instead of failing. Only `obsidian.service` gets the display; the `obsidian` CLI keeps working without it. by @brettdavies in [#337](https://github.com/brettdavies/dotfiles/pull/337)
- fix(hooks): catch a core variable the core-env guard missed after env's options by @brettdavies in [#340](https://github.com/brettdavies/dotfiles/pull/340)
- Fix `agent-slot check` treating gstack's `.gstack/` state and Playwright's `test-results` output, including under an ignored `.context/`, as work that blocks teardown. by @brettdavies in [#343](https://github.com/brettdavies/dotfiles/pull/343)
- Fix `agent-slot check` treating the Vale style packages a slot's `.vale.ini` names, which `vale sync` downloads into `StylesPath`, as untracked work that blocks teardown. by @brettdavies in [#345](https://github.com/brettdavies/dotfiles/pull/345)
- Fix `agent-slot check` reporting a different short-lived PID on every run when a process outside the slot's panes holds the slot. It now names the long-lived process with its command, in the message and in the blocker's `values`. by @brettdavies in [#346](https://github.com/brettdavies/dotfiles/pull/346)
- Fix the agent-slot test suites leaving processes running after a run, which kept a slot whose agent ran them from being torn down.
- Fix `agent-slot check` sometimes reporting `agent-state-unknown` for a short-lived command that one of the slot's own panes ran in the slot.
- Fix `agent-slot check` passing a slot while a job started from one of the slot's panes, and left running after its command ended, still used the slot. Only powerlevel10k's `gitstatusd` now counts as a pane's own by its environment. by @brettdavies in [#347](https://github.com/brettdavies/dotfiles/pull/347)
- Fix two test suites leaving processes running after a run, and fail any test suite that leaves one running once its bats process exits.
- Fix `agent-slot release` accepting a ce-compound or ce-compound-refresh Skill call that failed, such as one answered "Unknown skill", as a run of that skill. by @brettdavies in [#350](https://github.com/brettdavies/dotfiles/pull/350)
- Fix `agent-slot check` naming, beside the process that holds a slot, a short-lived child of it that exited before check could trace it, which put an extra bare pid in the `agent-state-unknown` message and values when the host was busy. by @brettdavies in [#352](https://github.com/brettdavies/dotfiles/pull/352)
- Fix `sd-commit-doc` leaving the shared solutions clone modified and behind origin when one call commits a new doc together with an edited one. A failure to reconcile the clone after the push now exits non-zero and says the push already landed, instead of passing silently. by @brettdavies in [#353](https://github.com/brettdavies/dotfiles/pull/353)
- Fix `sd-commit-doc` failing after its fetch and worktree setup when the message file is given by a path relative to the current directory. by @brettdavies in [#355](https://github.com/brettdavies/dotfiles/pull/355)
- Fix `agent-slot launch` failing with `clone-failed` (`pack has N unresolved deltas`) when the repo's prime checkout is a partial clone: the slot is now cloned with the prime's own partial-clone filter. by @brettdavies in [#357](https://github.com/brettdavies/dotfiles/pull/357)
- Fix a failed base-branch checkout during `agent-slot launch` reporting `script-error` with git's output mixed into the JSON error stream; it now reports `clone-failed` with a log, under the same timeout as the clone.
- Fix the solutions-clone autosync hook so it reverts only copies whose content already matches origin. It no longer deletes an untracked in-flight doc that shares a path with a newly pushed one, and it reports a revert that git refuses as a non-blocking hook error instead of dropping it. by @brettdavies in [#358](https://github.com/brettdavies/dotfiles/pull/358)
- Fix `agent-slot check` reporting commits pushed to a fork as unpushed: a branch's upstream or push remote on origin's host now counts, and a fork that can't be fetched blocks with `git-state-unknown`. by @brettdavies in [#360](https://github.com/brettdavies/dotfiles/pull/360)
- Fix a slot launched on an existing PR, such as a review round, seeing no PR: check now adopts an older PR whose head commit one of the slot's branches holds beyond the base.
- Fix agent-slot teardown leaving every deleted slot's clone in the trash, where it kept its disk space: teardown now purges the clone's own trash entry as soon as it is trashed, and reports a purge that fails with the `trash-rm` command that finishes it. by @brettdavies in [#361](https://github.com/brettdavies/dotfiles/pull/361)
- Fix `~/.local/bin` wrappers, including the `gh` merge guard, losing to Homebrew binaries in shells that inherit `~/.local/bin` (tmux panes, agent slots, the shells and Claude Code sessions they start) and in macOS login zsh after `path_helper`. by @brettdavies in [#363](https://github.com/brettdavies/dotfiles/pull/363)
- Fix `~/.npm-global/bin` and `~/.bun/bin` losing to Homebrew in shells that inherit them.
- Fix `agent-slot release --not-yet` after a `release`: it withdraws the release and the teardown that release started, so the automatic sweep keeps the slot as not-yet instead of tearing it down. by @brettdavies in [#364](https://github.com/brettdavies/dotfiles/pull/364)
- Fix the finish a release starts recording the task as operator-finished; it marks the release instead, and `agent-slot check` reports `finished_by: "release"`.
- Fix the Claude Code guards allowing every call on a host without jaq: each guard now falls back to jq, and with neither it blocks the calls it checks with a reason that ends in `brew install jaq`. by @brettdavies in [#371](https://github.com/brettdavies/dotfiles/pull/371)
- Fix a guard that crashes, times out, or is missing letting the call through: the guard entries in `settings.json` now block on failure, and a crash inside a guard names the guard and the line.
- Fix `defuddle-webfetch.sh` failing on a Mac without `sha256sum`.
- Fix `agent-slot release` refusing a reopened slot with `compound-not-run` after both closing skills ran. Claude Code keeps writing a resumed conversation to its transcript under the old slot's project directory, so a recorded transcript path that does not exist now resolves to the session's real transcript, found by session ID, in the slot record, the release gate, and the `release` and `teardown` ledger events. by @brettdavies in [#373](https://github.com/brettdavies/dotfiles/pull/373)
- Fix a `git pull` that adds a Claude Code hook script leaving `~/.claude/settings.json` naming a script with no link yet, which blocked every tool call on the host until a manual restow: `post-merge` and `post-checkout` now relink the `claude` and `secrets` packages when an update changes them, from the deployed checkout only. by @brettdavies in [#374](https://github.com/brettdavies/dotfiles/pull/374)
- Fix the Claude Code auto-format hook re-sorting `use` lists in edition-2024 Rust crates that have no `rustfmt.toml`: it formats each `.rs` file with its package's edition from `Cargo.toml`, as `cargo fmt` does, including `edition.workspace = true` members. by @brettdavies in [#377](https://github.com/brettdavies/dotfiles/pull/377)
- Fix the never-send guard allowing calls on macOS when `~/.claude.json` exists but is not a regular file; it now blocks them, as it does on Linux. by @brettdavies in [#379](https://github.com/brettdavies/dotfiles/pull/379)
- Fix the slot-context, slot-status, and solutions-clone-autosync Claude hooks printing `realpath: illegal option -- m` on macOS. by @brettdavies in [#380](https://github.com/brettdavies/dotfiles/pull/380)
- Fix the global PR template so prettier leaves it unchanged: a blank line now follows the version stamp on line 1. by @brettdavies in [#383](https://github.com/brettdavies/dotfiles/pull/383)
- Fix `agent-slot-rex`'s follow loop missing a sleep of the Mac that happened while it was checking the Rex server, which skipped the reconnect restore after that wake. by @brettdavies in [#385](https://github.com/brettdavies/dotfiles/pull/385)
- Fix `scripts/run-tests` exiting 0 without running anything when an option such as `--shard` comes before the mode; it now exits 2.
- Fix `stow-deploy` deploying the `gh` and `codex` packages' encrypted files as ciphertext from a git-crypt-locked checkout; it now refuses any package `.gitattributes` encrypts while the checkout is locked, and names the locked file. by @brettdavies in [#388](https://github.com/brettdavies/dotfiles/pull/388)
- Fix piped-commit-guard so it also denies `sd-commit-doc` and the `gh pr`, `gh issue`, and `gh release` body/notes-file submissions when their output is piped and a later step deletes the message file. by @brettdavies in [#391](https://github.com/brettdavies/dotfiles/pull/391)
- Fix `ledger_append` ending its caller's shell when the ledger lock file can't be opened; it now returns 1. by @brettdavies in [#395](https://github.com/brettdavies/dotfiles/pull/395)
- Fix agent-slot's slot and repo locks ending their caller's shell when the lock file can't be opened. A slot's SessionStart now still prints its context and logs the lock it could not take. by @brettdavies in [#396](https://github.com/brettdavies/dotfiles/pull/396)
- Fix yazi's git status column failing on every directory under yazi 26.9 and piling up failed `Run fetcher 'git'` tasks, by pinning git.yazi, piper.yazi, and smart-enter.yazi to revisions built for the current fetcher API. by @brettdavies in [#399](https://github.com/brettdavies/dotfiles/pull/399)
- Fix every repo's Rex session appearing twice after `rex-server.service` restarts while a reconcile pass runs: a pass now stops at the first sign that the server instance it planned against has gone, logging `rex-server-restarted` (or `rex-server-down`) under `skipped`, and the start-up step kills sessions that hold only slot tabs before rexurrect restores. by @brettdavies in [#406](https://github.com/brettdavies/dotfiles/pull/406)
- Fix the yazi plugin install in `scripts/stow-deploy` and the daily brew job, which left every host that already had plugins at its old pins after a pin bump; both now run `ya pkg install --discard`, and the rerun commands they print match. by @brettdavies in [#407](https://github.com/brettdavies/dotfiles/pull/407)
- Fix a hung bats test blocking `scripts/run-tests`, pre-commit, pre-push, and CI: every test now fails once it runs past `BATS_TEST_TIMEOUT` seconds (180 unless the environment sets it), naming the test. by @brettdavies in [#411](https://github.com/brettdavies/dotfiles/pull/411)
- Fix the new-agent key in a session with no tabs opening its tab, and launching a slot, in another session Rex.app had focused earlier: a key-opened tab now waits to be shown, and one never shown starts nothing and closes itself. by @brettdavies in [#413](https://github.com/brettdavies/dotfiles/pull/413)
- Fix the vault agent-workspace sync to the NAS, which failed on every run on the Linux server after the `rex` package added a file to `/etc/ssh/ssh_config.d/`. by @brettdavies in [#415](https://github.com/brettdavies/dotfiles/pull/415)
- Fix the nightly autocommit job's fetch and push for solutions-docs and agent-skills, which failed on the same ssh error while the job still reported success.
- Fix the GitHub stars sync and the uv tool upgrade so ssh still works if either job falls back to git over ssh.
- Fix the AppArmor denial flood and one-uid user namespace that `PrivateTmp=true` caused in eleven systemd user units on Linux; the units keep `NoNewPrivileges=true` and set no namespace directive. by @brettdavies in [#417](https://github.com/brettdavies/dotfiles/pull/417)
- Fix the vault mirror's stall alert, which depended on the decommissioned OpenClaw CLI. The check fails its unit and logs to the journal at err priority instead. by @brettdavies in [#420](https://github.com/brettdavies/dotfiles/pull/420)
- Fix prime tabs coming back detached after a Rex server restart: the start-up step now runs `agent-slot-rex prime <repo>` in each restored prime tab that sits at an idle shell prompt, so the new-agent key no longer opens a second prime beside it. by @brettdavies in [#421](https://github.com/brettdavies/dotfiles/pull/421)
- Fix the brew upgrade job's stale-process scan, which skipped itself on every systemd run because it probed the user manager, whose executable no unit can read. Services still running a removed Homebrew binary are restarted again. by @brettdavies in [#422](https://github.com/brettdavies/dotfiles/pull/422)
- Fix nightly-autocommit skipping a repo whose `.git` is a file pointing at a separate git directory. by @brettdavies in [#423](https://github.com/brettdavies/dotfiles/pull/423)
- Fix `scripts/run-tests` failing a run under host load because bats 1.14 left a test's timeout watchdog `sleep` running after the run ended. The run-level scan stops that sleep without failing the run. by @brettdavies in [#426](https://github.com/brettdavies/dotfiles/pull/426)
- Fix the nightly autocommit starting `claude -p` in `$HOME` with debug logging on: claude runs from inside the repo it commits in, with no debug flag. by @brettdavies in [#427](https://github.com/brettdavies/dotfiles/pull/427)
- Fix `scripts/run-tests` letting a leaked `sleep` of exactly the test time limit pass when its descriptors matched bats's own watchdog: the run-level scan stops only the watchdog, recognised by its environment, and fails every other leftover process. by @brettdavies in [#429](https://github.com/brettdavies/dotfiles/pull/429)
- Fix another tool's `playwright install` deleting the dotfiles-provisioned Playwright browsers: `scripts/playwright-browsers-deploy.sh` now registers its browser set and chromium aliases in the cache's `.links`, which Playwright's install-time cleanup honors. by @brettdavies in [#431](https://github.com/brettdavies/dotfiles/pull/431)
- Fix the new-agent key's launch request time, which lost up to a second to whole-second truncation. by @brettdavies in [#432](https://github.com/brettdavies/dotfiles/pull/432)
- Fix `agent-slot doctor` reporting the prune and sweep timers as not enabled when run from a shell in a slot. by @brettdavies in [#434](https://github.com/brettdavies/dotfiles/pull/434)
- Fix the SSH config's Match exec tests reading the whole shell profile, which added about 0.25 to 0.5 s to every ssh and every git operation over ssh on both macOS and Linux. by @brettdavies in [#435](https://github.com/brettdavies/dotfiles/pull/435)
- Fix the new-agent key's tab asking "press Enter to go on" although Rex.app showed it: the tab now counts as shown once the app asks a size for its terminal, rather than once the session's active window moves, and it waits up to 10 s (`AGENT_SLOT_REX_SHOWN_WAIT`) instead of 5 s. by @brettdavies in [#436](https://github.com/brettdavies/dotfiles/pull/436)
- Fix `--from-dev-prs` reading `dev`'s whole history when the previous release has no backport commit on `dev`: the window now opens at the newest `dev` commit at or before the previous tag's commit time. by @brettdavies in [#442](https://github.com/brettdavies/dotfiles/pull/442)
- Fix the `gh` wrapper's merge guard reading the wrong repository's PR for `gh pr merge N -R owner/repo`, which let a merge into `main` through when the working directory's PR N targeted another branch. by @brettdavies in [#444](https://github.com/brettdavies/dotfiles/pull/444)
- Fix the merge guard letting a merge through when `-R` came before the PR number, when a flag's value preceded the PR number, when `-R` came before `merge`, and whenever the base lookup failed. It now refuses a merge whose base it cannot determine.
- Finish a released task with no PR once its agent is idle, so a release whose detached finish died no longer leaves the slot held and unlisted. by @brettdavies in [#447](https://github.com/brettdavies/dotfiles/pull/447)
- Remind an agent on a task with no PR about its `release --not-yet`, as the command promises.
- Purge a failed launch's clone from the trash, so an unlocked clone of a git-crypt repo does not stay there in plaintext.
- Copy hooks installed in the git directory of a prime whose `.git` is a file; they were skipped silently.
- Include `--dangerously-skip-permissions` in the commands `agent-slot warm` tells you to run to trust a prime.
- Name `AGENT_SLOT_EXTRA_PRIMES` in `repo-not-found`, and say that a repo goes by its directory's name.
- Remove a Codex trust entry for a deleted repository. by @brettdavies in [#448](https://github.com/brettdavies/dotfiles/pull/448)
- Fix the brew upgrade job reporting a stale service as restarted when it died right after the restart; a restart now counts only if the unit is still active 3 s later on the same invocation. by @brettdavies in [#450](https://github.com/brettdavies/dotfiles/pull/450)
- Fix the brew upgrade job restarting a transient `systemd-run` service, which reran its command; it is now left running and reported.
- Fix `run.end` reporting zero errors and warnings for a killed upgrade run, and remove the temp files such a run left behind.
- Remove the `ingest-lab` prime, whose repository and checkout no longer exist. by @brettdavies in [#451](https://github.com/brettdavies/dotfiles/pull/451)
- Fix the `agent-slot launch`, `adopt`, and `reopen` help examples, which named repositories that no longer exist.
- Fix the session-context hook running tools in the session's working directory, where a tree's `bunfig.toml` could run code as the account at session start. by @brettdavies in [#453](https://github.com/brettdavies/dotfiles/pull/453)
- Fix slot setup writing through a link the head tracks, which could overwrite `~/.claude/settings.json`. Setup now replaces a `settings.local.json` link and refuses a `.claude`, `docs`, or `.context` link out of the slot with `tracked-link-leaves-slot`.
- Fix slot setup firing a tracked `post-index-change` hook through its own `update-index` once the hooks path was set.
- Fix `agent-slot launch` dropping a brief when another request's slot already held the task or work item; it now refuses with `item-held-by-slot`. by @brettdavies in [#457](https://github.com/brettdavies/dotfiles/pull/457)
- Fix the `gh` wrapper's PR freeze so a repo flag before or between the words of `pr create`, or written as `-R=owner/repo`, no longer gets a pull request past a frozen repository. by @brettdavies in [#468](https://github.com/brettdavies/dotfiles/pull/468)
- Fix the AI-attribution guard skipping `gh -R owner/repo pr create` and `gh --repo owner/repo pr create`, so a trailer in those calls is now denied.
- Time the checkout's shell startup files in the perf gate instead of the config installed under `$HOME`. by @brettdavies in [#469](https://github.com/brettdavies/dotfiles/pull/469)
- Fix agentnative-site's WebKit projects (`mobile-ios`, `tablet`) failing at `newPage` with `Emulation.setAuthCredentials` against the shared browser set. by @brettdavies in [#472](https://github.com/brettdavies/dotfiles/pull/472)
- Fix a slot started with neither a name nor a task running an untitled Claude session; it is named `<repo>-<N>`. by @brettdavies in [#481](https://github.com/brettdavies/dotfiles/pull/481)
- Fix the prose-check LanguageTool stage being refused on the Linux server and skipping grammar checks. by @brettdavies in [#483](https://github.com/brettdavies/dotfiles/pull/483)
- Fix an unreachable LanguageTool passing as a clean check: the notice is a multi-line `WARNING:` that says what did not run and how to diagnose and override it, and no longer blames a downed service for a refused connection.
- Fix `lt_check` exiting 0 with no output when a server passes the probe and then fails the check requests.
- Fix the slot scope guard denying a command that only mentions `git push` inside a quoted string, such as an `rg` pattern, with the retask message. by @brettdavies in [#484](https://github.com/brettdavies/dotfiles/pull/484)
- Fix the slot scope guard denying a slot's push as a second task because the clone still holds a local copy of origin's default branch. by @brettdavies in [#486](https://github.com/brettdavies/dotfiles/pull/486)
- Fix the slot scope guard denying a push from the lower branch of a stack after that branch is rebased onto, or merged with, a base that moved, including its later pushes. A lower branch that was reset, amended, or squashed stays a second task. by @brettdavies in [#487](https://github.com/brettdavies/dotfiles/pull/487)
- Fix the slot scope guard refusing the push of an upper branch after its stack's lower branch was squash-merged into the base and the upper branch was replayed onto the squash commit, while the slot still holds the lower branch. A branch that carries work the base lacks, and a new task cut from the base after the merge, stay a second task. by @brettdavies in [#488](https://github.com/brettdavies/dotfiles/pull/488)
- Fix the slot scope guard letting a branch that was reset to the base, or rebuilt on it with `git checkout -B`, push beside a squash-merged branch; the push is denied with the retask message. by @brettdavies in [#489](https://github.com/brettdavies/dotfiles/pull/489)

### Documentation

- Document how the format hook chooses its line width and ignore list, and the 9999 opt-out, in the global CLAUDE.md and the cli-tools guide. by @brettdavies in [#306](https://github.com/brettdavies/dotfiles/pull/306)
- Add a stacked-PR workflow to the global git guide: one atomic merge for a whole stack, rollup-based CI verification, sequential-merge recovery, and the `merge-async` fallback. by @brettdavies in [#307](https://github.com/brettdavies/dotfiles/pull/307)
- Clarify that `gh pr checks --watch`'s exit code is not a CI verdict; the status rollup decides.
- Document parallel agents in README (setup, keys, tab labels, every reason and teardown blocker), BOOTSTRAP, and CONCEPTS. by @brettdavies in [#308](https://github.com/brettdavies/dotfiles/pull/308)
- Document how tabs follow the server, its configuration, and its logs in the README's agent slot section. by @brettdavies in [#334](https://github.com/brettdavies/dotfiles/pull/334)
- Document release, the automatic sweep, and the teardown log in the README and `CONCEPTS.md`. by @brettdavies in [#336](https://github.com/brettdavies/dotfiles/pull/336)
- Document installing the `rex` package on the preview channel and connecting Rex for Mac to the server, in BOOTSTRAP.md § Rex login server. by @brettdavies in [#348](https://github.com/brettdavies/dotfiles/pull/348)
- Fix the `gh pr checks --watch` exit codes in the git-and-github guide: it exits 1 only when a check fails and 0 when the rest pass, skip, or are cancelled (cancelled exits 1 before gh 2.36.0), and it counts only the checks registered when it polls. by @brettdavies in [#354](https://github.com/brettdavies/dotfiles/pull/354)
- State in `CLAUDE.md` and the git-and-github guide that a commit's message file is deleted only on the commit's own status, never behind a pipe. by @brettdavies in [#356](https://github.com/brettdavies/dotfiles/pull/356)
- Describe an agent slot as a clone that takes its prime's partial-clone filter, rather than always a full clone. by @brettdavies in [#357](https://github.com/brettdavies/dotfiles/pull/357)
- Correct the git-and-github guide on how `gh pr checks` deduplicates checks: by check-run name, workflow, and event, keeping the most recently started. by @brettdavies in [#358](https://github.com/brettdavies/dotfiles/pull/358)
- docs(agent-slot): say that trash-cli logs an entry's name at -vv by @brettdavies in [#362](https://github.com/brettdavies/dotfiles/pull/362)
- Document in AGENTS.md that a PATH directory whose binaries shadow Homebrew or system binaries moves to the front at startup. by @brettdavies in [#363](https://github.com/brettdavies/dotfiles/pull/363)
- Document in `CONCEPTS.md` that a deliberate wrapper is the one sanctioned second copy of a command, and that it works only while its directory precedes the copy it wraps. by @brettdavies in [#366](https://github.com/brettdavies/dotfiles/pull/366)
- State in `CLAUDE.md` how the rule against sending the account address to an outside service is enforced. by @brettdavies in [#368](https://github.com/brettdavies/dotfiles/pull/368)
- Document in AGENTS.md that a top-level non-login, non-interactive `bash -c` reads `.bashrc` when its stdin is a socket or `SSH_CLIENT` is set, and that a heredoc command in the agent Bash tool hands it a socket. by @brettdavies in [#370](https://github.com/brettdavies/dotfiles/pull/370)
- Document restow on pull, its failure report and manual recovery, and `stow-deploy --only` in `AGENTS.md`, `README.md`, and `CONCEPTS.md`. by @brettdavies in [#374](https://github.com/brettdavies/dotfiles/pull/374)
- Document the slot worktree, the shared clone, the publish flow, and the stray report in the global agent rules, the workflows guide, `CONCEPTS.md`, and the README. by @brettdavies in [#375](https://github.com/brettdavies/dotfiles/pull/375)
- Document the repo's CalVer version scheme in RELEASES.md: releases are tagged `YYYY.MM.DD[.N]` with no `v`, and the changelog headings organize the notes without setting a version. by @brettdavies in [#383](https://github.com/brettdavies/dotfiles/pull/383)
- Document the Hex package in BOOTSTRAP.md, including quitting Hex before the first deploy so its in-memory settings don't overwrite the linked file. by @brettdavies in [#384](https://github.com/brettdavies/dotfiles/pull/384)
- Fix BOOTSTRAP.md's Hex section splitting the Rex config and agent slots section. by @brettdavies in [#386](https://github.com/brettdavies/dotfiles/pull/386)
- Change the git-and-github guide's Enforcement paragraph to list every submission the guard reads. by @brettdavies in [#391](https://github.com/brettdavies/dotfiles/pull/391)
- docs(concepts): define a concurrent suite by @brettdavies in [#392](https://github.com/brettdavies/dotfiles/pull/392)
- Document agent slots on the Linux server's Rex server: setup for each machine with doctor as the checklist, what to check when a slot's tab is missing, the phone's shell fallback, and slot agents' reach into every tab on that server. by @brettdavies in [#401](https://github.com/brettdavies/dotfiles/pull/401)
- Document the daily `ya pkg install` and the pin bump's outcomes, reasons, query, and manual rerun in `BOOTSTRAP.md` under "yazi plugin pins". by @brettdavies in [#404](https://github.com/brettdavies/dotfiles/pull/404)
- Document in `CONCEPTS.md` that the supply-chain age gate also covers commit-pinned dependencies, measured by when the hosting service recorded the commit on its branch rather than by the commit's own dates. by @brettdavies in [#405](https://github.com/brettdavies/dotfiles/pull/405)
- Point the git-and-github guide's attribution and heredoc guard notes at the command that runs each suite instead of a case count. by @brettdavies in [#409](https://github.com/brettdavies/dotfiles/pull/409)
- Document in `CONCEPTS.md` what a slot reconcile pass does when the Rex server restarts partway through it, and what the start-up step clears before rexurrect restores. by @brettdavies in [#410](https://github.com/brettdavies/dotfiles/pull/410)
- Explain in `CONCEPTS.md` that a unit's enable link points into the `stow/` tree without being stow's, and must be removed by disabling the unit before its file leaves the package. by @brettdavies in [#412](https://github.com/brettdavies/dotfiles/pull/412)
- Define the leak guard in `CONCEPTS.md`. by @brettdavies in [#416](https://github.com/brettdavies/dotfiles/pull/416)
- Fix the README, BOOTSTRAP, and LaunchAgent comments that placed the qmd systemd user units in the `qmd` package; they ship in `local`. by @brettdavies in [#418](https://github.com/brettdavies/dotfiles/pull/418)
- Document that `systemctl disable` and `reenable` remove a unit's stow-managed link, and that plain `enable` repoints an enable link. by @brettdavies in [#419](https://github.com/brettdavies/dotfiles/pull/419)
- Define the canonical browser set in `CONCEPTS.md`: what it is, how tools reach it, and why it is not the browser for untrusted pages. by @brettdavies in [#441](https://github.com/brettdavies/dotfiles/pull/441)
- Fix the release runbook's backport example, which passed `--only CHANGELOG.md` and failed with exit 64; `CHANGELOG.md` always comes from `main`, and `--only` names only the paths the dry run lists. by @brettdavies in [#442](https://github.com/brettdavies/dotfiles/pull/442)
- Fix the release runbooks' description of the drift gate's anchor: it is the newer of the newest CalVer tag and the newest `release:` commit on `main`.
- Fix the release runbooks' description of where the `--from-dev-prs` changelog window opens: at the previous release's backport commit on `dev`, or, with no backport, at the newest `dev` commit before the previous tag's time.
- Fix the release runbook's drift troubleshooting entry, which named a stale `origin/main` as a cause of an older anchor.
- Document that the backport dry run needs a clean tree and switches the checkout to `dev`.
- Document that a stacked PR in a repo whose workflows filter on base branch runs none of them until `gh stack link`, and that an empty rollup reading `CLEAN` means nothing ran. by @brettdavies in [#449](https://github.com/brettdavies/dotfiles/pull/449)
- Change the README's `agent-slot reopen` walkthrough to an illustrative repository in place of deleted forks. by @brettdavies in [#451](https://github.com/brettdavies/dotfiles/pull/451)
- Add a global rule that files meant for Brett to read go in the prime repo's `.context/` folder, never `/tmp` or a scratchpad. by @brettdavies in [#455](https://github.com/brettdavies/dotfiles/pull/455)
- Add a "Primes" reference to the README with the steps to move a running prime to the slot shape, restart its Claude, stop it, and start a slot without opening it first. by @brettdavies in [#466](https://github.com/brettdavies/dotfiles/pull/466)
- Document the `agent-busy` values `retask` emits: `own-agent` and one `<pid> <command>` line per running command. by @brettdavies in [#479](https://github.com/brettdavies/dotfiles/pull/479)
- Add `docs/runbooks/openseo.md`: tailnet policy, first deploy, first read-only run, Search Console, troubleshooting. by @brettdavies in [#480](https://github.com/brettdavies/dotfiles/pull/480)
- Document how `languagetool.sh` picks its server, where the Tailscale CLI may live, and what exit 2 means. by @brettdavies in [#483](https://github.com/brettdavies/dotfiles/pull/483)

### Removed

- Remove `AGENT_SLOT_REX_CLIENTS` and `AGENT_SLOT_PUSH_CONNECT_TIMEOUT`, and replace `agent-slot-rex restore --wait-server` with `--at-start`. by @brettdavies in [#397](https://github.com/brettdavies/dotfiles/pull/397)
- Remove `agent-slot-rex follow`, `agent-slot-rex restore --by reconnect`, and the follow loop's `AGENT_SLOT_REX_POLL_INTERVAL`, `AGENT_SLOT_REX_TICK`, and `AGENT_SLOT_REX_WAKE_GAP` settings; the reconcile timer and the Rex start-up step on the Linux server replace them. by @brettdavies in [#401](https://github.com/brettdavies/dotfiles/pull/401)
- Remove the OpenClaw settings backup (`backup-openclaw-settings` and its daily systemd timer) from the `local` package; OpenClaw is decommissioned. The Linux server needs the host-side steps in this PR to retire the timer it already has enabled. by @brettdavies in [#408](https://github.com/brettdavies/dotfiles/pull/408)
- Remove `~/.npm-global/bin` from the vault sync check's PATH. by @brettdavies in [#420](https://github.com/brettdavies/dotfiles/pull/420)
- Remove the Obsidian vault from the nightly autocommit. The job covers `~/dev/solutions-docs` (sync only) and `~/dev/agent-skills`, and never commits or pushes the vault. by @brettdavies in [#425](https://github.com/brettdavies/dotfiles/pull/425)

**Full Changelog**: [2026.10.25...2026.11.09](https://github.com/brettdavies/dotfiles/compare/2026.10.25...2026.11.09)

## [2026.10.25] - 2026-10-25

### Added

- Add `--include-contested` to `sync-dev-after-release.sh` for adopting paths both branches changed, and `--dry-run` to print the classification without creating a branch, commit, or PR. by @brettdavies in [#227](https://github.com/brettdavies/dotfiles/pull/227)
- Add `ai-attribution-guard.sh`, a PreToolUse hook that rejects AI-attribution trailers in `git commit` messages and `gh pr`, `gh issue`, and `gh release` bodies, including bodies passed by file. by @brettdavies in [#233](https://github.com/brettdavies/dotfiles/pull/233)
- Add unattended Claude account rotation on both platforms, checking every minute and switching at 99% of the active account's 5-hour or 7-day window: a `cswap` stow package with a systemd timer on Linux, and a `com.user.cswap-auto.plist` LaunchAgent on macOS. by @brettdavies in [#234](https://github.com/brettdavies/dotfiles/pull/234)
- Add `scripts/cswap-autoswitch-deploy.sh`, which pins the trip point, anti-flap margin, and API-key-account exclusion, holds the per-model trigger unset, and is safe to re-run.
- Document cswap installation, account transfer, and per-platform enablement in the bootstrap guide, including the warning that a `cswap export` file holds plaintext credentials.
- `taildrive-mount` takes share names (`taildrive-mount vault`) and mounts only those, instead of every configured share. by @brettdavies in [#240](https://github.com/brettdavies/dotfiles/pull/240)
- A `Vault` tmuxinator session on macOS, rooted at the Taildrive share and mounting it on start.
- Add `mac-open` and `mac-open-here`: open a file from yazi on a Linux host on the Mac the session is driven from, in VS Code through Remote-SSH for text and in the Mac's default app for everything else (in place on a Taildrive share, or from a copy in `~/Downloads/mac-open`). by @brettdavies in [#241](https://github.com/brettdavies/dotfiles/pull/241)
- The local gates and the ShellCheck CI job fail a test that resets `HOME`, `TMPDIR`, an `XDG_*` directory, a tool home, or the whole value of `PATH`. `scripts/core-env-allowlist.tsv` lists the current exceptions with their reasons. by @brettdavies in [#242](https://github.com/brettdavies/dotfiles/pull/242)
- Add `tailscale-serve-setup.service` and `scripts/tailscale-serve-deploy.sh`: the Tailscale Serve bindings are re-applied automatically at boot and whenever tailscaled restarts or upgrades. by @brettdavies in [#245](https://github.com/brettdavies/dotfiles/pull/245)
- Add a PR freeze to the `gh` wrapper: `gh pr create`, `gh stack submit`/`link`, and PR-creating `gh api` calls are refused for any repository listed in `~/.config/gh/pr-freeze.txt`, including unqualified calls from a checkout with a remote pointing at a frozen repo. by @brettdavies in [#250](https://github.com/brettdavies/dotfiles/pull/250)
- Add `gtime`, which runs GNU time the same way on macOS and Linux, and `gnu-time` to the Brewfile. by @brettdavies in [#251](https://github.com/brettdavies/dotfiles/pull/251)
- Add a canonical `.editorconfig` to the claude package, stowed to `~/.editorconfig`, so a bare `shfmt -w <file>` formats shell scripts with 2-space indent, indented case bodies, and binary operators at line start. by @brettdavies in [#253](https://github.com/brettdavies/dotfiles/pull/253)
- Add the canonical `.gitattributes` block at `~/.claude/templates/gitattributes`, the copy source for every repository's `.gitattributes`: LF for text on every platform regardless of `core.autocrlf`, committed bytes kept for iCalendar, email and test-data files, and PDFs always binary. by @brettdavies in [#254](https://github.com/brettdavies/dotfiles/pull/254)
- Add a global Claude rule that keeps each repo's Bun pin on the machine's Bun: a trailing `.bun-version` is bumped in its own PR, and agents never download or install an older Bun to satisfy a stale pin. by @brettdavies in [#255](https://github.com/brettdavies/dotfiles/pull/255)
- Add `cargo-target-sweep` and a weekly `cargo-target-sweep.timer` in the `cargo` package that delete Rust build output under `~/dev` no build has used in 14 days (`CARGO_TARGET_SWEEP_DAYS`), with `--dry-run` to preview. by @brettdavies in [#258](https://github.com/brettdavies/dotfiles/pull/258)
- Add `cargo-sweep` to the Brewfile on Linux.
- Add `scripts/launchd-user-path.sh`, which reports when the PATH launchd hands GUI apps and LaunchAgents differs from the Homebrew-first value in `config/launchd/user-path` and prints the `sudo launchctl config user path` fix; `--apply` runs it. `scripts/stow-deploy` runs the check on every macOS deploy. by @brettdavies in [#262](https://github.com/brettdavies/dotfiles/pull/262)
- Add a global Claude rule that committing or pushing from a linked worktree is safe only in a repo whose git hooks keep git's environment from the tools they start, with a guide section on what git exports to hooks and how to check a repo's hooks. by @brettdavies in [#265](https://github.com/brettdavies/dotfiles/pull/265)
- Add systemd user timers for the Linux server's scheduled jobs (vault agent-workspace mirror and its health check, OpenClaw settings backup, GitHub stars sync), gated with `ConditionHost` so other Linux hosts leave them inactive. by @brettdavies in [#278](https://github.com/brettdavies/dotfiles/pull/278)
- Add `scripts/host-jobs-enable.sh` to enable those timers on the server and retire the crontab lines they replace.
- Add `backup-openclaw-settings` to `~/.local/bin`.
- Add `github-stars` to `~/.local/bin`: clones and updates starred GitHub repos under `~/github-stars`. by @brettdavies in [#279](https://github.com/brettdavies/dotfiles/pull/279)
- Add a read-only token for the stars sync, loaded from `~/.config/github-stars/env`; `scripts/host-jobs-enable.sh` writes the file from 1Password when it is missing. by @brettdavies in [#280](https://github.com/brettdavies/dotfiles/pull/280)
- Add `github-stars-pdf`, which keeps markdown copies of the starred repos' reference PDFs under `~/github-stars/_pdf-markdown/` for qmd, converting only new or changed PDFs after each successful stars sync. by @brettdavies in [#281](https://github.com/brettdavies/dotfiles/pull/281)
- Add a decisions list for star PDFs (`~/.config/github-stars/pdfs.tsv`); PDFs in neither list are reported once in a vault inbox note, along with listed PDFs that moved or were deleted upstream.
- Add the `hms` and `l30d` tmuxinator projects for the home-media-server and last30days-skill repos. by @brettdavies in [#285](https://github.com/brettdavies/dotfiles/pull/285)
- Add a sleep-guard hook that denies foreground sleeps over 10 s, foreground polling loops, and background polls or fixed waits over 10 s, each with a rebuilt command to rerun. by @brettdavies in [#287](https://github.com/brettdavies/dotfiles/pull/287)
- Add a self-match-guard hook that denies `pgrep -f` / `pkill -f` patterns that match their own command, with a bracketed pattern or PID advice to rerun.
- Add daily scheduled upgrades: the `bu` Homebrew function at 04:00 and `uv tool upgrade --all` at 04:30, as LaunchAgents on macOS and host-gated systemd user timers on the Linux server. by @brettdavies in [#289](https://github.com/brettdavies/dotfiles/pull/289)
- Add a JSON Lines run log for both jobs, in `~/Library/Logs/<job>.jsonl` on macOS and the journal on Linux, with a stable `reason`, the packages each run changed, and a `next_step` for failures.
- Add `stale_processes` to the scheduled brew job's run.end on the Linux server: long-running user services still on a binary the upgrade removed are restarted with `systemctl --user try-restart`, and other processes on a removed binary, such as tmux, are reported as warnings. by @brettdavies in [#295](https://github.com/brettdavies/dotfiles/pull/295)
- Add log rotation for the macOS upgrade agents: a log past 1 MiB moves to `<log>.1` before the next run.
- Add `scripts/fseventsd-check.sh` and a Claude Code SessionStart hook that runs it on the Mac: when fseventsd holds more than ten times its launchd memory budget, every new session shows `WARNING: fseventsd holds N MB against its 30 MB launchd budget; reset it with: sudo killall fseventsd`. by @brettdavies in [#301](https://github.com/brettdavies/dotfiles/pull/301)

### Changed

- Remove the `caam` stow package, its shell fragment, and its git-crypt vault. Account rotation is handled by cswap. by @brettdavies in [#234](https://github.com/brettdavies/dotfiles/pull/234)
- Change the Box `rclone.conf` to an untracked, rclone-owned file in `~/.config/rclone/`; the repo ships `rclone.conf.example` with the bootstrap steps instead of the live token. by @brettdavies in [#237](https://github.com/brettdavies/dotfiles/pull/237)
- Local gates run in parallel. `pre-push` drops from roughly 96s to 41s, and `scripts/run-tests` accepts `--perf-only`, `--no-perf`, and a `RUN_TESTS_JOBS` job count. by @brettdavies in [#239](https://github.com/brettdavies/dotfiles/pull/239)
- `mux-all` reports how many projects failed to start, counts only successful starts, and exits non-zero when any failed. by @brettdavies in [#240](https://github.com/brettdavies/dotfiles/pull/240)
- Change yazi's open action (`Enter`, `o`) on Linux to hand files to the Mac when the session is driven from it, falling back to the local editor or PDF text view with the reason shown; the `O` picker still lists the local openers and directories open as before. by @brettdavies in [#241](https://github.com/brettdavies/dotfiles/pull/241)
- Change `Enter` in yazi to open the whole selection, as `o` does, rather than only the hovered file.
- Change the release notes to leave out a PR whose `## Changelog` section is deliberately empty, instead of listing its title. by @brettdavies in [#247](https://github.com/brettdavies/dotfiles/pull/247)
- Change the canonical `.editorconfig` (stowed to `~/.editorconfig`) to cover every file type the fleet formats: utf-8, LF, a final newline and trimmed trailing whitespace everywhere, per-language indentation that matches each formatter, two-space markdown hard breaks, CRLF for iCalendar and email files, and shfmt house style for extensionless hook scripts. by @brettdavies in [#254](https://github.com/brettdavies/dotfiles/pull/254)
- New shells no longer export `NEON_DATABASE_URL`; uncomment its line in the secrets file to restore it. by @brettdavies in [#256](https://github.com/brettdavies/dotfiles/pull/256)
- Remove the host-wide `CFLAGS`/`CXXFLAGS` (`-O3 -march=native -mtune=native -pipe`) and `RUSTFLAGS` (`-C target-cpu=native`) exports from `build-flags.sh`, so local cargo builds use CI's flags and keep one set of artifacts per project instead of one per shell depth. by @brettdavies in [#257](https://github.com/brettdavies/dotfiles/pull/257)
- Change the bash version guard in every guarded script and hook to require bash 4.4, re-execing under Homebrew's bash below it. by @brettdavies in [#263](https://github.com/brettdavies/dotfiles/pull/263)
- Change `cargo-target-sweep` to exit 3 when `numfmt` is not on PATH. by @brettdavies in [#264](https://github.com/brettdavies/dotfiles/pull/264)
- Change the stars timers to run `~/.local/bin/github-stars` and log to the journal. by @brettdavies in [#279](https://github.com/brettdavies/dotfiles/pull/279)
- Change `github-stars` to keep each starred repo as a blobless partial clone that leaves dependency trees, bytecode and binary files (images, media, fonts, archives, native binaries, databases) out of the working tree and the object store; `git show HEAD:<path>` or `git sparse-checkout add <path>` fetches one on demand. by @brettdavies in [#281](https://github.com/brettdavies/dotfiles/pull/281)
- Change `github-stars` to re-clone a repo whose `.git` grows past twice its post-clone size, so the stars directory stays bounded.
- Change the stars sync and clone pass to run with 8 workers. by @brettdavies in [#282](https://github.com/brettdavies/dotfiles/pull/282)
- Change `github-stars-pdf` to look for new PDFs only in clones whose commit changed since the last scan.
- Change `github-stars-pdf` to convert each PDF once more when the converter changes.
- fix(host-jobs): name the stars token item by its current title by @brettdavies in [#283](https://github.com/brettdavies/dotfiles/pull/283)
- Change the PR template to offer `### Breaking changes`, `### Deprecated`, and `### Removed` changelog headings alongside Added, Changed, Fixed, and Documentation, in the order `generate-changelog.py` emits them. by @brettdavies in [#288](https://github.com/brettdavies/dotfiles/pull/288)
- Change the scheduled brew run to `bu --no-greedy`, so self-updating casks (Ghostty, Rectangle, Telegram, AppCleaner) no longer quit their app when the run lands at wake. `bu` accepts `--no-greedy`; a manual `bu` stays greedy. by @brettdavies in [#295](https://github.com/brettdavies/dotfiles/pull/295)
- Change `scripts/stow-deploy` to restart only enabled systemd user timers after a deploy, so a deploy never switches on a timer nobody enabled.
- Change the iCloud Drive mirror of `~/dev` to run hourly and to leave out `node_modules`, `.build`, and `target` directories, removing the copies already in iCloud. by @brettdavies in [#297](https://github.com/brettdavies/dotfiles/pull/297)
- Change the brew and uv upgrade logs in `~/Library/Logs` to keep only their last 1 MiB instead of a current file and one previous `.1` file.
- Change Claude Code's permissions to deny `rustup self` subcommands for agent shell calls, so an agent cannot run `rustup self uninstall`, which deletes the Rust install and edits the stowed `~/.profile` in the repo. Other `rustup` commands stay allowed. by @brettdavies in [#302](https://github.com/brettdavies/dotfiles/pull/302)

### Fixed

- Fix the post-release backport dropping every release-branch edit except `CHANGELOG.md`. The set of synced paths is discovered by comparing `dev` against `main`, so a release-branch change to any file reaches `dev` instead of being reverted by the next release. by @brettdavies in [#227](https://github.com/brettdavies/dotfiles/pull/227)
- Fix `scripts/lint-shell` skipping the release tooling. `sync-dev-after-release.sh` and `scripts/release/*.sh` are now linted by CI and both git hooks.
- Fix the heredoc guard denying commands whose heredoc body merely contains `git commit -m` or `--body`. Writing a file, script, or test fixture that mentions those strings is no longer blocked; only a flag actually fed by a heredoc is. by @brettdavies in [#229](https://github.com/brettdavies/dotfiles/pull/229)
- Fix the guard reporting a heredoc violation for an inline `-m` that shared a command line with an unrelated heredoc.
- Fix the markdown auto-format hook reformatting files the markdownlint config ignores. The prose wrapper and table aligner now honor the same `ignores` globs the linter does, so `docs/solutions/**` and other excluded paths keep the shape their owning tool gave them. by @brettdavies in [#230](https://github.com/brettdavies/dotfiles/pull/230)
- Fix generated `CHANGELOG.md` being re-wrapped after every edit, which committed line-break churn and made the changelog generator's `--dry-run` drift check fail against its own output.
- Fix the cherry-pick release recipe aborting on a guarded-path deletion. Its leak check now filters to added and modified paths, matching the overlay recipe and `guard-main-docs`. by @brettdavies in [#231](https://github.com/brettdavies/dotfiles/pull/231)
- Fix `scripts/sync-dev-after-release.sh` omitting `--only` from the usage string it prints on an argument error.
- Fix the `gh` merge-guard wrapper spinning at 100% CPU when it is reachable on PATH under a path other than `~/.local/bin/gh` (symlinked alias dir, trailing slash, a checkout's stow tree); it now skips itself by file identity and fails loudly with a `FATAL:` line if it ever re-enters itself. by @brettdavies in [#235](https://github.com/brettdavies/dotfiles/pull/235)
- Fix the stowed GitHub PR template so its comments carry no em-dashes; consumer repos that copy it stay verbatim under the prose rule. by @brettdavies in [#236](https://github.com/brettdavies/dotfiles/pull/236)
- Fix Box bisync dying with `invalid_grant` after any checkout or re-deploy restored a consumed refresh token from git. by @brettdavies in [#237](https://github.com/brettdavies/dotfiles/pull/237)
- Fix the `gh` wrapper refusing to run from a second checkout (worktree or scratch clone) whose own copy of the wrapper sat on `PATH`. by @brettdavies in [#238](https://github.com/brettdavies/dotfiles/pull/238)
- The AI-attribution guard no longer passes a commit message or GitHub body larger than the pipe buffer. A trailer in a body over roughly 32KB was allowed through every time, and smaller bodies were allowed intermittently under load. by @brettdavies in [#239](https://github.com/brettdavies/dotfiles/pull/239)
- `git push` no longer aborts with status 141 when the ref list outgrows the pipe buffer.
- The solutions-prefetch and CI-watch reminders no longer go missing on a long pasted log or a multi-line command, and the model-tier guard no longer returns an empty verdict on a prompt with many TIER lines.
- `taildrive-mount` no longer reports a share as mounted when the volume landed elsewhere or the request was refused. by @brettdavies in [#240](https://github.com/brettdavies/dotfiles/pull/240)
- Attaching to a running session no longer fails while the tailnet reconnects: shares already mounted skip the endpoint probe.
- Share names are matched literally against the mount table, so a name containing `.` no longer aliases a different volume.
- Share names that collide under `/Volumes`, empty names, and surrounding whitespace in `TAILDRIVE_SHARES` are rejected or trimmed rather than silently mounting nothing.
- `taildrive-unmount` reports the volumes diskutil refused and exits non-zero.
- Fix SSH to the home servers failing on networks that share the home LAN's address range: the LAN route now applies only when the server's LAN sshd answers, and the Tailscale route applies everywhere else. by @brettdavies in [#243](https://github.com/brettdavies/dotfiles/pull/243)
- Fix the home-LAN SSH route never applying on Linux hosts.
- Fix `gstack-config-apply` managing `checkpoint_push`, a setting gstack 1.89.1 no longer has.
- Fix the release backport PR body citing a tag object's SHA for an annotated tag; it names the released commit. by @brettdavies in [#247](https://github.com/brettdavies/dotfiles/pull/247)
- Fix `sync-dev-after-release.sh --dry-run` refusing to run while a previous sync branch exists; a dry run creates no branch.
- Fix a failed or refused backport leaving the sync branch checked out and blocking the rerun; every exit before the commit returns to `dev` with a clean tree.
- Fix the post-sync changelog check reporting every failure as edited PR bodies; it shows the changelog generator's own reason, and the generator names line-wrap-only drift separately.
- Fix the auto-format hook skipping files in git worktrees checked out under `/tmp`, `/var/tmp`, or `$TMPDIR`; loose drafts in those directories keep their authored shape. by @brettdavies in [#253](https://github.com/brettdavies/dotfiles/pull/253)
- Fix the auto-format hook reformatting shell files the `.editorconfig` marks `ignore`: generated completions and test data (fixtures, testdata, golden files, snapshots) now keep their bytes when edited. by @brettdavies in [#254](https://github.com/brettdavies/dotfiles/pull/254)
- Fix local aws-lc-sys builds failing at jitterentropy's optimization check whenever a project resolves cc 1.6.0. by @brettdavies in [#257](https://github.com/brettdavies/dotfiles/pull/257)
- Fix nested zsh shells prepending Homebrew Ruby's `bin` to `PATH` once more at each level.
- Fix pushes from a linked worktree resetting its branch and corrupting the shared advisory database, by installing cargo-deny 0.20+ from the Brewfile on Linux. by @brettdavies in [#259](https://github.com/brettdavies/dotfiles/pull/259)
- Fix boots on the Linux host randomly skipping AppArmor profile loading, local-filesystem ordering, tmpfiles setup, or utmp recording: the NAS automount no longer orders itself after the network. by @brettdavies in [#260](https://github.com/brettdavies/dotfiles/pull/260)
- Fix the `obsidian` CLI wrapper reporting "unable to find Obsidian" from non-login shells such as agents and cron.
- Fix `scripts/nas-deploy.sh` reporting the NAS unreachable on hosts without `ping`.
- Fix qmd embedding falling back to the CPU and holding it at its thermal limit while the NVIDIA driver is unusable: the embed timer now skips those runs, and any CPU fallback is capped at two cores. by @brettdavies in [#261](https://github.com/brettdavies/dotfiles/pull/261)
- Fix the iCloud sync LaunchAgent (`com.user.devtosync`) running under the macOS system bash 3.2: it now sets the same inline PATH as the other agents, and its script uses `#!/usr/bin/env bash`. by @brettdavies in [#262](https://github.com/brettdavies/dotfiles/pull/262)
- Fix scripts that need bash 4 (`lint-shell`, `lint-workflows`, `run-tests`, `release/guarded-paths.sh`, `tools-atime.sh`, `cargo-target-sweep`, `solutions-clone-autosync.sh`, `mac-open`) failing when the macOS system bash 3.2 starts them: each re-execs under Homebrew bash, or exits with a `brew install bash` hint.
- Fix pushes and commits from a linked worktree letting a hook's child tools run git against the worktree's repository, which could move the branch, mark the repository bare, or corrupt the commit's temporary index. by @brettdavies in [#263](https://github.com/brettdavies/dotfiles/pull/263)
- Fix the dotfiles pre-commit hook failing with `mapfile: command not found` when started by the macOS system bash 3.2.
- Fix `cargo-target-sweep` exiting with status 64 and no output on macOS, where BSD `du` rejects `-b`. by @brettdavies in [#264](https://github.com/brettdavies/dotfiles/pull/264)
- Fix the markdown auto-format hook collapsing the whitespace inside inline code spans, which turned quoted help-text column layouts into single-spaced text. by @brettdavies in [#266](https://github.com/brettdavies/dotfiles/pull/266)
- Fix the markdown auto-format hook breaking lines inside inline code spans; each span now stays whole on one line.
- Fix the markdown auto-format hook starting a wrapped line with a token markdown reads as a heading, list item, or other structure, which made a file change again on every reflow and could turn an issue reference into a heading or re-indent part of a list item. by @brettdavies in [#267](https://github.com/brettdavies/dotfiles/pull/267)
- Fix the markdown auto-format hook leaving an inline code span wider than the line on one overlong line; it now wraps at the span's single spaces and keeps its multi-space runs intact.
- Fix `scripts/tmux/prune-orphans.sh` hanging indefinitely against a wedged tmux server. It now exits 1 with an `ERROR:` line after 10 seconds, so the `tmux-prune-orphans` timer unit fails visibly instead of never finishing. by @brettdavies in [#272](https://github.com/brettdavies/dotfiles/pull/272)
- Fix `mac-open` hanging in yazi when the tmux server stops answering. It now refuses the hand-off within about 5 seconds with `not-from-mac: tmux reported no client for this session`. by @brettdavies in [#273](https://github.com/brettdavies/dotfiles/pull/273)
- Fix the Claude Code permission rule for the vault sync script, which named a path that no longer exists. by @brettdavies in [#278](https://github.com/brettdavies/dotfiles/pull/278)
- Fix `github-stars` exposing the GitHub token in process arguments and `.git/config`; git now reads it from its environment. by @brettdavies in [#279](https://github.com/brettdavies/dotfiles/pull/279)
- Fix `github-stars` exiting 0 on an unknown option; it now exits 2.
- Fix `github-stars` deleting committed `vendor/`, `build/`, `dist/`, `out/` and `target/` directories from starred-repo clones; the next update restores them. by @brettdavies in [#281](https://github.com/brettdavies/dotfiles/pull/281)
- Fix `github-stars` rewriting and deleting the same files on every hourly update, which left about 70 clones with a dirty `git status`.
- Fix `github-stars --prune` deleting a clone whose repo GitHub blocks or no longer serves, which could erase the only copy. by @brettdavies in [#282](https://github.com/brettdavies/dotfiles/pull/282)
- Fix `github-stars-pdf` retrying a PDF that failed to convert after every stars sync; a failed version is reported once and retried only when the PDF changes.
- Fix the ShellCheck gate skipping 17 shell scripts under `scripts/`; every `sh` or `bash` script there is now linted in pre-commit, pre-push, and CI. by @brettdavies in [#284](https://github.com/brettdavies/dotfiles/pull/284)
- Fix pipx apps installed from one kind of launcher being invisible to pipx run from another, by leaving `PIPX_HOME` at pipx's platform default instead of relocating it into the XDG cache. by @brettdavies in [#286](https://github.com/brettdavies/dotfiles/pull/286)
- Fix the markdown auto-format hook breaking Obsidian wikilinks across lines, which left them unresolved in the vault. by @brettdavies in [#290](https://github.com/brettdavies/dotfiles/pull/290)
- Fix the upgrade run log reporting every package as changed when a version listing fails (`changes` is now null, with a warning), and keep config/shell helper output out of the JSON log. by @brettdavies in [#295](https://github.com/brettdavies/dotfiles/pull/295)
- Fix the iCloud mirror's logs growing without bound: each run appends one summary line to `~/Library/Logs/devtosync.log` and its rsync errors to `devtosync.error.log`, and each log keeps only its last 1 MiB. by @brettdavies in [#297](https://github.com/brettdavies/dotfiles/pull/297)
- Fix the Mac's scheduled brew and uv upgrades failing after a night asleep. Each agent now fires hourly and runs the upgrade only when it has not succeeded in the last 20 hours and the network answers, so the day's run lands at the first hour the Mac is awake and online. An offline fire with no success in 48 hours writes a `WARNING:` line to the agent's `.error.log`. by @brettdavies in [#300](https://github.com/brettdavies/dotfiles/pull/300)

### Documentation

- Document the backport's discovery and its release-prep versus contested classification in `RELEASES.md`, with the post-merge convergence check that catches an unresolved contested path. by @brettdavies in [#227](https://github.com/brettdavies/dotfiles/pull/227)
- Correct the release runbook's description of the backport, which still called it CHANGELOG-only after it began discovering every diverged path, and lead its command block with the `--dry-run` classification the surrounding prose tells you to start from. by @brettdavies in [#231](https://github.com/brettdavies/dotfiles/pull/231)
- Record the guard beside the no-AI-attribution rule in `CLAUDE.md` and the git/GitHub guide. by @brettdavies in [#233](https://github.com/brettdavies/dotfiles/pull/233)
- Drop caam from the stow package table, the shell helper table, and the package summary, and add the `cswap` package. by @brettdavies in [#234](https://github.com/brettdavies/dotfiles/pull/234)
- README covers the two platform branches of `vault.yml`, what the start hook guarantees, and the wedged-mount case it cannot cover. by @brettdavies in [#240](https://github.com/brettdavies/dotfiles/pull/240)
- Document the hand-off's routes, fallback, and five-step setup in the README's "Yazi Hand-off to the Mac" section. by @brettdavies in [#241](https://github.com/brettdavies/dotfiles/pull/241)
- Document the unit in `BOOTSTRAP.md`, `AGENTS.md` and `README.md`, and name the `svc:codex-proxy` binding alongside `svc:ollama` where the setup script is described. by @brettdavies in [#245](https://github.com/brettdavies/dotfiles/pull/245)
- Document `gtime` as the way agents time a command and read its peak memory. by @brettdavies in [#251](https://github.com/brettdavies/dotfiles/pull/251)
- Name `.editorconfig` in the shell style guide as the settings source a bare `shfmt` reads, and note that any formatting flag makes shfmt ignore it. by @brettdavies in [#253](https://github.com/brettdavies/dotfiles/pull/253)
- Describe in the shell style guide how the `.editorconfig` covers extensionless hook scripts, which files its `ignore` sections skip, and that a formatting flag makes shfmt drop the file's formatting settings but not its `ignore` sections. by @brettdavies in [#254](https://github.com/brettdavies/dotfiles/pull/254)
- Document the Bun pin bump in the cli-tools guide: which declarations move, when the `bun-types` caret moves, the plain `bun install` that records a caret edit, and why `bun.lock` is never regenerated from scratch. by @brettdavies in [#255](https://github.com/brettdavies/dotfiles/pull/255)
- Document enabling the sweep timer in BOOTSTRAP. by @brettdavies in [#258](https://github.com/brettdavies/dotfiles/pull/258)
- Document the launchd user PATH in README, AGENTS.md, BOOTSTRAP.md and CONCEPTS.md, and add the `env bash` shebang and bash >= 4 guard to AGENTS.md's script conventions. by @brettdavies in [#262](https://github.com/brettdavies/dotfiles/pull/262)
- Document how the auto-format hook treats inline code spans, including markdownlint's MD038 trimming of leading and trailing spaces. by @brettdavies in [#266](https://github.com/brettdavies/dotfiles/pull/266)
- Fix the CI-watch policy so it no longer claims `gh pr checks --watch` exits 0 on a failed check, and so the cross-repo `gh run watch` example passes `--exit-status`. by @brettdavies in [#275](https://github.com/brettdavies/dotfiles/pull/275)
- Add a runbook procedure for installing optional NVIDIA userspace libraries (NVENC, NVDEC) at the matching `-server` branch and driver version without disturbing the driver or qmd. by @brettdavies in [#277](https://github.com/brettdavies/dotfiles/pull/277)
- Add "Never block on a wait" to the global Claude instructions and "Waiting without blocking" to the workflows guide. by @brettdavies in [#287](https://github.com/brettdavies/dotfiles/pull/287)
- Document loading, running, and triaging the scheduled upgrades in BOOTSTRAP.md for macOS and the Linux server. by @brettdavies in [#289](https://github.com/brettdavies/dotfiles/pull/289)
- Change the `AGENTS.md` GitHub Actions rule: workflows no longer set `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24`, since GitHub runs JavaScript actions on Node.js 24. by @brettdavies in [#298](https://github.com/brettdavies/dotfiles/pull/298)
- Document the hourly retry in BOOTSTRAP's launchd section, including where the success record lives and how to force a run (trash the record, then `launchctl kickstart`). by @brettdavies in [#300](https://github.com/brettdavies/dotfiles/pull/300)
- Document the fseventsd memory check in BOOTSTRAP's macOS section, including how to reset the daemon and what the restart costs (Spotlight, Dropbox, and iCloud Drive may rescan). by @brettdavies in [#301](https://github.com/brettdavies/dotfiles/pull/301)

### Removed

- Remove the `opendataloader-pdf` stow package and its `scripts/opendataloader-pdf-enable.sh` enabler. The socket-activated hybrid PDF server on `127.0.0.1:5002` is no longer deployed; the `opendataloader-pdf` CLI is unaffected. by @brettdavies in [#294](https://github.com/brettdavies/dotfiles/pull/294)

**Full Changelog**: [2026.09.14...2026.10.25](https://github.com/brettdavies/dotfiles/compare/2026.09.14...2026.10.25)

## [2026.09.14] - 2026-09-14

### Added

- Add the `qmd-learnings-researcher` Claude Code agent to the `claude` stow package, deploying to `~/.claude/agents/`. by @brettdavies in [#162](https://github.com/brettdavies/dotfiles/pull/162)
- Add the orchestrator-handoff template, deploying to `~/.claude/templates/orchestrator-handoff.md`. by @brettdavies in [#163](https://github.com/brettdavies/dotfiles/pull/163)
- Add `transcribe-diarize`, a local GPU speaker-diarized transcription script (whisperx + pyannote), deploying to `~/.local/bin/transcribe-diarize`.
- Add `unslop` and `unslop-gate` commands to `~/.local/bin` so repo hooks can score prose, with per-tree strictness, without vendoring the scorer by @brettdavies in [#167](https://github.com/brettdavies/dotfiles/pull/167)
- `sd-commit-doc` helper that commits and pushes `docs/solutions/` files from an isolated worktree and keeps the shared clone fast-forwarded to origin. by @brettdavies in [#172](https://github.com/brettdavies/dotfiles/pull/172)
- Codex desktop app configuration is now tracked: computer-use notify hook, `node_repl` MCP server, marketplace registrations, and the enabled plugin set. by @brettdavies in [#173](https://github.com/brettdavies/dotfiles/pull/173)
- `scripts/macos-gpu-monitor.sh` traces peak Metal GPU residency and power around any command on macOS, with optional per-process CPU and RSS sampling via `--proc` and a sudo-free `--no-gpu` mode. by @brettdavies in [#174](https://github.com/brettdavies/dotfiles/pull/174)
- `shfmt` is now installed by `brew bundle`, so the shell auto-format hook has the formatter it depends on. by @brettdavies in [#175](https://github.com/brettdavies/dotfiles/pull/175)
- Session-start safety net that fast-forwards the shared `~/dev/solutions-docs` clone to origin, so a clone left behind by a hand-rolled commit flow self-heals at the next session instead of drifting silently. by @brettdavies in [#176](https://github.com/brettdavies/dotfiles/pull/176)
- Add `model-tier-guard.sh`, a `PreToolUse` hook that denies an `Agent` dispatch whose requested model contradicts the `TIER:` line in its prompt. by @brettdavies in [#178](https://github.com/brettdavies/dotfiles/pull/178)
- Add `qmd-gpu-verify`: deterministic PASS/FAIL verification that the qmd-serve daemon runs its models on the GPU (systemd unit + live env pin + VRAM residency, optional `--live` ramp probe), with a graceful launchd/powermetrics path on macOS. by @brettdavies in [#179](https://github.com/brettdavies/dotfiles/pull/179)
- `mios` tmuxinator project for `~/dev/meum-ios`. by @brettdavies in [#180](https://github.com/brettdavies/dotfiles/pull/180)
- `msites` tmuxinator project for the Meum Sites repo. by @brettdavies in [#181](https://github.com/brettdavies/dotfiles/pull/181)
- `cargo` stow package (Linux only) that routes git dependency fetches through the git CLI, so a git dependency resolves for systemd units, cron, CI and agent tool calls rather than only for shells with an SSH agent.
 by @brettdavies in [#188](https://github.com/brettdavies/dotfiles/pull/188)
- Workflow files are linted by actionlint in CI, pre-push, and pre-commit. Previously nothing checked them, and a shell quoting bug inside a `run:` block could reach `main` and misfire during a release. by @brettdavies in [#190](https://github.com/brettdavies/dotfiles/pull/190)
- Add the qmd thin client / brain host concept to CONCEPTS.md. by @brettdavies in [#193](https://github.com/brettdavies/dotfiles/pull/193)
- Add gstack's timeline Stop hook to the Claude Code settings.
- Add `scripts/sshd-locale-deploy.sh`, which stops `sshd` accepting `LANG` and `LC_*` from clients so sessions take the server's `C.UTF-8` from `/etc/default/locale`; it edits the main config and drop-ins in place, validates with `sshd -t`, restores on rejection, reloads `sshd`, and is safe to re-run. by @brettdavies in [#195](https://github.com/brettdavies/dotfiles/pull/195)
- `scripts/stow-deploy` honors `STOW_DEPLOY_TARGET` as its deploy target directory (default `$HOME`). by @brettdavies in [#199](https://github.com/brettdavies/dotfiles/pull/199)
- Install the CodexBar CLI on Linux hosts via `brew bundle`, so CodexBar's agent-session menu can report sessions running on them instead of showing the host as unreachable. by @brettdavies in [#201](https://github.com/brettdavies/dotfiles/pull/201)
- Add `scripts/codexbar-config` to move CodexBar's config between this repo and `~/.config/codexbar/config.json` (`deploy`, `capture`, `diff`).
- Add `scripts/claude-token-totals` to report Claude Code lifetime token usage summed across machines, with each host's share. `/usage` counts only the machine it runs on. by @brettdavies in [#202](https://github.com/brettdavies/dotfiles/pull/202)
- Add `bu`, an interactive shell function that runs `brew update`, `brew upgrade --greedy -y`, and `brew cleanup` in sequence, stopping at the first failure. by @brettdavies in [#206](https://github.com/brettdavies/dotfiles/pull/206)
- Add `gstack-config-apply`, which pins gstack's telemetry, sync, review, hook, prompt, and auto-update settings to the repo's values and runs at every Claude Code session start; `--check` reports drift, `--list` shows the managed table. by @brettdavies in [#215](https://github.com/brettdavies/dotfiles/pull/215)
- Install `wrangler` from the Brewfile on both macOS and Linux, for use outside a project directory. by @brettdavies in [#219](https://github.com/brettdavies/dotfiles/pull/219)
- Add the `homebrew-app` cask (Homebrew's official GUI) to the macOS Brewfile set, installed only on macOS 26 or later. by @brettdavies in [#220](https://github.com/brettdavies/dotfiles/pull/220)
- Reach the macOS workstation by host alias instead of passing an explicit identity file on every connection. by @brettdavies in [#221](https://github.com/brettdavies/dotfiles/pull/221)
- Document the error contract for structured output in the global instructions: a stable reason from a closed set, an exit code, a human message, the offending value, and a next step with a headless-safe command. by @brettdavies in [#223](https://github.com/brettdavies/dotfiles/pull/223)

### Changed

- The markdown auto-format hook now skips a repo entirely (prose wrap, table align, and lint autofix) when that repo sets `MD013.line_length` to 9999 or higher in its `.markdownlint-cli2.yaml`. Lets a repo whose committed markdown owns its own wrapping stay untouched on edit. by @brettdavies in [#165](https://github.com/brettdavies/dotfiles/pull/165)
- Claude Code sessions default to opus and skip the dangerous-mode startup prompt. by @brettdavies in [#173](https://github.com/brettdavies/dotfiles/pull/173)
- `bun run`, `python3`, `uv run`, and `xargs` no longer prompt for permission. Deny-listed and delete-shaped commands are unaffected.
- tmuxinator reads and writes projects in `stow/tmuxinator/dot-config/tmuxinator/` directly. `tmuxinator new` and `tmuxinator copy` land on the source of truth with no deploy step, and `tmux-new-session` no longer re-stows. by @brettdavies in [#180](https://github.com/brettdavies/dotfiles/pull/180)
- Remove the `gbrain` stow package and the `gbrain-sync`, `gbrain-dream`, and `claude-code-archive` systemd timers. On a host where these are already deployed, stop and disable the timers before redeploying: stow no longer manages the package, so it will not reconcile the symlinks and they are left pointing at a deleted source. by @brettdavies in [#182](https://github.com/brettdavies/dotfiles/pull/182)
- Remove the `claude-code-sessions` qmd collection. Transcripts already written under `~/.gbrain/transcripts/` stay on disk but are no longer indexed or searchable.
- `pre-push` runs the full local CI mirror and `pre-commit` runs the same checks over staged files, so a red pipeline should be a surprise rather than routine. A missing tool skips its step with an install hint instead of blocking the commit or push. by @brettdavies in [#184](https://github.com/brettdavies/dotfiles/pull/184)
- `scripts/stow-deploy` sets the rustup install profile to minimal when the `cargo` package deploys, so toolchains stop downloading `rust-docs` rather than having it removed afterwards.
 by @brettdavies in [#188](https://github.com/brettdavies/dotfiles/pull/188)
- Change the canonical Playwright browser set to 1.62.1 (chromium 1234 / Chrome for Testing 151, webkit 2336); chromium 1228 now resolves through a consumer alias to the canonical build. by @brettdavies in [#191](https://github.com/brettdavies/dotfiles/pull/191)
- Change the default Claude Code model from opus to fable. by @brettdavies in [#193](https://github.com/brettdavies/dotfiles/pull/193)
- Change the `ssh` package's Linux-server host entries to pin `SetEnv LANG=C.UTF-8`, so the client stops the override even against a server that still accepts the variable. by @brettdavies in [#195](https://github.com/brettdavies/dotfiles/pull/195)
- Change the Linux qmd collections template to exclude the `stars` collection from default queries; search it explicitly with `qmd query -c stars`. by @brettdavies in [#196](https://github.com/brettdavies/dotfiles/pull/196)
- refactor(tools-atime): quote the sort key specs in the sort_args arrays by @brettdavies in [#197](https://github.com/brettdavies/dotfiles/pull/197)
- `ollama-update` is now defined in the interactive shell helpers rather than `.profile`, so it is available in interactive shells only. by @brettdavies in [#204](https://github.com/brettdavies/dotfiles/pull/204)
- Remove the rtk token-compression hook from the Claude Code Bash `PreToolUse` chain, along with its two permission entries. Bash output is no longer rewritten before the agent sees it. by @brettdavies in [#205](https://github.com/brettdavies/dotfiles/pull/205)
- Drop `rtk` from the Brewfile so `brew bundle` stops installing it on new machines.
- Claude Code tool shells now run with `LANG=C.UTF-8` instead of inheriting the session locale, so tools that decode non-ASCII output behave consistently on hosts that generate only `C.UTF-8`. by @brettdavies in [#208](https://github.com/brettdavies/dotfiles/pull/208)
- Remove the `gstack` tmuxinator project, whose root directory no longer exists. by @brettdavies in [#209](https://github.com/brettdavies/dotfiles/pull/209)
- Remove the `hbcore` tmuxinator project, whose root directory no longer exists once the local `homebrew/core` tap is removed. by @brettdavies in [#211](https://github.com/brettdavies/dotfiles/pull/211)
- `sd-commit-doc` now checks frontmatter against the corpus schema before committing, so a rejected doc fails in about a second with the offending field named, instead of aborting part-way through a commit. by @brettdavies in [#214](https://github.com/brettdavies/dotfiles/pull/214)
- A failed `sd-commit-doc` run now prints `sd-commit-doc: FAILED during <step>` on stderr, so the failure is identifiable even when hook output fills the end of the transcript.
- Adopt the live Claude Code settings: permission mode `auto`, Opus with the long context window, and agent push notifications on. by @brettdavies in [#223](https://github.com/brettdavies/dotfiles/pull/223)

### Fixed

- `md-wrap.py` reflows nested and long markdown list items idempotently, preserving nesting depth and keeping a list marker on the same line as its content. by @brettdavies in [#164](https://github.com/brettdavies/dotfiles/pull/164)
- Alias lagging-consumer chromium revisions (e.g. crawl4ai / patchright's 1223) to the canonical provisioned build, so their headless and headed browser launches resolve to the single canonical chromium instead of failing with `Executable doesn't exist`. by @brettdavies in [#166](https://github.com/brettdavies/dotfiles/pull/166)
- Fix the opendataloader-pdf launcher-help test failing, rather than skipping, on hosts whose uv-tool lacks the hybrid extras by @brettdavies in [#167](https://github.com/brettdavies/dotfiles/pull/167)
- Fix `unslop-gate` missing from the deployed `~/.local/bin` set after #167, which left consuming repo hooks skipping their prose gates by @brettdavies in [#168](https://github.com/brettdavies/dotfiles/pull/168)
- Fix `unslop-gate` masking git's non-fast-forward rejection with a bad-revision fatal when a push had nothing deliverable by @brettdavies in [#169](https://github.com/brettdavies/dotfiles/pull/169)
- Nightly autocommit no longer strands commits or drifts behind origin on a shared clone: it fast-forwards the local branch to origin before committing and rebases onto origin before retrying a rejected push. by @brettdavies in [#170](https://github.com/brettdavies/dotfiles/pull/170)
- Pushing from a git worktree no longer lets the bats suite operate on the real repository, which could rewrite `.git/config`, move HEAD, and push a stray commit to origin. by @brettdavies in [#180](https://github.com/brettdavies/dotfiles/pull/180)
- `mux-all` no longer restarts sessions that are already running when a config's `name:` differs from its filename.
- The `client-detached` orphan-prune hook now runs on macOS instead of silently exiting.
- Shell helpers in `config/shell/` load in terminals launched from the dock or Spotlight, and under cron and `ssh host cmd`. Previously they took effect only in shells started from another shell, so tool wrappers and exports such as `TMUXINATOR_CONFIG` were missing from a freshly opened window until the shell was replaced. by @brettdavies in [#181](https://github.com/brettdavies/dotfiles/pull/181)
- `tmux-new-session` starts sessions when invoked from launchd, cron, or a remote `ssh` command, rather than only from a shell that has sourced the dotfiles profile.
- Seven test assertions that silently passed regardless of their result are now enforced. by @brettdavies in [#184](https://github.com/brettdavies/dotfiles/pull/184)
- Shell startup latency checks no longer fail at random on a loaded machine.
- Release version bump no longer treats the date prefix as a glob pattern when deriving the next suffix.
- `CARGO_HOME` and `RUSTUP_HOME` are no longer relocated into the cache directory. A host could otherwise end up with two Rust toolchain trees, one used by interactive shells and another by systemd units, cron, git hooks and agent tooling, with `cargo install` writing to whichever the caller happened to see. by @brettdavies in [#186](https://github.com/brettdavies/dotfiles/pull/186)
- `trash` is a real binary on Linux via trash-cli rather than a shell alias, so scripts, systemd units, cron jobs, git hooks and agent tool calls can honor the repo's ban on `rm`. Previously it resolved only inside interactive shells. by @brettdavies in [#187](https://github.com/brettdavies/dotfiles/pull/187)
- Fix 10 tmuxinator project configs (cfoh, crawl4ai-skill, gstack, lmgrok, mapi, meum, msdk, oppusa, paxel, yc) that were invisible to tmuxinator: they now live in the canonical config dir with resize targets pointing at their own sessions. by @brettdavies in [#192](https://github.com/brettdavies/dotfiles/pull/192)
- Fix the five-minute qmd update timer to run `qmd update` only; vacuum, FTS optimize, and LLM cache drop now happen once a day in the nightly cleanup unit instead of every five minutes. by @brettdavies in [#194](https://github.com/brettdavies/dotfiles/pull/194)
- Running the bats suite from a git worktree or a second clone (the pre-push hook does this on every push) no longer re-points the live `~` symlinks at that checkout: the deploy-executing cases stow into a per-test sandbox. by @brettdavies in [#199](https://github.com/brettdavies/dotfiles/pull/199)
- Restore PATH assembly for `sh -lc` callers on Linux hosts. `~/.profile` aborted partway through under dash, leaving remote tooling with a bare PATH and unable to find Homebrew, `~/.local/bin`, bun, or cargo binaries. by @brettdavies in [#200](https://github.com/brettdavies/dotfiles/pull/200)
- `lp`, `lp1`, and `xurl` now resolve in non-interactive shells. As aliases they silently did not exist for scripted callers under `bash -lc`. by @brettdavies in [#204](https://github.com/brettdavies/dotfiles/pull/204)
- Fix the `Stop hook error: … timeline-stop-hook: No such file or directory` message Claude Code printed after every response on machines other than the one that registered the hook. by @brettdavies in [#207](https://github.com/brettdavies/dotfiles/pull/207)
- Fix the pre-push hook running the full lint and bats gate on pushes that deliver nothing: branch deletes, up-to-date pushes, tags on already-pushed commits, and history rewrites that keep the tree. by @brettdavies in [#212](https://github.com/brettdavies/dotfiles/pull/212)
- Fix four Claude Code permission rules that only matched on the Linux host, so the same commands no longer re-prompt on macOS. by @brettdavies in [#213](https://github.com/brettdavies/dotfiles/pull/213)
- Deploy the `rust` and `caddy` stow packages. A fresh host previously skipped both, leaving the Rust toolchain with no update timer and Ollama's tailnet route with no `Host`-rewriting proxy. by @brettdavies in [#216](https://github.com/brettdavies/dotfiles/pull/216)
- Stop relocating the bun install root. `bun add -g` packages and the `qmd` global now resolve from a single `~/.bun`, instead of dividing across `~/.bun` and `~/.cache/bun` with both on `PATH`. by @brettdavies in [#217](https://github.com/brettdavies/dotfiles/pull/217)
- Point the four qmd LaunchAgents at the stock bun bin directory, so launchd resolves the same global bin as the shell.
- Start `qmd-serve` from the stowed dispatcher at `~/.local/bin/qmd` rather than through the bun global bin directory, so the daemon always runs the fork and cannot be switched to the upstream package by a global bun install. by @brettdavies in [#218](https://github.com/brettdavies/dotfiles/pull/218)
- Bootstrap `com.user.qmd-serve` alongside the other agents on macOS. The launchagent package shipped it but the enable script never started it, so a rebuilt machine had no resident model server and every qmd call cold-loaded a model. by @brettdavies in [#219](https://github.com/brettdavies/dotfiles/pull/219)
- Resolve qmd through the stowed dispatcher on macOS. The LaunchAgents no longer list a bun bin directory, so a missing dispatcher fails instead of silently falling through to the upstream package, and the enable script requires the dispatcher rather than accepting either path.
- Make the `qmd-serve` enable script's `/health` smoke retry a refused connection. It previously reported a healthy daemon as dead, in milliseconds, with misleading causes.
- Take bun from Homebrew's official tap only. A host carrying both that and the curl installer ran the curl copy for every call while `brew upgrade` maintained a separate one, with nothing reporting the version gap. by @brettdavies in [#222](https://github.com/brettdavies/dotfiles/pull/222)

### Documentation

- README documents `TMUXINATOR_CONFIG` as the single project directory, the `~/.config/tmuxinator` shadowing hazard, and the `tmuxinator copy` footgun. by @brettdavies in [#180](https://github.com/brettdavies/dotfiles/pull/180)
- README records the ordering constraint for `config/shell/`, so a new file dropped in there is not silently dead in GUI-launched shells. by @brettdavies in [#181](https://github.com/brettdavies/dotfiles/pull/181)
- Remove the gbrain thin client and Claude Code session pipeline entries from the concepts glossary. by @brettdavies in [#182](https://github.com/brettdavies/dotfiles/pull/182)
- AGENTS.md documents how the local gates map onto CI jobs, and why tool versions are pinned alongside the commands. by @brettdavies in [#184](https://github.com/brettdavies/dotfiles/pull/184)
- AGENTS.md tabulates the eight supported shell invocation shapes and the startup files each one reads. by @brettdavies in [#185](https://github.com/brettdavies/dotfiles/pull/185)
- The CLI tools guide records where `trash` comes from on each platform, why it cannot be an alias, and the one sanctioned `rm -rf` fallback. by @brettdavies in [#187](https://github.com/brettdavies/dotfiles/pull/187)
- BOOTSTRAP.md installs rustup with `--profile minimal`, and records why the setting can be neither exported nor stowed.
 by @brettdavies in [#188](https://github.com/brettdavies/dotfiles/pull/188)
- `CONCEPTS.md` records that ordering within the shell config chain is load-bearing, and that the failure it prevents is silent. by @brettdavies in [#189](https://github.com/brettdavies/dotfiles/pull/189)
- Change the release runbook to build `release/YYYY.MM.DD` as an overlay of `dev` on `main`, with the drift gate, the guarded-set leak check, and `generate-changelog.py --from-dev-prs`. by @brettdavies in [#198](https://github.com/brettdavies/dotfiles/pull/198)
- Record that the shell config chain's entry file is dialect-constrained as well as order-constrained, and define `Invocation shape` as the unit at which shell environment behavior is specified and verified. by @brettdavies in [#203](https://github.com/brettdavies/dotfiles/pull/203)
- Document the `dash` login shape in the invocation-shape table, and the syntax constraint it places on `.profile`. by @brettdavies in [#204](https://github.com/brettdavies/dotfiles/pull/204)
- Remove the rtk auto-rewrite section from the CLI tools guide and the rtk reference from the global CLAUDE.md preference list. by @brettdavies in [#205](https://github.com/brettdavies/dotfiles/pull/205)
- Define `install root` in `CONCEPTS.md`, and why relocating one diverges for every bare launcher. by @brettdavies in [#216](https://github.com/brettdavies/dotfiles/pull/216)
- Correct three `CONCEPTS.md` entries that described guards and an architecture the repo does not have, and add `Package set`, `Stowed dispatcher`, `Shadowed executable`, and `Captured environment`. by @brettdavies in [#223](https://github.com/brettdavies/dotfiles/pull/223)

**Full Changelog**: [2026.06.26...2026.09.14](https://github.com/brettdavies/dotfiles/compare/2026.06.26...2026.09.14)

## [2026.06.26]

### Added

- Claude Code now auto-formats shell scripts with `shfmt -i 2 -ci -bn` on edit, matching the pre-commit and pre-push shell checks. by @brettdavies in [#132](https://github.com/brettdavies/dotfiles/pull/132)
- New `~/.claude/guides/shell-style.md` covering shell conventions `shfmt` and `shellcheck` do not enforce: function naming, `ALL_CAPS` constants, doc-block shape, function ordering, and errors-to-STDERR.
- `scripts/tailscale-serve-setup.sh`: idempotent reproducer for bigdaddy's Tailscale Serve config (openclaw node serve + `svc:ollama` service serve), so a fresh host or a dropped binding recovers in one run. by @brettdavies in [#136](https://github.com/brettdavies/dotfiles/pull/136)
- `com.user.qmd-serve` LaunchAgent that keeps `qmd serve` resident on `127.0.0.1:7832` (loopback only), with `RunAtLoad` + `KeepAlive`, full-resident (no `--low-vram`). by @brettdavies in [#138](https://github.com/brettdavies/dotfiles/pull/138)
- `brave-search` helper: query the Brave Search API from the CLI and print ranked results, with the API key read from 1Password at call time via a mode-600 curl config so it never reaches a child process argv or an exported env var. by @brettdavies in [#148](https://github.com/brettdavies/dotfiles/pull/148)
- `gh-revision-audit` helper: list issues and PRs you authored that still carry multiple non-deleted edit-history revisions worth pruning through the GitHub web UI.
- `~/.grok/bin` on PATH with grok zsh completions.
- Tailscale serve binding for `svc:codex-proxy`: advertises the codex-proxy OpenAI-compat endpoint at `https://codex-proxy.<tailnet>/` forwarding to `127.0.0.1:8080`, health-gated before the VIP is pointed at it. Unlike `svc:ollama` it needs no Caddy Host-rewrite shim (codex-proxy accepts any Host header); inbound stays gated by the tailnet ACL plus the `LITELLM_API_KEY` bearer. by @brettdavies in [#149](https://github.com/brettdavies/dotfiles/pull/149)
- Deploy the gbrain thin-client config on macOS via stow, pointing at the shared Postgres brain; the Mac is a read-only client with no local indexing daemons. by @brettdavies in [#150](https://github.com/brettdavies/dotfiles/pull/150)
- Route gbrain embeddings and chat/expansion to the tailnet services on macOS via Darwin-gated `OLLAMA_BASE_URL` / `LITELLM_BASE_URL`, keeping a single shared embedder for vector-space consistency.
- `xurl` alias plus a `~/.local/bin/xurl` shim, both forwarding to `xr` (the `xurl-rs` binary). The alias covers interactive shells; the shim covers subprocess callers that never load it. by @brettdavies in [#152](https://github.com/brettdavies/dotfiles/pull/152)

### Changed

- Install `ruby` explicitly via the Brewfile. by @brettdavies in [#134](https://github.com/brettdavies/dotfiles/pull/134)
- macOS `qmd` dispatcher now targets the fork launcher (`~/dev/qmd/bin/qmd`), which provides `qmd serve` and `QMD_REMOTE_URL`; the upstream package provided neither. by @brettdavies in [#138](https://github.com/brettdavies/dotfiles/pull/138)
- `QMD_REMOTE_URL` is now exported on all platforms; `QMD_LOW_VRAM` is now Linux-only (macOS runs the daemon full-resident).
- The periodic `com.user.qmd-embed` job routes through the resident daemon (`QMD_REMOTE_URL` declared in the plist `EnvironmentVariables`, since launchd does not inherit the interactive shell environment).
- Promote reusable permission grants (tailscale serve, caddy, ssh-keygen fingerprint reads) into the global Claude allowlist, default the permission mode to `acceptEdits`, and disable workflow keyword triggers. by @brettdavies in [#148](https://github.com/brettdavies/dotfiles/pull/148)
- Allow `time ./scripts/generate-changelog.py *` in the global permission allowlist alongside the existing `generate-changelog.sh` grants. by @brettdavies in [#149](https://github.com/brettdavies/dotfiles/pull/149)
- `scripts/stow-deploy` no longer treats `gbrain` as Linux-only: its config deploys on macOS while its systemd indexing units are dropped. by @brettdavies in [#150](https://github.com/brettdavies/dotfiles/pull/150)
- Global gitignore ignores `.pytest_cache/`. by @brettdavies in [#155](https://github.com/brettdavies/dotfiles/pull/155)

### Fixed

- Stop tracking qmd's machine-specific `index.yml` as a stow symlink, which left a permanent dirty working tree on macOS. Collections config now deploys from a per-platform template. by @brettdavies in [#133](https://github.com/brettdavies/dotfiles/pull/133)
- Put Homebrew's Ruby ahead of macOS system Ruby 2.6 on PATH so Bundler satisfies the supply-chain cooldown policy (`>= 4.0.13`). by @brettdavies in [#134](https://github.com/brettdavies/dotfiles/pull/134)
- Fix a Ruby PATH glob that aborted zsh shell startup on hosts with keg-only Homebrew Ruby but no gem binstub directory. by @brettdavies in [#135](https://github.com/brettdavies/dotfiles/pull/135)
- The `svc:ollama` Tailscale service now reaches Ollama from other tailnet nodes. A loopback Caddy proxy rewrites the `Host` header so Ollama's DNS-rebinding check accepts the served request, while Ollama stays bound to loopback only. by @brettdavies in [#139](https://github.com/brettdavies/dotfiles/pull/139)
- Fix `bundle`/`ruby` resolving to macOS system Ruby in login shells by re-asserting keg-only Homebrew Ruby in `~/.zprofile` after `path_helper`. by @brettdavies in [#140](https://github.com/brettdavies/dotfiles/pull/140)
- Stop the `stow-deploy` integration tests from hijacking the live `~` deployment when run from a worktree or second clone (e.g. the pre-push hook inside a worktree). by @brettdavies in [#141](https://github.com/brettdavies/dotfiles/pull/141)
- Stop the changelog / sync / pre-push bats fixtures from mutating the real repo (identity config + stray commits/branches) when their `cd` to a temp dir fails. by @brettdavies in [#142](https://github.com/brettdavies/dotfiles/pull/142)
- Fix `bundle` resolving to macOS system Ruby (Bundler 1.17.2) in bash, cron, and non-login shells; keg-only Homebrew Ruby is now forced ahead of `/usr/bin` so Bundler meets the supply-chain cooldown floor. by @brettdavies in [#151](https://github.com/brettdavies/dotfiles/pull/151)
- Fix `bundle` and `ruby` resolving to macOS system Ruby (Bundler 1.17.2) inside the Claude Code Bash tool; keg-only Homebrew Ruby is now placed ahead of `/usr/bin` so Bundler meets the supply-chain cooldown floor. by @brettdavies in [#154](https://github.com/brettdavies/dotfiles/pull/154)
- `stow-deploy` no longer leaves systemd `--user` timers (`qmd-embed`/`qmd-update`/`qmd-cleanup`) in a failed, unscheduled state after a re-deploy. The deploy now reloads the user manager and restarts the timer units it ships, so a restow can't silently kill the schedule. by @brettdavies in [#157](https://github.com/brettdavies/dotfiles/pull/157)
- `qmd-embed.service` now pins the CUDA GPU backend (`NODE_LLAMA_CPP_GPU=cuda`), so scheduled embedding runs on the GPU instead of silently falling back to CPU through node-llama-cpp's Vulkan prebuilt. by @brettdavies in [#159](https://github.com/brettdavies/dotfiles/pull/159)
- `qmd-embed` caps per-batch work (`--max-docs-per-batch 50 --max-batch-mb 10`) so GPU embedding stays within the VRAM the unit frees, avoiding ggml/CUDA aborts on the shared low-VRAM box.

### Documentation

- Document the one-time Bundler install for the cooldown policy in `BOOTSTRAP.md`. by @brettdavies in [#134](https://github.com/brettdavies/dotfiles/pull/134)
- BOOTSTRAP.md gains a Linux Server Setup section documenting the serve script and the one-time service-host approval step in the admin console. by @brettdavies in [#136](https://github.com/brettdavies/dotfiles/pull/136)
- Add a `CONCEPTS.md` entry defining the "gbrain thin client" host role. by @brettdavies in [#150](https://github.com/brettdavies/dotfiles/pull/150)
- Extend the present-state / no-temporal-narration policy to in-repo prose docs (READMEs, docs, specs, runbooks, plans), with an exception for designated change records (decision-logs, `CHANGELOG`/`RELEASES`, migration records). by @brettdavies in [#153](https://github.com/brettdavies/dotfiles/pull/153)
- Rewrite README to match the current repo: all 34 stow packages (adds caddy, ollama), all 21 shell fragments, the bats.yml workflow with corrected triggers, and the layout tree. by @brettdavies in [#155](https://github.com/brettdavies/dotfiles/pull/155)
- Add Philosophy and Engineering Practices sections to PROJECT.md and refresh its package and fragment inventory.
- Define the shell config chain and bare launcher in CONCEPTS.md.
- Remove backburnered dotfiles-cli references from AGENTS.md, PROJECT.md, and scripts/stow-deploy.
- Restructure `RELEASES.md` into a runbook that cross-links its companions and folds the four post-tag checks into the Tagging section. by @brettdavies in [#156](https://github.com/brettdavies/dotfiles/pull/156)
- Add `RELEASES-RATIONALE.md` documenting the why behind the branching model, PR conventions, triple-diff verification, CHANGELOG generation, CI-side CalVer tagging, and the surgical backport.
- Add `RELEASES-PREFLIGHT.md`, a config-only pre-cut checklist covering repo health, changelog completeness, cross-platform deploy sanity, release mechanics, and the prose floor.

**Full Changelog**: [2026.06.16...2026.06.26](https://github.com/brettdavies/dotfiles/compare/2026.06.16...2026.06.26)

## [2026.06.16]

### Added

- Export `TMUXINATOR_CONFIG` from `config/shell/tmuxinator.sh` so tmuxinator reads and writes the stow source directly,
  no backport step. by @brettdavies in [#109](https://github.com/brettdavies/dotfiles/pull/109)
- Six tmuxinator templates land in the stow package: `birdskill`, `brettdavies`, `homebrew`, `qmd`, `ssite`, `xrskill`.
- `@`-import of `git-and-github.md` in global CLAUDE.md so the git/GitHub workflow rules load in every Claude Code
  session. by @brettdavies in [#111](https://github.com/brettdavies/dotfiles/pull/111)
- `anc-dev` SSH tunnel now forwards the Wrangler dev range, dev registry, Worker inspector, and common dev ports
  (3000/5173/8080). by @brettdavies in [#112](https://github.com/brettdavies/dotfiles/pull/112)
- Supply-chain exception documenting `@main` pins for brettdavies-owned reusable workflows.
- `stow/ollama/` package containing the systemd override drop-in, deploy runbook, and `.stow-local-ignore` exclusion
  list. by @brettdavies in [#113](https://github.com/brettdavies/dotfiles/pull/113)
- `docs/solutions/**` to the markdownlint ignore list. Consumed by every brettdavies repo that copies this template via
  the `github-repo-setup` bootstrap procedure. by @brettdavies in
  [#114](https://github.com/brettdavies/dotfiles/pull/114)
- Adopt the official Codex self-installer (`curl -fsSL https://chatgpt.com/codex/install.sh | sh`) as the supported
  install path; deploys to `~/.local/bin/codex` with `codex update` for self-updating. by @brettdavies in
  [#115](https://github.com/brettdavies/dotfiles/pull/115)
- Add `~/.codex/AGENTS.md` (stowed) as a cross-package symlink to `~/.claude/CLAUDE.md` so codex picks up the same
  global agent rules as Claude Code.
- Add the `gbrain` MCP server to codex via `mcp_servers.gbrain`, mirroring the Claude config.
- Define `Cross-package symlink` in `CONCEPTS.md` so future docs and PRs can cite the pattern without redefinition. by
  @brettdavies in [#116](https://github.com/brettdavies/dotfiles/pull/116)
- `tmux-prune-orphans.timer` systemd user timer (fires at 02:15 local) that sweeps orphan tmux clients whose controlling
  terminal died. by @brettdavies in [#117](https://github.com/brettdavies/dotfiles/pull/117)
- `client-detached` hook in `tmux.conf` invoking the same prune script on every client disconnect.
- New `tools-atime` script under `scripts/tools-atime/` that ranks installed CLI tools across brew, uv, cargo, bun, and
  caches by last-used time and disk footprint. by @brettdavies in
  [#119](https://github.com/brettdavies/dotfiles/pull/119)
- `--inspect <target>` drill-down for `uv-cache`, `bun-cache`, `brew/<formula>`, `uv/<tool>`, `cargo/<crate>`, and
  `bun/<pkg>`. uv-cache reports TOTAL and FREEABLE per archive so the user sees honest disk-reclaim potential.
- `--reclaim` guided interactive cleanup mode that walks top reclaim candidates, prompts per row with a manager-specific
  action menu, and dispatches to the right PM subcommand. Dry-run by default; `--apply` executes.
- Auto-loaded `## Voice notes` section in global `CLAUDE.md` pointing the agent at
  `~/dev/brettdavies/brettdavies/.context/voice.md` for drafting prose in Brett's voice, with an explicit register split
  (heavy on conversational surfaces, light on technical artifacts). by @brettdavies in
  [#120](https://github.com/brettdavies/dotfiles/pull/120)
- Voice-match instruction paired with `/unslop` in step 2 of the "Authoring GitHub correspondence" workflow in
  `guides/git-and-github.md`, so deterministic scrubbing and voice-matching happen in the same pass.
- Stow package `gbrain`: systemd user units for `gbrain sync` (every 15m) and `gbrain dream` (nightly 02:00),
  Linux-only. by @brettdavies in [#121](https://github.com/brettdavies/dotfiles/pull/121)
- Stow package `codex-proxy`: oneshot systemd user unit that brings up the docker-compose codex-proxy stack so paid LLM
  traffic bills against corp ChatGPT credits, Linux-only.
- `LITELLM_API_KEY` env var exported from `stow/secrets/dot-secrets`, sourced at shell init from the `secrets-dev`
  1Password vault.
- `LITELLM_BASE_URL` env var (`http://localhost:8080/v1`) exported from `config/shell/litellm.sh`.
- `stow/codex/dot-codex/config.toml` is git-crypt encrypted at rest. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- Trust entries in codex config for `~` and `~/dotfiles`.
- New `claude-code-archive` systemd timer (every 30 min) that converts Claude Code session jsonl to redacted markdown
  under `~/.gbrain/transcripts/claude-code/`. Idempotent and corpus-permanent; survives Claude Code's 30-day eviction
  window. by @brettdavies in [#123](https://github.com/brettdavies/dotfiles/pull/123)
- New `claude-code-sessions` qmd collection, default-excluded from `qmd query` results. Reach raw transcripts with `qmd
  query -c claude-code-sessions "<phrase>"`.
- New `claude-code-synthesize-sweep.sh` script for hand-rolled `gbrain dream --phase synthesize` backfill over the
  corpus. Ships ready; the user invokes manually with cost-monitoring via the existing
  `~/.gbrain/audit/dream-budget-*.jsonl` ledger. `--dry-run` and `-h/--help` are safe no-cost paths.
- New `~/.config/qmd/index.yml` adopted into stow management (`stow/qmd/dot-config/qmd/`), where it was previously a
  plain unversioned file.
- New `subagent-to-md.py` converter for the subagent jsonl shape that `cc2md` doesn't understand (different fields:
  `agentId`, `parentUuid`, `entrypoint`). Output mirrors cc2md's markdown so the corpus stays uniform for qmd and
  synthesize. by @brettdavies in [#124](https://github.com/brettdavies/dotfiles/pull/124)
- `claude-code-archive.sh` now walks `~/.claude/projects/**/subagents/agent-*.jsonl` in addition to cc2md's top-level
  session list. Brings the corpus to ~1156 transcripts (was ~256).
- New SessionEnd hook `~/.claude/claude-code-archive.sh` fires the archive on session close. Defensive schema: tries
  `.transcript_path`, falls back to `.session_id` filesystem walk. Fire-and-forget, always exits 0.
- `stow/gbrain/dot-gbrain/config.json` (git-crypt encrypted) and `stow/gbrain/dot-gbrain/preferences.json` (plain).
  `scripts/stow-deploy gbrain` symlinks them to `~/.gbrain/`. by @brettdavies in
  [#126](https://github.com/brettdavies/dotfiles/pull/126)
- uv install-time malware check: every sync queries OSV for known-malware advisories against the locked resolution and
  aborts before a matched package's code runs. Enabled when uv >= 0.11.16 is installed; bypass a single run with
  `UV_MALWARE_CHECK=0`. by @brettdavies in [#127](https://github.com/brettdavies/dotfiles/pull/127)
- `scripts/sync-dev-after-release.sh`: post-release backport that surgically copies `CHANGELOG.md` from `origin/main`
  and opens a PR to `dev`, so dev's changelog stops drifting behind released history. CalVer-validated
  (`YYYY.MM.DD[.N]`), idempotent, with preflight guards on tag existence, main reachability, and GitHub Release publish
  state. by @brettdavies in [#128](https://github.com/brettdavies/dotfiles/pull/128)
- `scripts/generate-changelog.py`: vendored git-cliff + PR-body changelog generator with CalVer release-branch detection
  and a `--print-tag` helper.

### Changed

- Rename `homebrewcore.yml` to `hbcore.yml` and `homebrewtap.yml` to `hbtap.yml`. Drop standalone `homebrew.yml`. by
  @brettdavies in [#109](https://github.com/brettdavies/dotfiles/pull/109)
- Humanize every `name:` field (`ANC CLI`, `HB Core`, `Agent Skills`, etc.).
- CLAUDE.md preamble calls out `git-and-github.md` as the one auto-loaded guide. by @brettdavies in
  [#111](https://github.com/brettdavies/dotfiles/pull/111)
- Resolution-time cooldown section documents per-tool native support (Bundler, uv, pip, npm, pnpm, yarn, bun) and tools
  without it (cargo, Homebrew, Go modules), pointing at `config/shell/supply-chain.sh`. by @brettdavies in
  [#112](https://github.com/brettdavies/dotfiles/pull/112)
- `docs/solutions/` symlink recreate command uses an absolute `$HOME` path for portability across repo depths.
- ollama systemd unit binds to `127.0.0.1:11434` (loopback only) instead of `0.0.0.0:11434` (all interfaces). LAN
  clients and tailnet peers can no longer reach the raw API by IP; intentional reach paths are loopback, the
  `svc:ollama` Tailscale Serve service, and a per-stack docker socat sidecar. by @brettdavies in
  [#113](https://github.com/brettdavies/dotfiles/pull/113)
- Canonical version bumped `2026.04.15` to `2026.06.09`. by @brettdavies in
  [#114](https://github.com/brettdavies/dotfiles/pull/114)
- Expand `~/.codex/config.toml` with `sandbox_mode = "workspace-write"`, `approval_policy = "on-request"`,
  `model_reasoning_summary = "auto"`, `web_search = "live"`, and `features.memories = true`. by @brettdavies in
  [#115](https://github.com/brettdavies/dotfiles/pull/115)
- Negate the global `~/.config/git/ignore` block on `AGENTS.md` for the single stow source path
  `stow/codex/dot-codex/AGENTS.md` so the stowed agent rules can be committed.
- Ollama service now keeps up to 4 models hot in VRAM. Reduces evict-and-reload thrash when routing across embedding,
  chat, and codegen models in quick succession. by @brettdavies in
  [#118](https://github.com/brettdavies/dotfiles/pull/118)
- `.claude/settings.local.json` allowlists `Bash(gbrain *)` and the gbrain MCP read-side tools (`whoami`,
  `get_brain_identity`, `get_stats`, `list_jobs`) so headless cycles don't prompt. by @brettdavies in
  [#121](https://github.com/brettdavies/dotfiles/pull/121)
- `stow/codex/dot-codex/config.toml` trusts `~/gbrain` so the codex CLI runs unattended for headless dream cycles.
- gbrain allowlist (`Bash(gbrain *)` and four `mcp__gbrain__*` MCP entries) moved from project-local
  `.claude/settings.local.json` to user-global `~/.claude/settings.json`. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- `gbrain` now reads `dream.synthesize.session_corpus_dir = ~/.gbrain/transcripts/claude-code/`. Nightly
  `gbrain-dream.timer` picks up new transcripts automatically (12h synth cooldown still applies on the corpus-scan
  path). by @brettdavies in [#123](https://github.com/brettdavies/dotfiles/pull/123)
- `emit_discovered` audit event now carries a `source` field (`top_level` or `subagents`) so the two sweep passes can be
  counted separately without re-derivation. by @brettdavies in [#124](https://github.com/brettdavies/dotfiles/pull/124)
- Pre-push hook now skips shellcheck + bats when every changed file in the push is `.md`. git-lfs still runs in all
  cases. by @brettdavies in [#125](https://github.com/brettdavies/dotfiles/pull/125)

### Fixed

- Align `on_project_first_start` resize-pane targets with each project's `name:` field, including quoting for names that
  contain spaces. Corrects both the new renames and pre-existing copy-paste targets that pointed at the wrong session.
  by @brettdavies in [#109](https://github.com/brettdavies/dotfiles/pull/109)
- Removed plaintext `OPENAI_API_KEY` literal from `stow/secrets/dot-secrets`. git-crypt protects the file at rest, but
  the inline export was still a leak path for anyone with the git-crypt key. Slot is preserved as a commented
  placeholder so callsites that previously read `$OPENAI_API_KEY` migrate to `$LITELLM_API_KEY` against the local proxy.
  by @brettdavies in [#121](https://github.com/brettdavies/dotfiles/pull/121)
- Shell startup tests in `tests/shell-config.bats` no longer fail. Interactive zsh/bash and non-interactive zsh are back
  under their respective 500ms/200ms budgets. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- Release runbook pointed at `~/.claude/skills/rust-tool-release/scripts/generate-changelog.sh`, which no longer exists;
  the changelog step was unrunnable as written. by @brettdavies in
  [#128](https://github.com/brettdavies/dotfiles/pull/128)

### Documentation

- Global PR template comment under `## Changelog` names `generate-changelog.py` as the script that parses the
  categorized bullets at release time. by @brettdavies in [#110](https://github.com/brettdavies/dotfiles/pull/110)
- `OLLAMA_MAX_LOADED_MODELS=4` comment expanded with VRAM math and eviction semantics. by @brettdavies in
  [#122](https://github.com/brettdavies/dotfiles/pull/122)
- `RELEASES.md` now documents the post-release backport-to-dev step and drops the stale "dev is untouched" claim. by
  @brettdavies in [#128](https://github.com/brettdavies/dotfiles/pull/128)

**Full Changelog**: [2026.06.03...2026.06.16](https://github.com/brettdavies/dotfiles/compare/2026.06.03...2026.06.16)

## [2026.06.03]

### Added

- Cross-platform `stow/qmd` package: stowing `qmd` now works on both macOS and Linux with the right backend dispatched
  per OS. by @brettdavies in [#87](https://github.com/brettdavies/dotfiles/pull/87)
- `STOW_FLAGS+=(--ignore='\.DS_Store$')` in `scripts/stow-deploy` (always): suppresses macOS Finder turds across every
  package on both OSes.
- `STOW_FLAGS+=(--ignore='\.(service|timer)$')` in `scripts/stow-deploy` (macOS only): skips Linux systemd unit files
  that share packages with cross-platform content.
- Per-platform "read PDF" opener for selectable, searchable PDF text. Pressing `o` on a PDF opens Preview.app on macOS
  or `pdftotext` extracted into micro on Linux. by @brettdavies in
  [#89](https://github.com/brettdavies/dotfiles/pull/89)
- `y` shell wrapper (bash + zsh) that cds the parent shell to yazi's last directory on quit. Adopted in all 16
  tmuxinator session configs and the `tmux-new-session` template, with a silent fallback to plain `yazi`.
- git.yazi plugin with plain-letter status signs (M / A / D / U / ? / !) as a linemode column, computed via two
  prepend_fetchers in yazi.toml and registered in a new `init.lua`.
- Brewfile entries for `yazi`, `glow`, `poppler`, `resvg`, `imagemagick`, and `sevenzip` so `brew bundle` provisions a
  complete yazi preview pipeline on a fresh machine: text extraction, markdown rendering, SVG rasterization,
  AVIF/HEIC/JXL decoding, font sample rendering, and archive contents listing.
- `defuddle` to the Brewfile under a new web-content-extraction comment block. Fresh `brew bundle` machines now
  provision defuddle on PATH with zero per-call resolve cost. by @brettdavies in
  [#90](https://github.com/brettdavies/dotfiles/pull/90)
- `Bash(defuddle:*)` allow-list entry on the caam streams profile alongside the existing `Bash(bunx defuddle:*)`
  fallback.
- New SSH host entry that tunnels `localhost:8787` to a remote wrangler dev server via Tailscale. `ExitOnForwardFailure
  yes` makes a local port collision fail loudly instead of silently dropping into a shell with no tunnel. by
  @brettdavies in [#93](https://github.com/brettdavies/dotfiles/pull/93)
- New `uuidv7` CLI helper at `~/.local/bin/uuidv7` (three-line `python3.14` script around `uuid.uuid7()`) for generating
  time-ordered, collision-proof IDs for tmp-file naming and similar one-off needs. by @brettdavies in
  [#94](https://github.com/brettdavies/dotfiles/pull/94)
- `lt_check` shell function at `~/dotfiles/config/shell/languagetool.sh`. Parallel grammar-check workhorse with category
  whitelist, 10-rule baseline denylist, byte-offset-to-line approximation, and graceful skip when LanguageTool is
  unreachable. Exit codes: 0 (clean) / 1 (blocking) / 2 (unreachable, stderr notice) / 3 (usage). by @brettdavies in
  [#95](https://github.com/brettdavies/dotfiles/pull/95)
- `lt_info`, `lt_languages`, `lt_rules`, `lt_categories` query helpers for inspecting the LT server and the active
  override surface.
- `LT_DENY_RULES_BASELINE` constant for repo-specific extensions:
  `LT_DENY_RULES="${LT_DENY_RULES_BASELINE}|EXTRA_RULE"`.
- New `config/shell/build-flags.sh` and `config/shell/run-flags.sh` that set `-march=native -O3 -pipe` CFLAGS/CXXFLAGS
  plus runtime env defaults for local compilation on Linux hosts. macOS toolchains skip these (handled by Xcode/brew).
  by @brettdavies in [#98](https://github.com/brettdavies/dotfiles/pull/98)
- New `scripts/qmd-llama-rebuild.sh` to rebuild `node-llama-cpp` from source with the host's CPU/GPU flags, plus a
  runbook callout pointing at it.
- Allow `curl -sS http://127.0.0.1:7832/health` in the local Claude allowlist for qmd-serve liveness probes. by
  @brettdavies in [#99](https://github.com/brettdavies/dotfiles/pull/99)
- `scripts/playwright-deps-deploy.sh`: provisions browser launch on Linux. Always deploys the Chromium AppArmor userns
  profile plus a boot unit that survives reboots, and installs heavy Chromium/WebKit system libraries only when
  explicitly requested. by @brettdavies in [#100](https://github.com/brettdavies/dotfiles/pull/100)
- `apparmor-playwright.service`: boot unit that reloads the Chromium userns profile at boot, because Ubuntu's
  `apparmor.service` is skipped on minimized server images.
- `UserPromptSubmit` hook (`solutions-prefetch.sh`): on debugging-flavored prompts, reminds you to query
  `docs/solutions` before investigating. Reminder-only, fail-open, no qmd call. by @brettdavies in
  [#101](https://github.com/brettdavies/dotfiles/pull/101)
- Grant Claude Code Read/Edit/Write on `/tmp/**` via `permissions.additionalDirectories`, unblocking the collision-proof
  `/tmp/` commit/PR/release body workflow without per-call permission prompts. by @brettdavies in
  [#103](https://github.com/brettdavies/dotfiles/pull/103)
- Add `op-skill-nudge.sh` PreToolUse/Bash hook so secret-handling commands trigger the 1Password skill helper before
  execution.
- New "Resolution-time aging window (cooldown)" section in `supply-chain-pinning.md` covering Bundler 4.0.13+
  `cooldown`, uv `exclude-newer`, pnpm `minimumReleaseAge`, and the per-tool emergency-bypass flags. Notes that npm and
  bun have no native equivalent. by @brettdavies in [#104](https://github.com/brettdavies/dotfiles/pull/104)
- `CONCEPTS.md` at repo root: 9-entry glossary in 4 clusters (Hosts, Packages, System configuration, Policies). Names
  the project-specific terms a new engineer needs defined to follow conversations, tickets, or code in this repo. by
  @brettdavies in [#105](https://github.com/brettdavies/dotfiles/pull/105)
- AGENTS.md `## Reference` section: one-line entry pointing at `CONCEPTS.md` so agents and collaborators discover the
  shared vocabulary alongside `docs/solutions/`.

### Changed

- `stow/qmd/dot-local/bin/qmd` is now an OS-aware dispatcher (`case "$(uname -s)"` → `~/dev/qmd/qmd` on Linux,
  `~/.cache/bun/bin/qmd` on macOS). by @brettdavies in [#87](https://github.com/brettdavies/dotfiles/pull/87)
- Linux-only qmd artifacts (7 systemd `.service`/`.timer` units + the `qmd-ollama-unload-all` helper) moved from
  `stow/qmd/` into `stow/local/`.
- `qmd` removed from the Linux-only skip case in `scripts/stow-deploy` (the package is now cross-platform).
- WebFetch-intercept hook (`stow/claude/dot-claude/defuddle-webfetch.sh`) redirects to `defuddle parse <url>` instead of
  `bunx defuddle parse <url>`. by @brettdavies in [#90](https://github.com/brettdavies/dotfiles/pull/90)
- `gh` wrapper's pr-merge-to-main block: second line now reads "Ask the human to perform the merge; the PR body is used
  as the squash commit message" (was: "Please provide a ready-to-paste squash merge commit message").
- Rename `QMD_SERVER` env var to `QMD_REMOTE_URL` and `qmd serve --sequential` flag to `qmd serve --low-vram`, matching
  the upstream qmd fork. Anyone with a manual `export QMD_SERVER=…` elsewhere needs to switch to `QMD_REMOTE_URL`. by
  @brettdavies in [#92](https://github.com/brettdavies/dotfiles/pull/92)
- GitHub-correspondence workflow in CLAUDE.md now requires collision-proof tmp-file names:
  `/tmp/pr-body-<repo>.<branch>.md` for PR-scoped artifacts and `/tmp/<kind>-$(uuidv7).md` for everything else. Step 3
  also now requires `trash <path>` after a successful `gh` or `git commit` call. by @brettdavies in
  [#94](https://github.com/brettdavies/dotfiles/pull/94)
- `stow/claude/dot-claude/heredoc-pr-guard.sh` deny reasons now point at `~/.claude/CLAUDE.md § "Authoring GitHub
  correspondence: /tmp/ + --body-file + /unslop"` and show the canonical filename per artifact class
  (`/tmp/pr-body-<repo>.<branch>.md`, `/tmp/commit-msg-$(uuidv7).md`, etc.). by @brettdavies in
  [#95](https://github.com/brettdavies/dotfiles/pull/95)
- `stow/local/dot-config/systemd/user/qmd-serve.service` now sets `Environment=NODE_LLAMA_CPP_GPU=cuda`, pinning the
  backend so the daemon survives NVIDIA driver branch upgrades. by @brettdavies in
  [#98](https://github.com/brettdavies/dotfiles/pull/98)
- Tighten PR body rules: summaries describe the net diff vs the base branch; triple-diff stats, leak-check output,
  patch-id counts, pre-push gate results, CI status, prose-scrub findings, and exclusion rationale stay out of the body.
  by @brettdavies in [#99](https://github.com/brettdavies/dotfiles/pull/99)
- CLAUDE.md "Query solutions first" rule now explicitly covers `/investigate` and other gstack debugging skills, and
  extends the qmd-learnings-researcher dispatch to them. by @brettdavies in
  [#101](https://github.com/brettdavies/dotfiles/pull/101)
- Restructure the global `CLAUDE.md` into a progressive-disclosure layout: a slim always-on index plus seven on-demand
  topic guides under `~/.claude/guides/` (cli-tools, code-comments, git-and-github, local-only-files,
  supply-chain-pinning, workflows-and-skills, writing-safety). Reduces always-on context while preserving every rule;
  detail loads with Read only when the relevant task runs. by @brettdavies in
  [#102](https://github.com/brettdavies/dotfiles/pull/102)
- Strengthen CI watch policy (`CLAUDE.md` + `ci-watch-prompt.sh` header): a completed watcher is not a green watcher.
  After every completion notification, re-query `gh pr view --json statusCheckRollup,mergeStateStatus` (or `gh run view
  --json conclusion`) and assert every conclusion is `SUCCESS`. by @brettdavies in
  [#103](https://github.com/brettdavies/dotfiles/pull/103)
- Expand chain-discovery rule to cover cross-repo `repository_dispatch` flows (e.g. agentnative-cli release →
  brettdavies/homebrew-tap → callback to agentnative-cli finalize-release). Both repos must be watched and re-queried
  until they quiesce.
- Pin `autoUpdatesChannel: "stable"`, `enableWorkflows: false`, `workflowKeywordTriggerEnabled: false`; bump
  `effortLevel` from `high` to `xhigh`.
- Relocate `skillOverrides` from the trailing block to immediately after `permissions` (content unchanged).

### Fixed

- The PostToolUse `ci-watch-prompt.sh` hook now retries `gh run list` up to 5 times with a 2 s delay between attempts.
  Previously the hook queried once with a 2 s lead-in, which lost the race against GitHub's API surfacing
  newly-triggered runs (especially after `gh pr create`) and silently exited without emitting the watch reminder. by
  @brettdavies in [#87](https://github.com/brettdavies/dotfiles/pull/87)
- 3-pane tmuxinator sessions (`mux start <name>` / `tmuxinator start <name>`) now resize to the documented 33% yazi /
  67% shell / 33% lazygit layout when launched from a bare shell, not only from inside an existing tmux session. by
  @brettdavies in [#88](https://github.com/brettdavies/dotfiles/pull/88)
- Yazi 26.x no longer prints TOML parse errors at startup for the stowed yazi, theme, and keymap configs. Editor schema
  tooling continues to work via the Taplo `#:schema` directive. by @brettdavies in
  [#89](https://github.com/brettdavies/dotfiles/pull/89)
- Yazi image preview (PNG, JPEG, etc.) now renders inside tmux on macOS with Ghostty. Previously the panel was blank
  because tmux stripped the Kitty graphics escape sequences yazi emits.
- Yazi SVG, AVIF / HEIC / JXL, font, and archive previews now render via the corresponding built-in previewers plus
  their newly-tracked external tools.
- `y()` yazi wrapper rejects malformed `--cwd-file` output via an `[ -d "$cwd" ]` guard, matching yazi's upstream
  canonical pattern. Function doc-comment now states the actual yazi defaults (`q` writes cwd-file; `Q` does not). by
  @brettdavies in [#90](https://github.com/brettdavies/dotfiles/pull/90)
- Stop emitting `npm warn Unknown env config "minimum-release-age"` on every `npm` invocation. The pnpm-only env var is
  now exported only when pnpm is on PATH, and the npm-only env var is gated on `npm --version` being 11.10.0 or newer.
  by @brettdavies in [#91](https://github.com/brettdavies/dotfiles/pull/91)
- `qmd-serve` queries no longer fall back to slow Vulkan inference. Verified end-to-end after a 570 → 580 driver swap on
  the dev box: expand query 25.3s → 2.7s, rerank 40 chunks 31.1s → 1.9s, total cold query 114s → 12.4s (≈9-16x). by
  @brettdavies in [#98](https://github.com/brettdavies/dotfiles/pull/98)

### Documentation

- New: `docs/solutions/architecture-patterns/cross-platform-stow-package-gating-2026-05-17.md` documenting the
  package-level vs file-level OS gating decision framework, the file-extension-regex rationale (stow 2.4.1's `--ignore`
  matches file basenames not directory names), and adjacent gotchas (bun global cache purge silently uninstalls
  binaries; macOS Finder `.DS_Store` proliferation). by @brettdavies in
  [#87](https://github.com/brettdavies/dotfiles/pull/87)
- Refreshed: `docs/solutions/deployment-issues/stow-conflict-resolution-wrapper.md` and
  `docs/solutions/architecture-patterns/stow-dotfiles-architecture-and-failure-modes-2026-04-20.md` to incorporate the
  new gating tier in their failure-mode maps, hardened-defaults lists, and reference sections.
- `AGENTS.md` Reference section gains a link to the new architecture-patterns doc.
- New "Code Comments" policy section in CLAUDE.md codifying the WHY-only standard, hard bans, allowed external refs, and
  language-specific overrides for public surface area. by @brettdavies in
  [#94](https://github.com/brettdavies/dotfiles/pull/94)
- New paragraph in `AGENTS.md § Shell Config Chain` titled "External scripts that need a helper must source it
  explicitly". It documents that non-login bash scripts (git hooks, CI, `bash scripts/foo.sh`) read no startup files, so
  they must source helpers with the `DOTFILES_SHELL_DIR` fallback pattern. by @brettdavies in
  [#95](https://github.com/brettdavies/dotfiles/pull/95)
- Add explicit anti-pattern note to `CLAUDE.md`: don't write the tmp commit/PR-body path to a sidecar file and re-read
  it later. Re-paste the literal path in each Bash call, or recompute it deterministically. Rule applies to any sidecar
  filename. Picking a different name doesn't make it safe. by @brettdavies in
  [#96](https://github.com/brettdavies/dotfiles/pull/96)
- `docs/runbooks/headless-gpu-server-nvidia-driver.md` gains a DKMS-migration section and an A.6 post-migration GPU
  consumer verification step, capturing what was learned during the diagnostic cycle. by @brettdavies in
  [#98](https://github.com/brettdavies/dotfiles/pull/98)
- Runbook for diagnosing `browse` and Playwright browser-launch failures on Linux: sandbox `Permission denied` (profile
  not loaded) versus missing WebKit dependencies. by @brettdavies in
  [#100](https://github.com/brettdavies/dotfiles/pull/100)
- Add `docs/progressive-disclosure-evals.md`: a six-eval harness verifying fetch-on-demand and prohibition-floor
  behavior, with a validity gate noting the suite must run from a fresh `claude` process. by @brettdavies in
  [#102](https://github.com/brettdavies/dotfiles/pull/102)
- `RELEASES.md § PRs and changelog generation`: add the rule that release PR bodies use one logical line per bullet and
  paragraph (GitHub soft-wraps), and that bullets copied from `CHANGELOG.md` must be unwrapped first because the source
  content is pre-wrapped at the repo's MD013 limit. by @brettdavies in
  [#107](https://github.com/brettdavies/dotfiles/pull/107)

**Full Changelog**: [2026.05.16...2026.06.03](https://github.com/brettdavies/dotfiles/compare/2026.05.16...2026.06.03)

## [2026.05.16]

### Added

- Rectangle window manager (macOS): keyboard hotkeys for snap/resize, size-cycling on repeated arrow presses, flush
  borders, no margins. Run `scripts/rectangle-defaults.sh` after first-launch Accessibility grant. by @brettdavies in
  [#70](https://github.com/brettdavies/dotfiles/pull/70)
- ⌃⌥C triggers `centerHalf` with cycling (1/2 → 2/3 → 1/3 centered vertical column on repeated presses), replacing the
  default translate-only `center` action.
- macOS LaunchAgents for the qmd knowledge-base index: `com.user.qmd-update`, `com.user.qmd-embed`, and
  `com.user.qmd-cleanup`. Schedule, logs, and bootstrap match the Linux systemd setup so the laptop and server keep
  their indexes maintained the same way. by @brettdavies in [#71](https://github.com/brettdavies/dotfiles/pull/71)
- `scripts/qmd-launchd-enable.sh` idempotent bootstrap script (run once on macOS after `stow-deploy --all`).
- Install `rtk` via brew so the PreToolUse Bash hook from PR #62 (rewrites `git`, `cargo`, `gh`, `pytest`, `docker`, …
  through `rtk` for 60-90% token compression) actually runs on macOS. Linux bottles ship in the same formula, so this
  benefits headless servers too.
- PreToolUse Bash hook (`stow/claude/dot-claude/heredoc-pr-guard.sh`) that blocks heredoc piped into `--body`,
  `--notes`, or `-m` flags on `gh pr`, `gh issue`, `gh release`, and `git commit` commands. Allows every other heredoc
  use. Returns a deny JSON with a message pointing at the correct `--body-file` / `--notes-file` / `--file` workflow. by
  @brettdavies in [#75](https://github.com/brettdavies/dotfiles/pull/75)
- 41-case bats test suite (`tests/heredoc-pr-guard.bats`) covering positive deny cases, negative allow cases, and 13
  red-team adversarial bypass attempts (indent-stripping `<<-EOF`, unusual heredoc markers, extra whitespace, subshell
  wrapping, chained commands, prepended env vars, `--body=value` equals form, quoted markers, request-changes reviews,
  line-continuation backslash, `bash -c` wrapper).
- New section in `stow/claude/dot-claude/CLAUDE.md`: "Personal paths and machine names: relative or generic in all
  written artifacts". Sits directly after the existing "Secrets and identifiers" section (same theme of privacy at the
  echo boundary, distinct category). by @brettdavies in [#77](https://github.com/brettdavies/dotfiles/pull/77)
- pnpm and yarn supply-chain age-gate env vars in `config/shell/supply-chain.sh`, enforcing a 7-day floor on installed
  packages to mirror the existing npm/bun/uv/pip controls. by @brettdavies in
  [#78](https://github.com/brettdavies/dotfiles/pull/78)
- New global ALLOW patterns at `stow/claude/dot-claude/settings.json`: lint/dev tools (actionlint, shellcheck, vale,
  rtk), 1password skill helpers (`~/.claude/skills/1password/scripts/*`), github-repo-setup repo-settings.sh report,
  unslop score.py, user-wide Read paths under `//home/brett/{,dev/,dev/solutions-docs/,.claude/,dotfiles/}**` and
  `//usr/bin/**`, WebFetch domains (github.com, docs.rs, crates.io, raw.githubusercontent.com,
  developers.cloudflare.com, rust-cli.github.io), Skill calls (plan-eng-review, unslop, defuddle), MCP wildcards
  (`mcp__plugin_cloudflare_*`, `mcp__plugin_compound-engineering_context7__*`, `mcp__plugin_context7_context7__*`). by
  @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- New global ASK carveouts: `Bash(gh pr create *)`, `Bash(gh pr edit *)`, `Bash(gh pr merge *)`, `Bash(gh repo create
  *)`, `Bash(op item *)`. These mutate shared state or read 1Password secrets and now prompt despite the broader
  `Bash(gh:*)` and op CLI presence in allow (deny→ask→allow precedence ensures ask wins).
- Tailscale skill enabled in this repo via `skillOverrides.tailscale = "on"` in `.claude/settings.local.json`.
- 23 Bash CLI tools to global ALLOW: bun add/x, defuddle, flatpak list, kill, magick, npm view, ollama list/ps/stop,
  pdfimages, pdftocairo, pgrep, rclone, sha256sum, snap list, trash-list, tsc, ty check, unzip, wrangler. by
  @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)
- 18 skill helper scripts to global ALLOW: 1password (create_item, edit_item, list_tags), bird, clip, docker-engine
  (docker-doctor, journal-tail, sg-docker.sh), gstack (4 entries), hb-verify, rust-new-repo, tailscale, x-api, plus
  ~/.claude/{md-align-tables.py, rust-ci-check.sh}.
- 9 Skill() entries to global ALLOW: browse, clip, ce-sessions, design-review, document-release, impeccable,
  office-hours, pdf-generator, qmd.
- 11 WebFetch domains to global ALLOW: arxiv.org, devcommunity/developer/docs.x.com, docs.brew.sh, docs.nvidia.com,
  gist.github.com, lib.rs, pandoc.org, sqlite.org, users.rust-lang.org.
- 4 Read paths to global ALLOW: ~/.gstack/projects/**, ~/github/**, /etc/systemd/system/**,
  /home/linuxbrew/.linuxbrew/share/bash-completion/completions/**.
- 19 ASK carveouts: killall:*and pkill:* (process-pattern killers; ASK so user can override per call), sg docker *(was
  bypassing the docker:* ASK), 11 wrangler destructive subcommands (delete, secret delete, kv key/namespace delete, r2
  object/bucket delete, d1 delete/execute, hyperdrive/queues/workflows delete), 5 rclone destructive (delete,
  deletefile, purge, sync, bisync --resync). Per the verified deny→ask→allow precedence, these narrow ASK entries
  override the broader Bash(wrangler:*) and Bash(rclone:*) ALLOWs.
- Micro keybinding: Alt-i toggles overwrite mode (separate concern bundled as a passenger commit).
- `snapshots/tailscale/`: encrypted reference snapshot of the tailnet's ACL, services list, and per-host `tailscale
  serve` configs after the Taildrive + Services rollout. Refresh recipe in the snapshot README. by @brettdavies in
  [#84](https://github.com/brettdavies/dotfiles/pull/84)
- `taildrive-mount` and `taildrive-unmount` shell functions (macOS only). `taildrive-mount` calls `osascript -e 'mount
  volume ...'` for each share so Finder's SUID helper handles the `/Volumes` mkdir that direct `mount_webdav` from a
  user shell cannot. The share list lives in `$TAILDRIVE_SHARES`, exported from `~/.secrets` (git-crypt encrypted) so no
  host identifiers land in plaintext in this public repo.

### Changed

- BOOTSTRAP.md "oh-my-zsh" section: removed obsolete macOS/Linux split for plugin install. `brew bundle` handles
  `zsh-autosuggestions`, `zsh-syntax-highlighting`, and `zsh-completions` on both platforms; `.zshrc` sources them
  directly. Only `powerlevel10k` (theme, not plugin) still needs a manual symlink. by @brettdavies in
  [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Normalize `qmd-update.service`'s `Environment="PATH=..."` (quoted) to unquoted `Environment=PATH=...`, matching the
  format used by every other unit. Semantically identical, since quoting only matters when the value contains
  whitespace. by @brettdavies in [#74](https://github.com/brettdavies/dotfiles/pull/74)
- `stow/claude/dot-claude/CLAUDE.md` "Pull Requests" section reorganized as "Authoring GitHub correspondence".
  Three-step workflow now applies to every server-side artifact: author in `/tmp/`, run `/unslop` (mandatory), submit
  via the file-flag variant. The "Heredoc escape rule" backstop is replaced by an explicit "Enforcement" section
  pointing at the new hook. by @brettdavies in [#75](https://github.com/brettdavies/dotfiles/pull/75)
- `stow/claude/dot-claude/settings.json` adds the hook to `PreToolUse.Bash`, running before the `rtk hook claude` entry
  so the deny decision fires before any rewrite.
- The existing Cloudflare-token example in "Secrets and identifiers" referenced an internal hostname in the 1Password
  entry name. Updated to a generic `(<server>)` placeholder, consistent with the new rule. by @brettdavies in
  [#77](https://github.com/brettdavies/dotfiles/pull/77)
- RELEASES.md: PR-body discipline rule. Bodies are user-facing substance only; no workflow recaps, no verification
  artifacts. by @brettdavies in [#79](https://github.com/brettdavies/dotfiles/pull/79)
- `.claude/settings.local.json` allow array alphabetized as a side-effect of the audit script's union pass; same content
  otherwise.
- SSH config now routes the three Tailscale-enabled host aliases via Tailscale SSH by default (port 22, FQDN, node
  identity), with a Match-driven override to LAN sshd when this Mac has a `<lan-subnet>.x` IP. Off-LAN: no SSH key
  needed. On-LAN: direct LAN path retained for speed. by @brettdavies in
  [#80](https://github.com/brettdavies/dotfiles/pull/80)
- One host's previously-inlined `tmux new -A -s main` RemoteCommand was removed. Auto-tmux on SSH connect is now opt-in
  per session, not config-default.
- killall:*moved from DENY to ASK. Reason: user does invoke killall periodically for legitimate process-cleanup;
  outright deny was too strict. ASK preserves the friction without blocking. Bash(kill:*) (PID-targeted, lower risk)
  stays in ALLOW. by @brettdavies in [#83](https://github.com/brettdavies/dotfiles/pull/83)

### Fixed

- Repair PATH ordering on macOS login shells so `/opt/homebrew/bin` and `/opt/homebrew/sbin` precede `/usr/bin` (was
  being clobbered by Apple's `/etc/zprofile` running `path_helper -s` after `.profile` set up PATH). by @brettdavies in
  [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Eliminate PATH duplication on shell startup by adding a sentinel guard to `.zshrc`'s `.profile` re-source (matches the
  pattern in `.bashrc` and `.zshenv`) and dedupe checks to `local-paths.sh` and `lm-studio.sh`.
- Stop oh-my-zsh `plugin not found` warnings by sourcing `zsh-autosuggestions` and `zsh-syntax-highlighting` directly
  from `$HOMEBREW_PREFIX/share/` (Homebrew's documented integration) instead of declaring them in `plugins=(...)` where
  omz's detection fails on brew's layout.
- Add `Environment=PATH=...` to four user systemd units that were relying on inherited PATH or internal full-path
  workarounds. Affects `qmd-cleanup`, `box-bisync`, `obsidian`, and `opendataloader-pdf`. Lets the wrapped scripts find
  brew-installed tools (`rclone`, `git`, coreutils, etc.) without hardcoded `/home/linuxbrew/.linuxbrew/bin/...`
  fallbacks. by @brettdavies in [#74](https://github.com/brettdavies/dotfiles/pull/74)
- bats: `tests/stow-deploy-packages.bats` no longer fails on Linux when asserting explicit-arg expansion through
  `ghostty` (a macOS-only DESKTOP package). by @brettdavies in [#78](https://github.com/brettdavies/dotfiles/pull/78)
- bats: `tests/qmd-serve.bats` assertions for `qmd-update.service` and `qmd-cleanup.service` now match the post-PR-#74
  unit files (Environment=PATH=/home/linuxbrew/.linuxbrew/bin:... for brew tool resolution).
- Removed pre-existing one-off entries from global allow that should never have been promoted (specific tax-document
  copies, pdf-generator scratch builds, Cloudflare-Pages-to-Workers sed renames, claude model probe). 24 entries
  stripped, mostly subsumed by broader wildcards anyway. by @brettdavies in
  [#79](https://github.com/brettdavies/dotfiles/pull/79)
- Stripped 50 redundant entries from `.claude/settings.local.json` and 672 from the other 17
  `~/dev/*/.claude/settings.local.json` files. The latter are gitignored/untracked, so the strips apply on disk in those
  repos without separate commits.
- Three speculative MCP wildcards in `stow/claude/dot-claude/settings.json` replaced with enumerated entries:
  `mcp__plugin_cloudflare_*` becomes 11 entries from the proven cloudflare set (`accounts_list`, `kv_namespaces_list`,
  `r2_buckets_list`, `set_active_account`, `workers_get_worker`, `workers_list`,
  `cloudflare-docs__search_cloudflare_documentation`, `cloudflare-api__execute`, `cloudflare-api__search`,
  `cloudflare-builds__accounts_list`, `cloudflare-observability__accounts_list`);
  `mcp__plugin_compound-engineering_context7__*` and `mcp__plugin_context7_context7__*` become 4 enumerated entries (2
  install paths × 2 tools each). by @brettdavies in [#81](https://github.com/brettdavies/dotfiles/pull/81)
- Stripped 13 redundant entries from `.claude/settings.local.json`: 3 /tmp/test_full.pdf curl probes, 6 macOS
  personal-home Read entries (orphans on Linux), 4 entries subsumed by the new global wildcards (rclone
  listremotes/version, kill %1 covered by kill:*). by @brettdavies in
  [#83](https://github.com/brettdavies/dotfiles/pull/83)
- Stripped ~324 entries across 17 other ~/dev/*/.claude/settings.local.json files (gitignored, on-disk only). Two files
  became empty (brettdavies, dot-github) and were deleted entirely.
- Closed semantic regressions surfaced during the security review: pkill was bypassing the killall deny; sg docker was
  bypassing the docker ASK; broad wrangler:*and rclone:* ALLOWs would have shipped destructive subcommands auto-allowed.

### Documentation

- Updated `~/dev/solutions-docs/best-practices/claude-code-permission-globs-use-colon-not-star-2026-04-20.md` to correct
  the previous claim that `Bash(cmd *)` (space-asterisk) was equivalent-to-dangerous Form A. Per current Claude Code
  docs (verified 2026-05-15), Forms B (space) and C (colon) are equivalent and both safe; only bare-prefix Form A is the
  typosquat surface. Audit regex corrected from `[^:]\*\)` to `[^: ]\*\)`. by @brettdavies in
  [#79](https://github.com/brettdavies/dotfiles/pull/79)
- Added `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` covering cross-list
  precedence (deny → ask → allow), within-list subsumption analysis, strategic carveouts pattern, and the
  promote-and-strip workflow.
- `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` (commit `4f62307` in
  solutions-docs) gains a "Tool pattern coverage (verified behavior)" section recording both findings: MCP wildcards do
  not validate, `Read(~/...)` does. Future audits skip the experiments. by @brettdavies in
  [#81](https://github.com/brettdavies/dotfiles/pull/81)
- No doc changes in this PR. The audit-strategy doc at
  `~/dev/solutions-docs/best-practices/claude-code-permissions-audit-strategy-2026-05-15.md` already covers cross-list
  precedence, subsumption analysis, and tool pattern coverage findings used to drive this audit. by @brettdavies in
  [#83](https://github.com/brettdavies/dotfiles/pull/83)
- Replace specific environment-tied references in tracked docs with generic placeholders and role descriptors, improving
  readability and portability for future contributors. by @brettdavies in
  [#85](https://github.com/brettdavies/dotfiles/pull/85)

### Removed

- Dead SDKMAN init blocks from `stow/zsh/dot-zprofile` and `stow/bash/dot-bash_profile`. SDKMAN is not installed on
  either the development Mac or the headless Linux server. by @brettdavies in
  [#73](https://github.com/brettdavies/dotfiles/pull/73)
- Drop one manual LAN-alias `Host` block from `stow/ssh/dot-ssh/config`. Use the canonical short name from any network:
  Tailscale SSH off-LAN, LAN sshd on the home network via the existing `Match originalhost` override. by @brettdavies in
  [#82](https://github.com/brettdavies/dotfiles/pull/82)

**Full Changelog**: [2026.05.11...2026.05.16](https://github.com/brettdavies/dotfiles/compare/2026.05.11...2026.05.16)

## [2026.05.11]

### Added

- Install `rtk-ai/rtk` `PreToolUse` Bash hook for ~60-90% token compression on supported commands (`git`, `cargo`, `gh`,
  `pytest`, `docker`, etc.). by @brettdavies in [#62](https://github.com/brettdavies/dotfiles/pull/62)
- Document rtk meta commands in global `CLAUDE.md`: `rtk gain` (savings analytics), `rtk discover` (find missed
  compression opportunities), `rtk proxy <cmd>` (run unfiltered for debugging).
- Add `ancsite`, `ancspec`, `ancskill` tmuxinator configs pointing at `~/dev/agentnative-{site,spec,skill}`. by
  @brettdavies in [#63](https://github.com/brettdavies/dotfiles/pull/63)

### Changed

- Rename `agentnative-cli` tmuxinator session to `anc` (project root unchanged: `~/dev/agentnative-cli`). by
  @brettdavies in [#63](https://github.com/brettdavies/dotfiles/pull/63)
- `tmux-new-session` now writes a tmuxinator config under `stow/tmuxinator/dot-config/tmuxinator/<name>.yml` and
  re-stows the package before launching the session, so every session it creates is reproducible and source-controlled.
  Sessions are started via `tmuxinator start` instead of raw `tmux new-session`. by @brettdavies in
  [#67](https://github.com/brettdavies/dotfiles/pull/67)

### Fixed

- Stop auto-formatting files under `/tmp`, `/var/tmp`, and `$TMPDIR` so PR-body drafts and other scratch files paste
  verbatim into downstream forms. by @brettdavies in [#64](https://github.com/brettdavies/dotfiles/pull/64)
- Restore the 3-pane default layout (yazi, shell, lazygit) to every tmuxinator config — sessions started via `mux start
  <name>` now reopen with the expected working layout instead of a single bare pane. by @brettdavies in
  [#66](https://github.com/brettdavies/dotfiles/pull/66)
- Replace deprecated `post:` hook with `on_project_exit:` in every tmuxinator config and in the config template emitted
  by `tmux-new-session`. Sessions still get the 3-pane resize, but `tmuxinator start` no longer prints the deprecation
  warning. by @brettdavies in [#68](https://github.com/brettdavies/dotfiles/pull/68)

### Documentation

- Document the triple-diff verification step in `RELEASES.md` (main→release, release→dev, dev→main + guarded-paths grep
- `git cherry` patch-id sweep) so missed cherry-picks get caught before the release tag goes out instead of after. by
  @brettdavies in [#60](https://github.com/brettdavies/dotfiles/pull/60)
- Document the cliff.toml chore-skip footgun in the `RELEASES.md` review step — generated changelog must be
  cross-checked against PR bodies for cherry-picked PRs whose commit subject starts with a skipped type.
- Add "Prefer `feat`/`fix` over `chore` when the change has any user-observable effect" rule to global CLAUDE.md `##
  Commit Messages` section, with the `cliff.toml` rationale.
- Restructure `RELEASES.md` to consolidate cliff.toml `chore`-skip guidance into a dedicated `### CHANGELOG is
  generated, never hand-written` subsection under `## Releasing dev to main` (mirrors sibling brettdavies repos); trim
  `## PRs and changelog generation` to PR-author-facing content only. by @brettdavies in
  [#61](https://github.com/brettdavies/dotfiles/pull/61)
- Add a `### Tmuxinator Sessions` section to `README.md` documenting the 3-pane layout intent and `tmuxinator start
  <name>` (and the `mux start <name>` shell alias, and the SSH form `ssh <host> -t tmuxinator start <name>`) as the
  preferred launch / connection idiom. Correct the stale "13 projects" count in the stow package row to "16 projects".
  by @brettdavies in [#68](https://github.com/brettdavies/dotfiles/pull/68)

**Full Changelog**: [2026.05.02...2026.05.11](https://github.com/brettdavies/dotfiles/compare/2026.05.02...2026.05.11)

## [2026.05.02]

### Added

- `qmd-cleanup.timer` + `qmd-cleanup.service`: nightly `qmd cleanup` with `RandomizedDelaySec=2h` so fires land in a
  [03:00, 05:00] window. by @brettdavies in [#51](https://github.com/brettdavies/dotfiles/pull/51)
- `qmd-ollama-unload-all` helper: dynamically frees Ollama VRAM only when GPU has less than `MIN_FREE_MIB` (default

1) free, leaving hot pins alone when headroom is sufficient.

- `stow/claude/dot-claude/md-align-tables.py`: GFM table aligner with PEP 723 inline metadata (uv run --script). Reflows
  mixed compact/aligned tables into consistent aligned-pipe style; preserves alignment hints, escaped pipes,
  frontmatter, fenced code, and HTML. by @brettdavies in [#52](https://github.com/brettdavies/dotfiles/pull/52)
- `stow/github/dot-config/github/pull_request_template.md`: `**Renamed:**` field in the `## Files Modified` section so
  rename-style changes get their own bullet category instead of splitting into create+delete or hiding under modified.
- 14 new telemetry opt-outs in `config/shell/telemetry.sh`: Apollo Rover, Astro, AWS CDK, Cloudflare Wrangler, .NET
  Interactive, .NET svcutil, Gemini CLI, Go runtime (1.23+), Hugging Face Hub, Nuxt, Stripe CLI, Supabase, Turborepo,
  Vercel. by @brettdavies in [#55](https://github.com/brettdavies/dotfiles/pull/55)
- Discoverability comment in `config/shell/supply-chain.sh` pointing at `stow/bun/dot-bunfig.toml` so future-me doesn't
  go looking for bun in this file (bun has no env-var equivalent for `minimumReleaseAge`).
- `copy-on-select = clipboard` in `stow/ghostty/dot-config/ghostty/config` so text selected with the mouse is
  auto-copied to the system clipboard (no Cmd+C needed), parity with tmux behavior. by @brettdavies in
  [#56](https://github.com/brettdavies/dotfiles/pull/56)

### Changed

- `stow/claude/dot-claude/auto-format.sh`: new Step 2 invokes `md-align-tables.py` (gated on `command -v uv`) between
  md-wrap and markdownlint; prior Step 2 (markdownlint) renumbered to Step 3. by @brettdavies in
  [#52](https://github.com/brettdavies/dotfiles/pull/52)
- `stow/claude/dot-claude/CLAUDE.md`: five workflow expansions — parallel CE + qmd learnings dispatch (workaround for
  EveryInc/compound-engineering-plugin#655), `.context/handoffs/` filename convention, pre-flight PR template read
  before `gh pr create`, branch-discipline scope refinement (audience, not extension), and two new principle sections
  (long artifacts go to files; system configs go in dotfiles).
- Re-sorted `telemetry.sh` to strict ASCII alphabetical order. Fixes two pre-existing minor disorderings: `Azure SDK`
  was before `Azure Functions Core Tools`, and `Sentry` was before `Segment`. by @brettdavies in
  [#55](https://github.com/brettdavies/dotfiles/pull/55)
- Annotated version-gated entries inline (`GH_TELEMETRY` v2.91.0+, `GOTELEMETRY` Go 1.23+).

### Fixed

- `qmd-embed.service` no longer references the stale `qwen3-coder:30b` model name. Pre-embed VRAM step now adapts to
  whatever Ollama is actually running, on whichever host. by @brettdavies in
  [#51](https://github.com/brettdavies/dotfiles/pull/51)
- `stow/claude/dot-claude/md-wrap.py`: `wrap_paragraph.drain()` no longer leaks `buf_indent` across paragraphs. Adds the
  missing `nonlocal` declaration plus a post-flush reset. by @brettdavies in
  [#52](https://github.com/brettdavies/dotfiles/pull/52)
- Cross-platform `docs/solutions` symlink: now resolves on both macOS and Linux without per-host re-creation. by
  @brettdavies in [#54](https://github.com/brettdavies/dotfiles/pull/54)

### Documentation

- Update `stow/claude/dot-claude/CLAUDE.md` recreate-symlink command to use the relative form. by @brettdavies in
  [#54](https://github.com/brettdavies/dotfiles/pull/54)
- Document PR template sub-section completeness — `Files Modified` and `Related Issues/Stories` sub-headers must appear
  with `- None.` or `n/a` when empty; only the `Changelog` block's `### Added`/`Changed`/`Fixed`/`Documentation`
  sections may be deleted when empty. by @brettdavies in [#58](https://github.com/brettdavies/dotfiles/pull/58)
- Document the heredoc escape rule for `gh pr create --body "$(cat <<'EOF' ... EOF)"` — single-quoted delimiters
  preserve the body literally, so do not escape inner quotes, backslashes, or `$`.
- Expand the plan/docs-only direct-commit exception to cover `docs/ideation/**` and `docs/research/**`.

**Full Changelog**: [2026.04.22...2026.05.02](https://github.com/brettdavies/dotfiles/compare/2026.04.22...2026.05.02)

## [2026.04.22]

### Added

- AppArmor profile for Playwright's Chromium binaries (both `chrome-headless-shell` and full `chrome`), deployed with
  `sudo scripts/apparmor-deploy.sh`. Persists across reboots via `/etc/apparmor.d/`. by @brettdavies in
  [#39](https://github.com/brettdavies/dotfiles/pull/39)
- `opendataloader-pdf` stow package: socket unit (`127.0.0.1:5002`), service unit (socket-activated, hardened with
  `NoNewPrivileges` + `PrivateTmp`), and a two-file launcher (`opendataloader-pdf-hybrid-sa` sh wrapper + `.py` module
  with LISTEN_FDS dispatch and asyncio idle-exit watchdog). by @brettdavies in
  [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `scripts/opendataloader-pdf-enable.sh` — one-shot idempotent enable script that stops orphan listeners, reloads
  systemd, enables `--now` the socket unit, and smoke-tests `/health`.
- `--idle-timeout` flag on the launcher; defaults to 60 s so qmd isn't starved by ODL's residual 4.4 GB.
- Stow-managed `qmd-serve.service` systemd user unit for the sequential-mode daemon (always-on, peak VRAM ~2.6 GB
  instead of ~5.4 GB). by @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `config/shell/qmd.sh` exports `QMD_SERVER=http://127.0.0.1:7832` in all shell contexts (interactive, non-interactive
  zsh, cron, systemd children that source `.profile`).
- `stow/qmd/dot-local/bin/qmd` sh wrapper dispatches to the brettdavies/qmd fork at `$HOME/dev/qmd/qmd`.
- `scripts/qmd-serve-enable.sh` is a Linux-only idempotent one-shot that cleans orphan `:7832` listeners, reloads
  systemd, enables --now, and smokes `/health`.
- `target/**` ignore and `# Canonical version: 2026.04.15` header in the canonical markdownlint config so per-repo
  copies can detect drift with a one-liner comparison. by @brettdavies in
  [#49](https://github.com/brettdavies/dotfiles/pull/49)

### Changed

- Change release-branch construction from `git merge origin/development` to cherry-picking PR squash commits, so
  `git-cliff --unreleased` only sees the true release delta. by @brettdavies in
  [#37](https://github.com/brettdavies/dotfiles/pull/37)
- `scripts/stow-deploy`: `opendataloader-pdf` added to `SHARED_PACKAGES` and to the Linux-only skip block (macOS deploys
  skip with a WARNING). by @brettdavies in [#40](https://github.com/brettdavies/dotfiles/pull/40)
- `qmd-embed.service` and `qmd-update.service` ExecStart switched to `%h/.local/bin/qmd` (the new stow wrapper). by
  @brettdavies in [#44](https://github.com/brettdavies/dotfiles/pull/44)
- `QMD_SERVER` export moved out of `stow/shell/dot-profile` into `config/shell/qmd.sh` (feature-named file convention).
- Rename `CLAUDE.md` to `AGENTS.md` so Claude Code, opencode, Cursor, and Codex all read the same project-level
  instructions. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)
- Update `README.md` stow-package table: add `github`, `openclaw`, `opendataloader-pdf`, and `rust` rows; expand the
  `qmd` row to cover the new qmd-serve daemon and `.local/bin/qmd` wrapper.
- Update `README.md` Shell Environment table: add `qmd.sh` (exports `QMD_SERVER`).
- Update `README.md` Release Automation section: rename `RELEASE_TOKEN` → `CI_RELEASE_TOKEN` and clarify that release
  notes come from the committed `CHANGELOG.md`, not from git-cliff at CI time.
- Update `BOOTSTRAP.md` manual stow commands to include `github` (macOS + headless) and `opendataloader-pdf` (headless),
  matching `scripts/stow-deploy`'s `SHARED_PACKAGES`.
- Update `PROJECT.md` counts (17 → 32 stow packages, 11 → 16 shell fragments) and expand the package breakdown.
- Correct the `RELEASES.md` pipeline diagram to show cherry-picking from dev onto a `release/*` branch branched from
  main (matches the flow landed in #37).

### Fixed

- `qmd-update.service` now sets an explicit `PATH` that includes the Homebrew prefix so timer-triggered runs can resolve
  subprocess dependencies. by @brettdavies in [#46](https://github.com/brettdavies/dotfiles/pull/46)
- Auto-format hook now reads its global config fallback from `~/.markdownlint-cli2.yaml` (stow-managed symlink to
  dotfiles canonical) instead of the deleted `~/.claude/.markdownlint-cli2.yaml` stray. by @brettdavies in
  [#49](https://github.com/brettdavies/dotfiles/pull/49)
- Realign table column widths across `AGENTS.md`, `README.md`, `PROJECT.md`, and `RELEASES.md` so they satisfy MD060
  `aligned` style after the widened rows. by @brettdavies in [#50](https://github.com/brettdavies/dotfiles/pull/50)

### Documentation

- Document the cherry-pick flow and rename "Why branch from main, not development" to explain both the `add/add`
  conflict and the orphan-history failure modes that motivate this workflow. by @brettdavies in
  [#37](https://github.com/brettdavies/dotfiles/pull/37)
- Describe \`docs/solutions/\` structure and search path in \`CLAUDE.md\` Reference section. by @brettdavies in
  [#41](https://github.com/brettdavies/dotfiles/pull/41)
- Mark \`docs/plans/2026-04-21-001-feat-opendataloader-pdf-socket-activation-plan.md\` as \`completed\` with post-ship
  notes describing shipped state, deviations, and measured timings. by @brettdavies in
  [#42](https://github.com/brettdavies/dotfiles/pull/42)

**Full Changelog**: [2026.04.15...2026.04.22](https://github.com/brettdavies/dotfiles/compare/2026.04.15...2026.04.22)

## [2026.04.15]

### Added

- Add `DO_NOT_TRACK=1` universal telemetry opt-out (consoledonottrack.com) plus targeted opt-outs for VS Code
  (`VSCODE_TELEMETRY_LEVEL=off`), PowerShell (`POWERSHELL_TELEMETRY_OPTOUT=1`), and Azure Functions Core Tools
  (`FUNCTIONS_CORE_TOOLS_TELEMETRY_OPTOUT=1`) by @brettdavies in [#31](https://github.com/brettdavies/dotfiles/pull/31)
  and [#32](https://github.com/brettdavies/dotfiles/pull/32)
- Add nightly autocommit for `obsidian-vault`, `solutions-docs`, and agent-skills with a systemd timer randomized to 2-4
  AM CT by @brettdavies in [#33](https://github.com/brettdavies/dotfiles/pull/33)
- Add `mnt-nas.automount` for on-demand NAS mounting (fixes the WiFi boot race) and `scripts/nas-deploy.sh` for
  copy-deploying system-level systemd units by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)
- Add `github/` stow package targeting `~/.config/github/` for repo-workflow templates; `SHARED_PACKAGES` in
  `scripts/stow-deploy` now includes it by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)

### Changed

- Rename `RELEASING.md` to `RELEASES.md` and restructure to the canonical release-doc layout shared across brettdavies
  repos by @brettdavies in [#35](https://github.com/brettdavies/dotfiles/pull/35)
- Move the canonical PR template from `stow/claude/dot-claude/templates/pull-request.md` to
  `stow/github/dot-config/github/pull_request_template.md`; `.github/pull_request_template.md` is now a real inlined
  file so GitHub's PR-template discovery works
- Prohibit AI-attribution trailers on commit messages and PR bodies via global CLAUDE.md directive
- Move `QMD_SERVER` and Bun PATH exports from `.zshrc` to `.profile` so cron, SSH commands, and other non-interactive
  contexts see them
- Support markdown hard line breaks (two trailing spaces) in the `md-wrap.py` PostToolUse hook and in the markdownlint
  config; prefer the project-local `markdownlint-cli2.yaml` over the global one for line-width
- Strengthen the query-solutions-first instruction in global CLAUDE.md
- Stop tracking `TODOS.md` (added to global gitignore)

### Fixed

- Fix nightly autocommit to embed the Conventional Commits spec and SRP rules in the prompt, and delegate full
  add+commit to `claude -p` rather than staging in shell

### Documentation

- Document the system-level systemd units pattern in CLAUDE.md (copy-deploy, not stow) and add a matching section to
  README.md by @brettdavies in [#34](https://github.com/brettdavies/dotfiles/pull/34)

**Full Changelog**: [2026.04.01...2026.04.15](https://github.com/brettdavies/dotfiles/compare/2026.04.01...2026.04.15)

## [2026.04.01]

### Added

- Add `gogcli` stow package with `config.json` and shell wrapper by @brettdavies in
  [#27](https://github.com/brettdavies/dotfiles/pull/27)
- Add tmuxinator stow package with 13 declarative session YAML configs by @brettdavies in
  [#28](https://github.com/brettdavies/dotfiles/pull/28)
- Add `mux` (tmuxinator passthrough) and `mux-all` (start all sessions) shell functions
- Add caam account manager stow package with daemon auto-start and `claude-switch`
- Add headless Obsidian stow package with systemd service, config, and CLI wrapper
- Add rclone Box bisync stow package with systemd timer and git-crypt encrypted config
- Add systemd user timers for qmd, openclaw, and nightly rustup-update
- Add supply-chain safety for uv, npm, pip, and bun (package age gates)
- Add TPM bootstrap instructions to BOOTSTRAP.md

### Changed

- Adopt changelog-as-committed-artifact release process (no more CI-generated changelog)
- Inline brew shellenv to eliminate Ruby subprocess on startup (~200ms savings)
- Replace docs/solutions/ directory with symlink to shared solutions-docs repo
- Rename RELEASE_TOKEN to CI_RELEASE_TOKEN by @brettdavies in [#26](https://github.com/brettdavies/dotfiles/pull/26)
- Pin external GitHub Actions to commit SHAs, upgrade to actions/checkout v6.0.2

### Fixed

- Add Homebrew site-functions to zsh fpath (fixes completions for tmuxinator, brew, gh, bat, etc.)
- Split caam interactive/non-interactive wrapper, add claude-switch helper
- Update openclaw service paths from OpenClaw to Areas/openclaw
- Enable rclone bisync filters and exclude Obsidian per-device state

### Documentation

- Add RELEASING.md with CalVer release branch procedure
- Overhaul README and extract bootstrap guide

**Full Changelog**: [2026.03.19...2026.04.01](https://github.com/brettdavies/dotfiles/compare/2026.03.19...2026.04.01)

## [2026.03.19]

### Changed

- Rename RELEASE_TOKEN to CI_RELEASE_TOKEN for clarity by @brettdavies in
  [#26](https://github.com/brettdavies/dotfiles/pull/26)

**Full Changelog**: [2026.03.18...2026.03.19](https://github.com/brettdavies/dotfiles/compare/2026.03.18...2026.03.19)

## [2026.03.18]

### Added

- Add `bun`, `pip`, `codex`, `opencode`, `local` stow packages
- Add `lazygit`, `micro`, `yazi` stow packages with configs
- Add platform-aware `$EDITOR` via `config/shell/` and `.gitconfig`
- Add `gh` CLI merge guard wrapper to block AI merges into `main`/`master`
- Add encrypted `gh` hosts.yml via git-crypt

### Changed

- Cross-platform editor config, CI hardening, new stow packages, and docs overhaul by @brettdavies in
  [#23](https://github.com/brettdavies/dotfiles/pull/23)
- Overhaul README with stow package table, shell environment table, and performance section
- Extract BOOTSTRAP.md from README with detailed platform-specific setup

### Fixed

- Release workflow fixes and action SHA pinning by @brettdavies in
  [#24](https://github.com/brettdavies/dotfiles/pull/24)
- Pin all external actions to commit SHAs
- Fix release body extraction (use git-cliff action output instead of bare CLI)

**Full Changelog**: [2026.03.13...2026.03.18](https://github.com/brettdavies/dotfiles/compare/2026.03.13...2026.03.18)

## [2026.03.13]

### Added

- Per-platform git config templates (`config/git/local.linux`, `config/git/local.darwin`)
- `stow-deploy` auto-deploys platform template to `~/.config/git/local` if absent

### Fixed

- Cross-platform hardening for shell scripts, SSH config, and git signing by @brettdavies in
  [#22](https://github.com/brettdavies/dotfiles/pull/22)
- Headless server adoption (OpenClaw, EDITOR/VISUAL, printer aliases, tmux)
- Cross-platform guards (Obsidian macOS-only, hbash Linuxbrew fallback)

### Documentation

- Compound solution: cross-platform shell idiom and config hardening

**Full Changelog**:
[2026.03.12.1...2026.03.13](https://github.com/brettdavies/dotfiles/compare/2026.03.12.1...2026.03.13)

## [2026.03.12.1]

### Fixed

- Force Node.js 24 for GitHub Actions by @brettdavies in [#20](https://github.com/brettdavies/dotfiles/pull/20)

**Full Changelog**:
[2026.03.12...2026.03.12.1](https://github.com/brettdavies/dotfiles/compare/2026.03.12...2026.03.12.1)

## [2026.03.12]

### Added

- Initial dotfiles repository with GNU Stow
- Script library with sync, verification, and dry-run
- Git-crypt encryption for secrets, SSH config, and git allowed_signers
- iCloud sync via LaunchAgent (macOS)
- Claude Code configuration and project documentation
- Cross-platform deployment to Ubuntu server
- `scripts/stow-deploy` conflict resolution wrapper with `--headless` mode by @brettdavies in
  [#4](https://github.com/brettdavies/dotfiles/pull/4)
- Repo-local enforcement (hooks, rulesets, config) by @brettdavies in
  [#3](https://github.com/brettdavies/dotfiles/pull/3)
- Auto-configure `core.hooksPath` in stow-deploy by @brettdavies in [#7](https://github.com/brettdavies/dotfiles/pull/7)
- CalVer changelog automation with git-cliff by @brettdavies in [#16](https://github.com/brettdavies/dotfiles/pull/16)
- `stow/tmux` package with full tmux config and TPM by @brettdavies in
  [#11](https://github.com/brettdavies/dotfiles/pull/11)
- Platform-aware package sets (`SHARED_PACKAGES` + `DESKTOP_PACKAGES`) by @brettdavies in
  [#12](https://github.com/brettdavies/dotfiles/pull/12)

### Changed

- Restructure as configuration store, remove shell CLI
- Zero-disk secret loading with `op inject`
- Branch workflow enforcement and documentation

### Fixed

- Cross-platform git signing and Claude Code hook guards
- Portable binary detection in git hooks by @brettdavies in [#8](https://github.com/brettdavies/dotfiles/pull/8)
- Standardize hook shebangs, add strict mode, optimize git-crypt check by @brettdavies in
  [#5](https://github.com/brettdavies/dotfiles/pull/5)
- Shell startup optimization from ~440ms to ~190ms by @brettdavies in
  [#14](https://github.com/brettdavies/dotfiles/pull/14)

### Documentation

- Compound solution for deployment hardening (sentinel, binary detection, auto hooks) by @brettdavies in
  [#10](https://github.com/brettdavies/dotfiles/pull/10)
