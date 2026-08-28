# shellcheck shell=bash
# gbrain: default `gbrain doctor` to --fast unless the caller opts out.
#
# Why: a full doctor sweep probes the chat model and pins it with
# KEEP_ALIVE=-1, so large local Ollama models (e.g. gemma4:26b) stay
# resident long after the check finishes. --fast skips the probe.
# Reserve full doctor runs for explicit calls.
#
# Loaded via stow/shell/dot-profile (every shell, interactive and
# non-interactive zsh) when gbrain is on PATH. No-op otherwise.
#
# Escape hatches:
#   GBRAIN_DOCTOR_NO_FAST_DEFAULT=1 gbrain doctor   # one-shot full run
#   command gbrain doctor                            # bypass the wrapper

if command -v gbrain >/dev/null 2>&1; then
  gbrain() {
    if [ "${1:-}" = "doctor" ] && [ -z "${GBRAIN_DOCTOR_NO_FAST_DEFAULT:-}" ]; then
      shift
      case " $* " in
        *" --fast "*) command gbrain doctor "$@" ;;
        *) command gbrain doctor --fast "$@" ;;
      esac
      return
    fi
    command gbrain "$@"
  }

  # Explicit full-doctor shortcut for the rare deliberate run.
  # Function (not alias): bash skips alias expansion in non-interactive
  # shells by default, but function definitions persist either way.
  gbrain-doctor-full() {
    GBRAIN_DOCTOR_NO_FAST_DEFAULT=1 command gbrain doctor "$@"
  }
fi
