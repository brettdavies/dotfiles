---
title: Dev Server Access from the Mac - Plan
type: feat
date: 2026-11-02
topic: dev-server-access-from-the-mac
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Dev Server Access from the Mac - Plan

## Goal Capsule

- **Objective:** A dev server that the operator or an agent runs on the Linux server opens in the Mac's browser without
  anyone keeping a list of port numbers, and everything that works against a localhost origin today keeps working.
- **Product authority:** the operator. Exploration is deferred until the Rex cutover (U10 of
  `docs/plans/2026-10-29-2303-feat-rex-agent-slots-on-linux-server-plan.md`) is done.
- **Open blockers:** the five questions under Resolve Before Planning. Planning waits on them.

---

## Product Contract

### Summary

Replace the tunnel's fixed list of forwarded ports with access by name, so a new dev server or a second copy of one
needs no dotfiles change. Two candidates are on the table: portless on the Linux server behind the existing tunnel, and
a Tailscale Service. Phone access is an open question.

### Problem Frame

Dev servers run on the Linux server, and the operator browses them from the Mac. The `bd-tunnel` LaunchAgent holds a
fixed set of the Mac's localhost ports (3000, 5173, 8080, 8787-8789, 8976, 9229) and forwards each to the same port on
the Linux server's localhost. That keeps localhost semantics, but every new port is a dotfiles edit, and the numbers
carry no meaning. Port 8080 is not even free: on the Linux server it is `codex-proxy`, which
`scripts/tailscale-serve-setup.sh` also serves as `svc:codex-proxy`.

Parallel agent slots make fixed ports worse. Two slots of one repo start the same dev script on the same port, and a
slot can measure another agent's build without noticing
(`docs/solutions/workflow-issues/dev-server-port-handed-to-a-parallel-agent-can-already-be-held-by-another-agents-server.md`).
The phone can reach no dev server at all.

### Requirements

**Access from the Mac**

- R1. A dev server started on the Linux server is reachable from the Mac's browser without a dotfiles change for its
  port.
- R2. Flows that depend on a localhost origin keep working from the Mac: OAuth redirect URIs registered to localhost,
  secure-context browser features, and dev-server host checks.

**Exposure**

- R3. No service that listens only on the Linux server's loopback (Ollama, `codex-proxy`, qmd, and the like) becomes
  reachable from another device as a side effect of this work.

### Key Decisions

- **Explore and plan this after the Rex cutover.** (session-settled: user-approved — chosen over planning it now in a
  parallel slot and over dropping it: the cutover holds priority today.)
- **The Mac keeps a localhost origin for dev servers.** This carries forward the Rex plan's decision that dev ports stay
  on the Mac's localhost through a tunnel, "for now"; this work is where "for now" gets revisited. Governs R2.

### Approaches Under Consideration

| Approach                                                             | How it reaches the Mac                                                                                                   | Keeps localhost (R2)             | Loopback exposure (R3)              | Phone |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | -------------------------------- | ----------------------------------- | ----- |
| A. Tunnel + portless                                                 | portless proxy on the Linux server routes `<name>.localhost` to each dev server; the tunnel carries the proxy's one port | Yes                              | None (the proxy binds loopback)     | No    |
| B. Tailscale Service, one endpoint per port                          | `tailscale serve --service=svc:dev --https=<port>` per dev port                                                          | No: the origin is a tailnet name | Per declared port only              | Yes   |
| C. Tailscale Service, all ports                                      | Linux-only layer-3 `--tun` endpoint plus iptables DNAT to loopback and `route_localnet`                                  | No                               | Every loopback port the DNAT covers | Yes   |
| D. A plus one Tailscale HTTPS Service in front of the portless proxy | The Mac as in A; other devices through the Service                                                                       | Yes on the Mac                   | One endpoint                        | Yes   |

D is the agent's current lean, not a decision: A meets R1-R3 for the Mac, and one Service adds the phone without
reopening every port. B and C give up R2: OAuth callbacks registered to localhost stop matching, Vite rejects an unknown
Host until `allowedHosts` names it, wrangler dev's Host rewriting applies, and plain HTTP on a non-localhost name is not
a secure context. MagicDNS has no wildcard subdomains, so per-app names under Tailscale need one Service per app.

### Scope Boundaries

- The Rex cutover and the tunnel's role as the Mac's always-on forwarder are out of scope; this work changes what the
  tunnel carries, not whether it exists.
- Production and staging deploys are out of scope; this is local development only.
- Services that are not dev servers (Ollama, `codex-proxy`, qmd) are out of scope except as R3 protects them.

### Dependencies / Assumptions

- The `bd-tunnel` LaunchAgent (`stow/launchagent`, host entry in `stow/ssh`) is deployed on the Mac.
- Agent slots are full clones, not git worktrees, so portless's per-worktree name prefix does not separate two slots of
  one repo.
- portless is pre-1.0 and its state format can change between releases. Homebrew ships 0.15.13 (2026-11-01), inside the
  7-day supply-chain gate until 2026-11-08.

### Outstanding Questions

**Resolve Before Planning**

- Which approach: A, B, C, D, or another?
- Is reaching dev servers from the phone or another tailnet device a goal of this work, or a later one?
- Are port-free URLs (`https://pronto.localhost`) worth binding port 443 on both machines, given the Mac's unprivileged
  `ssh` cannot bind loopback below 1024 (root or a `pf` redirect), or is one fixed port for every app
  (`pronto.localhost:1355`) enough?
- Should each agent slot get its own dev-server names (for example `dotfiles-2.pronto`) so parallel slots never share an
  address?
- TLS: trust a CA generated on the Linux server on the Mac, or serve plain HTTP and rely on `.localhost` counting as a
  secure context?

**Deferred to Planning**

- Per repo, whether the dev script is split so portless can inject the port, or the server keeps a fixed port behind
  `portless alias`. Today ingest-lab's `dev` runs `concurrently` over `bun run server` and `vite`, its `worker:dev` is
  `bun run build && wrangler dev`, and agentnative-site's `dev` is
  `bun run build && wrangler dev --env staging --local --port 8787`. portless leaves all three alone because they are
  compound.
- An inventory of OAuth apps whose redirect URIs name `localhost:<port>`. Google and Apple reject `.localhost`; they
  need portless's `--tld` with a real domain.
- Whether Safari on the Mac resolves `.localhost` subdomains. portless writes `/etc/hosts` only on the machine that runs
  the proxy.
- The proxy's systemd user unit lives in dotfiles, not in `portless service install`'s generated unit.
- Which portless version and install channel clear the 7-day gate.
- Whether port 8080 leaves the tunnel's list, since it reaches `codex-proxy`.

### Sources / Research

- portless README, https://github.com/vercel-labs/portless: one proxy routes `<name>.localhost` to apps on random ports
  4000-4999 given through `PORT`. It injects `--port` for Vite, Astro, React Router, Angular, Expo and React Native, and
  `--port` with `--ip` for Wrangler. Next, Express and Nuxt read `PORT`. Scripts with `&&`, `|`, `;`, an env prefix, or
  delegation to another script are left alone. Outside LAN mode the proxy binds only loopback.
- Tailscale Services, https://tailscale.com/kb/1552/tailscale-services: endpoints are declared per port (`tcp:`,
  `https:`), and only the Linux layer-3 `--tun` endpoint forwards every port.
- `docs/solutions/integration-issues/wrangler-dev-rewrites-request-host-to-route-set-dev-host.md`: wrangler dev hands
  the Worker the route's hostname when routes are declared; set `dev.host`.
- `docs/solutions/security-issues/node-http-server-without-hostname-listens-on-every-interface.md`: dev servers bind
  loopback, which C would have to work around.
- `scripts/tailscale-serve-setup.sh`: the Linux server's existing Services, `svc:ollama` and `svc:codex-proxy`.
