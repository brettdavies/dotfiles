-- yazi init.lua — Lua side of yazi config
-- Stow package: dotfiles/stow/yazi/dot-config/yazi/init.lua
-- Symlinked to: ~/.config/yazi/init.lua
--
-- Registers Lua-based plugins that need a setup() call at startup. Plugins
-- managed by `ya pkg` are recorded in package.toml; this file activates them.

-- git.yazi: shows git status markers (M/A/D/?) as a linemode column next to
-- files in the listing. The `prepend_fetchers` rules in yazi.toml feed git
-- status into each file object; this setup call registers the linemode renderer.
require("git"):setup()
