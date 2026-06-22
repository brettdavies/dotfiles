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

# Homebrew Ruby (keg-only) + its gem binstubs. Puts a modern Ruby/Bundler
# ahead of the macOS system Ruby 2.6 (whose Bundler 1.x predates the
# supply-chain cooldown policy). The gems/*/bin glob tracks the ABI dir so a
# Ruby minor bump (4.0.0 -> 4.1.0) needs no edit. Guarded by -d, so a host
# without keg-only Homebrew Ruby is untouched.
for _brew_prefix in /opt/homebrew /home/linuxbrew/.linuxbrew; do
    [ -d "$_brew_prefix/opt/ruby/bin" ] || continue
    case ":${PATH}:" in
        *:"$_brew_prefix/opt/ruby/bin":*) ;;
        *) export PATH="$_brew_prefix/opt/ruby/bin:$PATH" ;;
    esac
    for _ruby_gem_bin in "$_brew_prefix"/lib/ruby/gems/*/bin; do
        [ -d "$_ruby_gem_bin" ] || continue
        case ":${PATH}:" in
            *:"$_ruby_gem_bin":*) ;;
            *) export PATH="$_ruby_gem_bin:$PATH" ;;
        esac
    done
done
unset _brew_prefix _ruby_gem_bin
