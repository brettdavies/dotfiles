# shellcheck shell=bash
# Added by LM Studio CLI (lms) — dedupe-guarded to stay idempotent across
# re-sources. Original installer line appended unconditionally.
if [ -d "$HOME/.lmstudio/bin" ]; then
  case ":${PATH}:" in
    *:"$HOME/.lmstudio/bin":*) ;;
    *) export PATH="$PATH:$HOME/.lmstudio/bin" ;;
  esac
fi
# End of LM Studio CLI section
