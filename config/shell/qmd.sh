# qmd: route CLI queries through the persistent qmd-serve daemon (sequential
# model loading — one heavy model resident at a time, peak ~2.6 GB instead of
# ~5.4 GB). Service: ~/.config/systemd/user/qmd-serve.service
export QMD_SERVER=http://127.0.0.1:7832
