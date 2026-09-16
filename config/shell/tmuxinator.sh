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

  # Returns non-zero when any project failed to start.
  mux-all() {
    local started=0 skipped=0 failed=0 yml project session
    for yml in "${TMUXINATOR_CONFIG:-$HOME/.config/tmuxinator}"/*.yml; do
      [ -f "$yml" ] || continue
      project=$(basename "$yml" .yml)
      # tmux names the session after the config's `name:` field, which is a
      # display name free to differ from the filename tmuxinator starts by.
      session=$(sed -n 's/^name:[[:space:]]*//p' "$yml" | head -1 \
        | sed 's/[[:space:]]*$//; s/^"//; s/"$//')
      [ -n "$session" ] || session="$project"
      if tmux has-session -t "=$session" 2>/dev/null; then
        skipped=$((skipped + 1))
        continue
      fi
      # A project whose on_project_start hook fails never creates its session,
      # so a start that reports success is the only one counted as started.
      if tmuxinator start "$project" -d >/dev/null 2>&1; then
        started=$((started + 1))
      else
        failed=$((failed + 1))
        echo "mux-all: $project failed to start" >&2
      fi
    done
    echo "mux-all: started $started, skipped $skipped (already running), failed $failed"
    [ "$failed" -eq 0 ]
  }
fi
