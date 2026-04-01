# gogcli: Google Workspace CLI — auto-inject keyring password from 1Password
# On machines without gog, this file is a no-op (no function defined, no error)
if command -v gog >/dev/null 2>&1; then
    gog() {
        export GOG_KEYRING_PASSWORD="${GOG_KEYRING_PASSWORD:-$("$HOME/.claude/skills/1password/scripts/read_field.sh" 'Google Workspace CLI OAuth (Streams)' 'client_secret' 2>/dev/null)}"
        command gog "$@"
    }

    # Adopt gogcli config back into stow source (gogcli may rewrite config.json, breaking symlink)
    stow --dotfiles --no-folding --target="$HOME" --dir="$HOME/dotfiles/stow" -R --adopt gogcli 2>/dev/null || true
fi
