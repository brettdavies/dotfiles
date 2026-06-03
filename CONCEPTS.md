# Concepts

Shared domain vocabulary for this project — entities, named processes, and status concepts with project-specific
meaning. Seeded with core domain vocabulary, then accretes as ce-compound and ce-compound-refresh process learnings;
direct edits are fine. Glossary only, not a spec or catch-all.

## Deployed dotfiles host

A machine where this repo has been stowed into the user's home, so the dotfile symlinks and shell helpers are in place.
Some assertions in this repo's test suite (and some policies declared in shell configuration) are only meaningful on a
deployed dotfiles host — generic CI runners and non-deployed user accounts are not subject to them. Tests that enforce a
deployed-host policy precondition-skip when the host class is not detected; the canonical detection check is whether one
of the stow-deployed symlinks is in place.

Capability checks (is the tool installed at all?) layer before host-class checks (is this host subject to the policy?).
The two compose; neither replaces the other.

## Supply-chain age gate

The minimum-release-age policy applied to every supported package manager on a deployed dotfiles host: a version newly
published to its upstream registry is not resolvable until it has been public for at least the gate's configured number
of days. Each package manager exposes the policy through its own configuration key (env var, config file, or both), and
each requires a tool version recent enough to honor it — older versions silently ignore the setting, so the gate is
paired with a version floor for every PM it covers. The gate is enforced via shell env vars (covering interactive and
shell-launched processes) and, where the tool supports a global config file, written into that file (covering cron,
systemd units, and other non-shell invocations).
