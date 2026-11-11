os_help() {
  cat <<'EOF'
usage: openseo-deploy.sh [--host nas] VERB [--output json]

Runs OpenSEO's Docker stack on this host (the Linux server) and binds it to the tailnet service svc:openseo.

  render        write ~/.config/openseo/local.env from 1Password and the pin; no docker
  up            [operator: docker] render, pull, start, wait for init, then serve
  down          [operator: docker] stop the stack; the volumes and generated secrets stay
  create-admin  [operator: docker] make the first account from the host, then serve
  serve         bind svc:openseo once OpenSEO is healthy and has an account; no docker
  status        check OpenSEO is up; no docker and no sudo, so any agent may run it

  --host nas    [operator: docker, ssh] run the verb on the NAS's Docker daemon (DOCKER_HOST=ssh://pool, or the alias in
                OPENSEO_NAS_SSH) with ~/.config/openseo/nas.env; before or after the verb. Nothing is written on the NAS.
                `status --host nas` runs no docker, only curl and tailscale over ssh, so any agent may run it.

--output json (status only) prints one JSON object with reason, exit_code, message, and next_step.
Exit codes: 0 success; 1 an error, printed as "ERROR: <reason>: <message>" and a "fix:" line; 2 a usage error.
Every reason has an anchor in docs/runbooks/openseo.md.
EOF
}
