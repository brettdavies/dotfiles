# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# agent-slot-rex's usage text and each verb's --help: a usage line, what the verb does, and one example. VERBS is the
# closed set the dispatcher accepts.

USAGE='usage: agent-slot-rex <verb> [options] [--output json]

Verbs:
  launch   start an agent in a fresh slot, in a background Rex tab that becomes its tab, or open the repo'"'"'s prime
  prime    keep a tab attached to a repo'"'"'s prime tmux session, dropping to a shell on detach
  attach   keep a pane attached to one of a slot'"'"'s tmux sessions
  restore  give every live slot a tab, resume dormant slots, and close tabs whose slot is gone
  sweep    tear down finished slots, restore, then list the slots that need you
  finish   finish a task with no open PR and tear its slot down, from the control session
  doctor   check the Rex server, the units, rexurrect, and the reconcile journal, then run agent-slot'"'"'s doctor

On macOS, launch, prime, restore, finish, sweep, and doctor run on the Linux server'"'"'s helper over ssh; the other
verbs run only there.

Every verb takes --help. launch, restore, sweep, finish, and doctor take --output json (one JSON object on stdout, or an error
object on stderr). Exit codes: 0 ok, 1 failed, 2 usage, 77 auth, 78 configuration.'

VERBS=' launch prime attach restore sweep finish doctor '

verb_help() {
  case $1 in
    launch) printf '%s\n' \
      'usage: agent-slot-rex launch [--repo NAME] [--task NAME] [--here [--wait-shown]] [--output json]' \
      "Starts an agent in a fresh slot of a repo: --repo, else the Rex session's name when it names a repo, else" \
      "a numbered list when a terminal is attached. --here turns this tab into the agent's tab (the new-agent key" \
      "passes it); without it the launch runs in a new background tab in the repo's session. With --here and no" \
      "--repo, in a session named after a repo that has a prime tmux session (prime --help), and with no tab of" \
      "the session attached to it, this tab becomes the prime's tab instead: first in the session, labelled" \
      "with the prime's name, and running prime. --wait-shown, which a key or palette press adds, first waits up" \
      "to $AR_SHOWN_WAIT s for an app to show this tab, which it does by asking a size for its terminal; a tab" \
      "never shown starts nothing, and closes itself unless Enter comes within $AR_SHOWN_HOLD s." \
      'example: agent-slot-rex launch --repo dotfiles --task fix/login' ;;
    prime) printf '%s\n' 'usage: agent-slot-rex prime <repo>' \
      "Attaches to the repo's prime tmux session on the default tmux server, named in $AR_PRIMES, from \$HOME," \
      "and becomes a login shell ($AR_LOGIN_SHELL -l) when the client detaches or the attach fails." \
      'example: agent-slot-rex prime xurl-rs' ;;
    attach) printf '%s\n' 'usage: agent-slot-rex attach <repo>/<N> claude|files|git' \
      "Attaches to the slot's tmux session from \$HOME, resuming the slot when the session is missing, and waits" \
      'for Enter after a detach; it ends once the slot is gone.' \
      'example: agent-slot-rex attach dotfiles/2 claude' ;;
    restore) printf '%s\n' \
      'usage: agent-slot-rex restore [--tab | --at-start | --by push|poll] [--output json]' \
      "Gives every live slot a tab in its repo's session, resumes dormant slots, relabels tabs, and closes tabs" \
      'whose slot is gone or that duplicate another. With no Rex server answering, or before the start-up step has' \
      "run in it (until the server is $AR_STARTUP_LIMIT s old), it changes nothing and fails with rex-server-down or" \
      'startup-pending; when the server restarts or stops partway, it makes no further change and fails with' \
      'rex-server-restarted or rex-server-down. --tab runs it in a new tab of the agent-slots session. --at-start is' \
      "the start-up step Rex runs when it loads: it waits up to $AR_STARTUP_WAIT s for the server; once per server" \
      "instance it kills each session holding nothing but slot tabs and runs rexurrect's restore (up to" \
      "$AR_REXURRECT_BOUND s); it records the instance in $AR_STARTUP_RECORD, types prime <repo> into each" \
      "restored prime tab (labelled with the prime's name, one pane at a shell prompt, in a session whose prime" \
      "no tab holds), then restores, logging to $AR_STATE/restore.log; it does nothing unless a Rex server" \
      'started it. --by names what ran it:' \
      "push, after agent-slot's launch or teardown, or poll, from agent-slot-reconcile.timer each minute; such a" \
      'pass exits 0 when it changes nothing, and says why under skipped.' \
      "Every restore, sweep, and finish appends its plan, duration, and outcome to $AR_STATE/reconcile.log." \
      'example: agent-slot-rex restore' ;;
    sweep) printf '%s\n' 'usage: agent-slot-rex sweep [--output json]' \
      "Runs agent-slot sweep --yes, which tears down every finished slot that check passes, then restores tabs" \
      'and lists the slots that need you. In text mode it waits for q while any slot needs you or the server could' \
      'not be reached.' \
      'example: agent-slot-rex sweep --output json' ;;
    finish) printf '%s\n' 'usage: agent-slot-rex finish <repo>/<N> [--output json]' \
      '       agent-slot-rex finish --tab --session ID --block ID' \
      "Runs agent-slot finish --yes for the slot: a task with no open PR is marked finished and its slot torn down" \
      "when check passes; then restores tabs, which closes the task's tab. --tab, which the finish key passes, finds" \
      "the slot of the tab holding the block and runs the finish in a tab of the agent-slots session." \
      'example: agent-slot-rex finish dotfiles/2' ;;
    doctor) printf '%s\n' 'usage: agent-slot-rex doctor [--output json]' \
      "Checks the rex CLI, the Rex server (that $AR_REX_UNIT started it, its build, and the new-agent action)," \
      "the reconcile timer, the tab-number watcher, the login server, rexurrect, the reconcile journal, and where" \
      "the agent-slots tmux server runs, then adds agent-slot doctor's findings. Versions that differ from the" \
      'verified ones only warn.' \
      'example: agent-slot-rex doctor --output json' ;;
  esac
}
