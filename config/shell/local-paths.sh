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
