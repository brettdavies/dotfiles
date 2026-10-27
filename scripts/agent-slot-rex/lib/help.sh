# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# agent-slot-rex's usage text and each verb's --help: a usage line, what the verb does, and one example. VERBS is the
# closed set the dispatcher accepts.

USAGE='usage: agent-slot-rex <verb> [options] [--output json]

Verbs:
  launch   start an agent on the server in a fresh slot, in a background Rex tab that becomes its tab
  attach   keep a pane attached to one of a slot'"'"'s tmux sessions on the server
  restore  give every live slot a tab, resume dormant slots, and close tabs whose slot is gone
  sweep    tear down finished slots on the server, restore, then list the slots that need you
  finish   finish a task with no open PR and tear its slot down, from the control session
  doctor   check the Mac'"'"'s prerequisites, then run the server'"'"'s doctor through the ssh alias

Every verb takes --help. launch, restore, sweep, finish, and doctor take --output json (one JSON object on stdout, or an error
object on stderr). Exit codes: 0 ok, 1 failed, 2 usage, 77 auth, 78 configuration.'

VERBS=' launch attach restore sweep finish doctor '

verb_help() {
  case $1 in
    launch) printf '%s\n' 'usage: agent-slot-rex launch [--repo NAME] [--task NAME] [--here] [--output json]' \
      "Starts an agent in a fresh slot of a repo: --repo, else the Rex session's name when it names a repo, else" \
      "a numbered list when a terminal is attached. --here turns this tab into the agent's tab (the new-agent key" \
      "passes it); without it the launch runs in a new background tab in the repo's session." \
      'example: agent-slot-rex launch --repo dotfiles --task fix/login' ;;
    attach) printf '%s\n' 'usage: agent-slot-rex attach <repo>/<N> claude|files|git' \
      "Attaches to the slot's tmux session and reattaches after every disconnect until the slot is gone." \
      'example: agent-slot-rex attach dotfiles/2 claude' ;;
    restore) printf '%s\n' 'usage: agent-slot-rex restore [--tab | --wait-server] [--output json]' \
      "Gives every live slot a tab in its repo's session, resumes dormant slots, relabels tabs, and closes tabs" \
      'whose slot is gone or that duplicate another. --tab runs it in a new tab of the agent-slots session;' \
      "--wait-server first waits up to $AR_RESTORE_WAIT s for the server, logging to $AR_STATE/restore.log." \
      'example: agent-slot-rex restore' ;;
    sweep) printf '%s\n' 'usage: agent-slot-rex sweep [--output json]' \
      "Runs the server's sweep --yes, which tears down every finished slot that check passes, then restores tabs" \
      'and lists the slots that need you. In text mode it waits for q while any slot needs you or the server could' \
      'not be reached.' \
      'example: agent-slot-rex sweep --output json' ;;
    finish) printf '%s\n' 'usage: agent-slot-rex finish <repo>/<N> [--output json]' \
      '       agent-slot-rex finish --tab --session ID --block ID' \
      "Runs the server's finish --yes for the slot: a task with no open PR is marked finished and its slot torn down" \
      "when check passes; then restores tabs, which closes the task's tab. --tab, which the finish key passes, finds" \
      "the slot of the tab holding the block and runs the finish in a tab of the agent-slots session." \
      'example: agent-slot-rex finish dotfiles/2' ;;
    doctor) printf '%s\n' 'usage: agent-slot-rex doctor [--output json]' \
      "Checks rex, the new-agent action, and ssh to $AR_SERVER, then runs the server's doctor with each next step" \
      'rewritten to run through the alias. Versions that differ from the verified ones only warn.' \
      'example: agent-slot-rex doctor --output json' ;;
  esac
}
