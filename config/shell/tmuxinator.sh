# shellcheck shell=bash
# tmuxinator: declarative tmux session management
# mux() passes all arguments to tmuxinator; mux-all() starts every configured session
# On machines without tmuxinator, this file is a no-op
if command -v tmuxinator >/dev/null 2>&1; then
    # Point tmuxinator at the stow source so `tmuxinator new|copy|edit` writes
    # the source-of-truth directly. ~/.config/tmuxinator/*.yml symlinks remain
    # populated by stow for any tool that reads the XDG default path.
    _tmuxinator_stow_dir="$HOME/dotfiles/stow/tmuxinator/dot-config/tmuxinator"
    [ -d "$_tmuxinator_stow_dir" ] && export TMUXINATOR_CONFIG="$_tmuxinator_stow_dir"
    unset _tmuxinator_stow_dir

    mux() {
        tmuxinator "$@"
    }

    mux-all() {
        _started=0
        _skipped=0
        for _yml in "$HOME/.config/tmuxinator"/*.yml; do
            [ -f "$_yml" ] || continue
            _name=$(basename "$_yml" .yml)
            if tmux has-session -t "$_name" 2>/dev/null; then
                _skipped=$((_skipped + 1))
                continue
            fi
            tmuxinator start "$_name" -d >/dev/null 2>&1
            _started=$((_started + 1))
        done
        echo "mux-all: started $_started, skipped $_skipped (already running)"
        unset _started _skipped _yml _name
    }
fi
