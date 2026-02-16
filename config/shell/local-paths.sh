# Local tool paths — adds directories to PATH/LD_LIBRARY_PATH if they exist
# This covers tools installed outside of Homebrew (CUDA, npm, Bun, etc.)

# CUDA toolkit
if [ -d /usr/local/cuda/bin ]; then
    export PATH="/usr/local/cuda/bin:$PATH"
    [ -d /usr/local/cuda/lib64 ] && export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# npm global packages (Linux convention)
[ -d "$HOME/.npm-global/bin" ] && export PATH="$HOME/.npm-global/bin:$PATH"

# Bun
[ -d "$HOME/.bun/bin" ] && export PATH="$HOME/.bun/bin:$PATH"
