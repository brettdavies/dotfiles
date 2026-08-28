# shellcheck shell=bash
# tmuxinator: declarative tmux session management
# mux() passes all arguments to tmuxinator; mux-all() starts every configured session
# On machines without tmuxinator, this file is a no-op
if command -v tmuxinator >/dev/null 2>&1; then
  # TMUXINATOR_CONFIG is the sole project directory: tmuxinator reads, writes,
  # and lists projects here, so `new`/`copy` write straight to the source of
  # truth. Leaving ~/.config/tmuxinator populated would shadow it — tmuxinator
  # searches that path in `start`/`stop` but not in `list`, so a config sitting
  # there starts a session that never appears in the project list.
  _tmuxinator_config_dir="$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"
  [ -d "$_tmuxinator_config_dir" ] && export TMUXINATOR_CONFIG="$_tmuxinator_config_dir"
  unset _tmuxinator_config_dir

  mux() {
    tmuxinator "$@"
  }

  mux-all() {
    _started=0
    _skipped=0
    for _yml in "${TMUXINATOR_CONFIG:-$HOME/.config/tmuxinator}"/*.yml; do
      [ -f "$_yml" ] || continue
      _project=$(basename "$_yml" .yml)
      # tmux names the session after the config's `name:` field, which is a
      # display name free to differ from the filename tmuxinator starts by.
      _session=$(sed -n 's/^name:[[:space:]]*//p' "$_yml" | head -1 \
        | sed 's/[[:space:]]*$//; s/^"//; s/"$//')
      [ -n "$_session" ] || _session="$_project"
      if tmux has-session -t "=$_session" 2>/dev/null; then
        _skipped=$((_skipped + 1))
        continue
      fi
      tmuxinator start "$_project" -d >/dev/null 2>&1
      _started=$((_started + 1))
    done
    echo "mux-all: started $_started, skipped $_skipped (already running)"
    unset _started _skipped _yml _project _session
  }
fi
