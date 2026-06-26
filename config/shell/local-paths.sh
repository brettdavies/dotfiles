# shellcheck shell=bash
# Local tool paths — adds directories to PATH/LD_LIBRARY_PATH if they exist
# This covers tools installed outside of Homebrew (CUDA, npm, Bun, etc.)
#
# All prepends are dedupe-guarded so re-sourcing (e.g., from .zshrc after
# .zshenv) doesn't multiply entries. Same idiom as stow/shell/dot-profile.

# CUDA toolkit
if [ -d /usr/local/cuda/bin ]; then
    case ":${PATH}:" in
        *:/usr/local/cuda/bin:*) ;;
        *) export PATH="/usr/local/cuda/bin:$PATH" ;;
    esac
    if [ -d /usr/local/cuda/lib64 ]; then
        case ":${LD_LIBRARY_PATH:-}:" in
            *:/usr/local/cuda/lib64:*) ;;
            *) export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}" ;;
        esac
    fi
fi

# npm global packages (Linux convention)
if [ -d "$HOME/.npm-global/bin" ]; then
    case ":${PATH}:" in
        *:"$HOME/.npm-global/bin":*) ;;
        *) export PATH="$HOME/.npm-global/bin:$PATH" ;;
    esac
fi

# Bun
if [ -d "$HOME/.bun/bin" ]; then
    case ":${PATH}:" in
        *:"$HOME/.bun/bin":*) ;;
        *) export PATH="$HOME/.bun/bin:$PATH" ;;
    esac
fi

# Homebrew Ruby (keg-only). Puts a modern Ruby/Bundler ahead of the macOS
# system Ruby 2.6 (whose Bundler 1.x predates the supply-chain cooldown
# policy). Ruby's own bin carries the `bundle` binstub, which RubyGems resolves
# to the newest installed Bundler (>= 4.0.13 after `gem install bundler`), so a
# gem-binstub glob is unnecessary - and a bare `*/bin` glob aborts shell startup
# under zsh when it matches nothing. Guarded by -d, so a host without keg-only
# Homebrew Ruby is untouched.
#
# Force the dir to the FRONT (remove-then-prepend), not just "add if absent".
# macOS /etc/profile path_helper (and earlier PATH steps) can leave /usr/bin
# ahead of an already-present ruby/bin; an add-if-absent guard then skips and
# the demoted entry stays behind system Ruby in bash, cron, and non-login
# shells. zsh re-asserts the order in stow/zsh/dot-zprofile after path_helper;
# this is the cross-shell equivalent for every .profile-sourcing context.
for _brew_prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
    [ -d "$_brew_prefix/opt/ruby/bin" ] || continue
    _ruby_bin="$_brew_prefix/opt/ruby/bin"
    # Strip any existing occurrence, then prepend — promotes a demoted entry
    # instead of skipping it, and stays dedup'd on re-source. POSIX, no awk/sed.
    _new_path=
    _ifs_save=$IFS
    IFS=:
    # shellcheck disable=SC2086 # intentional word-split on IFS=: to walk PATH
    for _p in $PATH; do
        [ "$_p" = "$_ruby_bin" ] && continue
        _new_path="${_new_path:+$_new_path:}$_p"
    done
    IFS=$_ifs_save
    export PATH="$_ruby_bin:$_new_path"
    unset _ruby_bin _new_path _ifs_save _p
    break
done
unset _brew_prefix
