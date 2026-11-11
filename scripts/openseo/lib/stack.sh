# The NAS's Unraid Compose Manager stack (--host nas): its folder under PROJECTS_FOLDER, written over ssh, and the plugin's
# own compose.sh, which the dashboard runs too, so the containers show as a Compose Stack. Every path below is on the NAS.
# shellcheck disable=SC2034,SC2016 # globals are shared through the sourcing script; the snippets run on the NAS, not here

OS_STACK=openseo
OS_STACK_NAME=OpenSEO
OS_STACK_DESCRIPTION='OpenSEO standalone stack, written by scripts/openseo-deploy.sh'
OS_OVERRIDE_FILE=$OS_REPO/config/openseo/compose.override.yaml
OS_COMPOSE_SH=/usr/local/emhttp/plugins/compose.manager/scripts/compose.sh
OS_PROJECTS_CFG=/boot/config/plugins/compose.manager/compose.manager.cfg
OS_PROJECTS_DEFAULT=/boot/config/plugins/compose.manager/projects
OS_EOF=OPENSEO_STACK_EOF

# Sets d on the NAS to this stack's folder: PROJECTS_FOLDER from the plugin's config, else the plugin's default.
os_stack_dir() {
  printf '%s' "d=\$(sed -n 's/^PROJECTS_FOLDER=\"\\{0,1\\}\\([^\"]*\\)\"\\{0,1\\}.*/\\1/p' $OS_PROJECTS_CFG 2>/dev/null | tail -n 1)" \
    "; d=\${d:-$OS_PROJECTS_DEFAULT}/$OS_STACK"
}

# The shell script the NAS runs from stdin. A new folder gets name, project_name, description and autostart in this one
# run, because an open dashboard writes name and project_name into any folder it finds; an existing folder keeps those
# four and every file the dashboard owns, and only the three files below are replaced.
os_stack_script() {
  local f
  printf 'set -e\numask 077\n%s\nif [ ! -d "$d" ]; then\n  mkdir -p "$d"\n' "$(os_stack_dir)"
  for f in "name:$OS_STACK_NAME" "project_name:$OS_STACK" "description:$OS_STACK_DESCRIPTION" autostart:true; do
    printf '  printf %%s %q >"$d/%s"\n' "${f#*:}" "${f%%:*}"
  done
  printf 'fi\n'
  for f in "compose.yaml:$OS_COMPOSE_FILE" "compose.override.yaml:$OS_OVERRIDE_FILE" ".env:$OS_LOCAL_ENV"; do
    printf 'cat >"$d/%s" <<'"'%s'"'\n' "${f%%:*}" "$OS_EOF"
    cat "${f#*:}"
    printf '%s\n' "$OS_EOF"
  done
}

os_stack_write() {
  os_try os_nas_ssh_in sh -s < <(os_stack_script) \
    || os_fail stack-write-failed "writing the Compose Manager stack $OS_STACK on the NAS failed; nothing was started; safe to rerun" "$OS_DEPLOY up"
}

# os_stack ACTION [OPTION...] runs the plugin's compose.sh on the NAS: up or stop. Its --recreate option recreates every
# service with all the stack's files, so a settings change reaches web and crawl-gateway and the labels survive.
os_stack() {
  local action=$1
  shift
  os_nas_ssh "$(os_stack_dir); exec $OS_COMPOSE_SH -c$action${*:+ $*} -p$OS_STACK -f\"\$d/compose.yaml\" -f\"\$d/compose.override.yaml\" -e\"\$d/.env\" -s\"\$d\""
}
