# shellcheck shell=bash
# qmd: route CLI queries through a persistent qmd-serve daemon so heavy models
# stay warm across invocations instead of cold-loading per call.
export QMD_REMOTE_URL=http://127.0.0.1:7832

# Low-vram mode disposes and reloads heavy models one at a time (peak ~2.6 GB
# vs ~5.4 GB). Only the VRAM-constrained Linux box needs it; macOS runs the
# daemon full-resident.
if [ "$(uname)" = "Linux" ]; then
  export QMD_LOW_VRAM=1
fi
