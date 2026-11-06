# shellcheck shell=bash disable=SC2034 # its globals are read by profile_args, and the tests read them by name
# What a slot's Claude loads, cut to what slots use. Every tool definition and every skill listing row is read again on
# each call, and each subagent starts by writing its own copy, so what never loads costs nothing.
#
# The profile is one inline --settings object, since Claude takes a single --settings flag and the slot's
# idle-compaction setting travels in the same one. It stays inline so a pull needs no restow before a slot starts.
# Claude merges it over ~/.claude/settings.json key by key, which leaves alone the name-only skill entries that file's
# refresh keeps: an entry set here, even to name-only, would freeze that refresh for slots. Skills are set to off only.

# The tools a slot cannot use: its hook denies every question, a wakeup serves only /loop (off below), /code-review is
# the one user of ReportFindings and a slot's permissions deny it, and no slot publishes an artifact. Artifact alone
# is 35.9k characters of definition.
PROFILE_TOOLS_OFF=(Artifact AskUserQuestion ScheduleWakeup ReportFindings)

# Skills no slot has called: the claude.ai-synced set, the built-ins slots do not use, and the skills that only serve
# the Artifact tool. Off removes a skill from the listing and from the Skill tool.
PROFILE_SKILLS_OFF=(artifact-capabilities artifact-design artifact-diagramming artifact-emulator built-in-browser
  chrome-browser claude-api code-review computer-use dataviz deep-research docs docx fewer-permission-prompts
  google-workspace import-memory init keybindings-help loop morning pdf plugin-authoring pptx run schedule
  security-review simplify skill-creator update-config xlsx)

# The plugins whose skills and MCP tools no slot has called. A repo with a Cloudflare config keeps the cloudflare one.
PROFILE_PLUGINS_OFF=(obsidian@obsidian-skills cloudflare@claude-plugins-official)
PROFILE_CLOUDFLARE_PLUGIN=cloudflare@claude-plugins-official
# Where the account's Cloudflare repos keep a config: at the root, or one or two directories down.
PROFILE_CLOUDFLARE_DEPTH=3

# Usage: profile_cloudflare <dir>; true when the directory holds a wrangler.toml, wrangler.json or wrangler.jsonc within
# PROFILE_CLOUDFLARE_DEPTH levels. It reads file names only: a foreign head's tree is never opened, and git, which a
# tracked fsmonitor setting could turn into a command, never runs.
profile_cloudflare() {
  [[ -n $(find "$1" -maxdepth "$PROFILE_CLOUDFLARE_DEPTH" \( -name node_modules -o -name .git \) -prune -o -type f \
    \( -name wrangler.toml -o -name wrangler.json -o -name wrangler.jsonc \) -print -quit 2>/dev/null) ]]
}

# Usage: profile_args <dir>; prints the flags that put a slot's Claude on the profile, ready to be typed into a shell.
# The names are fixed words with no quote or space, so the single-quoted object needs no escaping. A slot runs with idle
# compaction off because it waits on review for hours, then takes a short fix or ends: a 7-day replay at a 400k window
# put idle compaction at 1.6% more cost for slots and 54% more compactions, where it saved primes and generic sessions 8%.
profile_args() {
  local name overrides='' plugins='' tools=''
  for name in "${PROFILE_SKILLS_OFF[@]}"; do overrides+="\"$name\":\"off\","; done
  for name in "${PROFILE_PLUGINS_OFF[@]}"; do
    if [[ $name == "$PROFILE_CLOUDFLARE_PLUGIN" ]] && profile_cloudflare "$1"; then continue; fi
    plugins+="\"$name\":false,"
  done
  for name in "${PROFILE_TOOLS_OFF[@]}"; do tools+=" $name"; done
  printf '%s' "--settings '{\"idleCompaction\":false,\"skillOverrides\":{${overrides%,}},\"enabledPlugins\":{${plugins%,}}}' \
--disallowedTools$tools"
}
