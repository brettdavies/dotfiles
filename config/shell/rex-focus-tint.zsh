# shellcheck disable=all  # zsh syntax: shellcheck only understands bash/sh
# Paints an unfocused Rex pane dark amber with OSC 11 when Rex reports focus-out. Inside tmux, the window-style hooks in
# stow/tmux/dot-config/tmux/base.conf own pane colors, so this stays off there.
[[ -n ${REX_SESSION:-} && -z ${TMUX:-} ]] || return 0

typeset -g REX_UNFOCUSED_BG='#3c2010'

_rex_focus_out() { printf '\e]11;%s\a' "$REX_UNFOCUSED_BG" >$TTY }
_rex_focus_in() { printf '\e]111\a' >$TTY }
_rex_focus_reports_on() { printf '\e[?1004h' >$TTY }

# Focus reports go to whatever program holds the terminal, and one that never asked for them reads the sequences as
# typed input; zsh also can't hear the focus-in that would clear the tint while that program runs.
_rex_focus_command_start() { printf '\e[?1004l\e]111\a' >$TTY }

zle -N _rex_focus_out
zle -N _rex_focus_in
zle -N _rex_focus_reports_on
for _rex_keymap in emacs viins vicmd; do
    bindkey -M "$_rex_keymap" '\e[O' _rex_focus_out
    bindkey -M "$_rex_keymap" '\e[I' _rex_focus_in
done
unset _rex_keymap

autoload -Uz add-zle-hook-widget add-zsh-hook
add-zle-hook-widget line-init _rex_focus_reports_on
add-zsh-hook preexec _rex_focus_command_start
