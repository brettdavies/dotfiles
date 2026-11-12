# OpenSEO on the Linux server

OpenSEO is a self-hosted SEO research and site-audit tool (`every-app/open-seo`, MIT). Its standalone Docker edition is
a five-container Compose stack. This repo vendors that stack in `config/openseo/`, runs the app image at upstream's
rolling `0` tag, and `scripts/openseo-deploy.sh` renders its secrets from 1Password and runs it. The stack publishes one
nginx port on loopback (8946). The Tailscale Service `svc:openseo` is the only way in:
`https://openseo.<tailnet>.ts.net`, reachable from inside the tailnet and nowhere else.

## Who runs what

| Step                                                                    | Who                          |
| ----------------------------------------------------------------------- | ---------------------------- |
| `up`, `down`, `create-admin` (they run `docker`)                        | the operator, never an agent |
| tailnet policy edits, `sudo systemctl` restarts                         | the operator                 |
| `render`, `serve` (no docker; `serve` changes what the tailnet can see) | the operator                 |
| `status` (no docker, no sudo; read-only)                                | the operator or any agent    |
| `status --host nas` (ssh to the NAS; no docker; read-only)              | the operator or any agent    |
| Google Cloud and Search Console setup, creating the DataForSEO account  | Brett, on his own decision   |

If `docker` answers `permission denied` on its socket, run a command through the group: `sg docker -c '<command>'`.

Limits that hold for every step here: nothing writes to anc.dev, its repo, Cloudflare, DNS, Search Console, or Bing
Webmaster, and nothing submits a sitemap or an IndexNow ping. No new account, key, or spend starts without Brett's
decision.

## One-time setup

### 1Password items

`render` and `create-admin` read two items in the `secrets-dev` vault by UUID. They exist; the UUIDs are in the header
of `scripts/openseo-deploy.sh`. To check one without revealing it:

```bash
~/.claude/skills/1password/scripts/get_item.sh tdkhy4vi4ijxryxihwb4xdjowy   # OpenSEO - Storage Secret (openseo)
~/.claude/skills/1password/scripts/get_item.sh hwacawam6ghon7c4tlxswldzye   # OpenSEO - Admin Login (openseo)
```

`render` also reads three optional items by the UUIDs in the same header: DataForSEO API Key, OpenSEO - Google OAuth Client
(openseo), and OpenRouter API Key - OpenSEO. `OPENSEO_DATAFORSEO_ITEM`, `OPENSEO_GOOGLE_ITEM`, and
`OPENSEO_OPENROUTER_ITEM` override their UUIDs, and an empty value skips the item and renders its keys empty.

To rebuild a lost item, use `create_item.sh`. Rebuilding the storage item gives it a new value, so do it only for a host
with no volumes and no env file; with existing data, recover the old value from the item's 1Password history instead
([storage-key-changed](#storage-key-changed)). A new item has a new UUID, which goes into the script's header.

```bash
~/.claude/skills/1password/scripts/create_item.sh --category PASSWORD --title "OpenSEO - Storage Secret (openseo)" \
  --tags "dev,dotfiles,openseo" --hostname "openseo.internal" --generate-password=letters,digits,64 \
  --notes "RustFS secret key for the OpenSEO Docker stack, rendered as STORAGE_SECRET_KEY by scripts/openseo-deploy.sh; the access key is the constant openseo. Never rotate: upstream restores only with the same storage credentials."

~/.claude/skills/1password/scripts/create_item.sh --category LOGIN --title "OpenSEO - Admin Login (openseo)" \
  --tags "dev,dotfiles,openseo" --hostname "openseo.internal" --field "username[text]=admin@openseo.internal" \
  --generate-password=letters,digits,32 \
  --notes "OpenSEO administrator account, created by scripts/openseo-deploy.sh create-admin from the host before the tailnet address binds. Sign in at the svc:openseo address."
```

### Tailnet policy

A Tailscale Service is defined, granted, and approved in that order, and no script on a host can assert the first and
last steps. All of these use the `tailscale` skill's `ts-api.sh`. The commands read the admin API with the key from
1Password and change tailnet policy, so the operator runs them.

1. Find the tag existing services carry and the tag the Linux server carries:

   ```bash
   ~/.claude/skills/tailscale/scripts/ts-api.sh service-get svc:ollama
   ~/.claude/skills/tailscale/scripts/ts-api.sh devices --verbose
   ```

2. Define the service on `tcp:443` with the service tag from step 1:

   ```bash
   ~/.claude/skills/tailscale/scripts/ts-api.sh service-set svc:openseo --port tcp:443 --tag tag:<service-tag> \
     --comment "OpenSEO SEO research and audit tool"
   ```

3. Add a grant and an autoApprover to the policy, then validate and apply it. The grant lets Brett's devices and the
   Linux server's tag reach the address; any process on the Linux server, agent slots included, can then reach the
   sign-in page, which is why sign-in stays on. Fetch the policy to a file:

   ```bash
   acl=$(mktemp) && ~/.claude/skills/tailscale/scripts/ts-api.sh acl > "$acl"
   ```

   Edit `$acl` by hand. Under `"grants"` add:

   ```json
   { "src": ["autogroup:member", "tag:<host-tag>"], "dst": ["svc:openseo"], "ip": ["tcp:443"] }
   ```

   Under `"autoApprovers"` > `"services"` add the next line, unless a tag-keyed entry already covers the service tag:

   ```json
   "svc:openseo": ["tag:<host-tag>"]
   ```

   Then validate, and apply only when validation reports no error:

   ```bash
   ~/.claude/skills/tailscale/scripts/ts-api.sh acl-validate "$acl"
   ~/.claude/skills/tailscale/scripts/ts-api.sh acl-apply "$acl"
   ```

   `ts-api.sh` posts the file as `application/json`, and the policy is HuJSON. A policy with comments or trailing commas
   can fail `acl-validate` with a parse error; nothing has been applied when it does. Stop there rather than working
   around it with a raw request, and take the fix to the `tailscale` skill.

4. After the first bind (below), confirm the host is approved:

   ```bash
   ~/.claude/skills/tailscale/scripts/ts-api.sh service-hosts svc:openseo
   ```

   An autoApprover judges a fresh advertisement only. If the host stays pending after a policy change, drop and re-add
   the binding: `tailscale serve --service=svc:openseo --https=443 off`, then `scripts/openseo-deploy.sh serve`.

## First deploy

Run from the canonical checkout, with the timing the Gate A note records:

```bash
cd ~/dotfiles && git pull
gtime -f '%e s' scripts/openseo-deploy.sh up
gtime -f '%e s' scripts/openseo-deploy.sh create-admin
scripts/openseo-deploy.sh status
```

- `up` renders `~/.config/openseo/local.env` (mode 600) and pulls the pin's image (about 115 MiB). It then turns the
  `svc:openseo` binding off, so the address stays dark for the whole `up` and a restart cannot leave a first-visitor
  sign-up bound. It starts the stack and force-recreates `init`, `web`, and `crawl-gateway`. Compose holds each
  `docker compose up -d` until `init` exits, which takes about two minutes, twice; each call is cut off after 360 s.
  `up` prints the command that follows the log (`docker compose logs -f init`), reads the log once afterwards for
  `OpenSEO initialized and ready.`, and waits up to 30 s for `/api/health`. It then tries to bind the address; with no
  account yet it stops and names `create-admin`.
- `create-admin` makes the first account from the host with upstream's operator command, reading the password from the
  admin item on stdin. That closes registration, so the gate passes and `create-admin` binds the address. It prints the
  address, the item to sign in with, and the next step. A binding still standing when it starts, with no account
  behind it, is turned off first.
- `status` exits 0 when the stack, the service, its binding, and the address are healthy. It prints `NOTE:` lines for
  anything worth knowing, such as this host being unable to reach its own service address. With `--output json`, a
  failure's `next_step.action` is `ask-operator`: the command names the operator's verb, and an agent does not run it.

Expected: `up` ends with `init finished: OpenSEO initialized and ready.` and a `NOTE:` naming `create-admin`;
`create-admin` prints `bound: https://openseo.<tailnet>.ts.net` and then the sign-in item; `status` exits 0.

### Checks after the first deploy

1. Reach. From the Mac, the address shows OpenSEO's sign-in page and signing in with the admin item works. From another
   LAN host, `curl --max-time 5 http://<the Linux server's LAN address>:8946/` is refused.
2. Restarts, each followed by `scripts/openseo-deploy.sh status` that exits 0 with no `up` or `serve` between. After a
   Docker restart give the stack a minute to come back before reading `status`.

   ```bash
   sudo systemctl restart docker
   sudo systemctl restart tailscale-serve-setup.service
   ```

3. Compose shape. This one runs `docker compose config` over the vendored file, so it is the operator's:
   `OPENSEO_TEST_DOCKER=1 scripts/run-tests tests/openseo-deploy.bats`.
4. The Gate A note. Write what happened, the two timings, and anything unexpected to a file in the prime checkout's
   `.context/` for Brett.

## Run on the NAS

On the NAS, OpenSEO is the Unraid Compose Manager stack `openseo`, so its five containers show in the Docker tab as a
Compose Stack, never as "3rd Party". `--host nas` drives that stack from the Linux server over ssh: `up` writes the stack
folder and starts it with the plugin's own `compose.sh`, `down` stops it with the same script, `create-admin` runs
upstream's operator command in the stack's `runtime` container, and the other verbs read the running stack. Compose
here reads the vendored file and `~/.config/openseo/nas.env` and reaches the NAS's Docker daemon through
`DOCKER_HOST=ssh://pool`, always with `-p openseo`; the loopback checks and `tailscale serve` run on the NAS through
`ssh pool`. The script's ssh calls carry `-o BatchMode=yes -o ConnectTimeout=10`. `OPENSEO_NAS_SSH=<alias>` names another
ssh alias. `--host nas` goes before or after the verb: `scripts/openseo-deploy.sh --host nas serve` and
`scripts/openseo-deploy.sh serve --host nas` are the same command, and the error messages print the first form.

This section is a fresh install: the stack gets empty volumes and no data moves. The NAS has 7.5 GiB of memory and no
swap, so an overrun there ends in the kernel's OOM killer, and its 20 GiB `docker.img` is shared by every container on
it.

### Before the first `--host nas` verb

1. `ssh pool 'test -x /usr/local/emhttp/plugins/compose.manager/scripts/compose.sh && docker version && curl --version && tailscale version'`
   answers from the Linux server without a prompt. Every `--host nas` verb, `render` included, starts by running its
   share of it, and stops with [nas-unreachable](#nas-unreachable) when it fails. Only `up` and `down` need the plugin's
   `compose.sh`, so only they test for it; `status` runs no docker, so its check leaves `docker version` out.
2. `svc:openseo` is defined, granted, and approved for the NAS. Follow [Tailnet policy](#tailnet-policy) with the NAS's
   tag from `ts-api.sh devices --verbose` as the `autoApprovers` entry, unless a tag-keyed entry already covers the
   service tag. Keep the Linux server's tag in the grant, so `status` reaches the address from there.
3. No other host advertises `svc:openseo`. One at a time: a host that already advertises it drains the service first,
   and only then does the NAS bind. Turning the binding off with `--https=443 off` is not enough, because the host keeps
   advertising the service. The script does not look for another advertiser. On the host that has it (the Linux server,
   when it ran the stack):

   ```bash
   tailscale serve drain svc:openseo
   scripts/openseo-deploy.sh down
   trash ~/.config/openseo/local.env
   ```

   `drain` ends the advertisement. `down` stops the stack and keeps its volumes. Without `local.env`,
   `tailscale-serve-setup.service` skips its OpenSEO block, so the next tailscaled start does not bind it again; that host's
   data does not move to the NAS.

### What `up --host nas` writes

The stack folder is `openseo` under `PROJECTS_FOLDER`, which `up` reads from
`/boot/config/plugins/compose.manager/compose.manager.cfg` on the NAS and which defaults to
`/boot/config/plugins/compose.manager/projects`. One ssh call writes everything, with the files on its stdin under
`umask 077`, so no secret is in an argument list.

- A folder that does not exist yet gets `name` (`OpenSEO`), `project_name` (`openseo`), `description`, `autostart`
  (`true`), `icon_url` (the OpenSEO app icon, a PNG at a pinned commit of upstream's repository), and `webui_url` (the
  address from `nas.env`'s `BETTER_AUTH_URL`, with a trailing slash) in that same call. An open dashboard writes `name`
  and `project_name` into any folder it finds, so they cannot wait for a second call.
- Every `up` replaces `compose.yaml` (upstream's file, checked against the pin's sha256 before anything is written),
  `compose.override.yaml` (`config/openseo/compose.override.yaml`: the label `net.unraid.docker.managed: composeman` and an
  empty icon, webui, and shell on each of the five services, except that `web`'s `net.unraid.docker.webui` is
  `nas.env`'s `BETTER_AUTH_URL` with a trailing slash), and `.env` (a copy of `nas.env`). The tracked override holds
  `@WEBUI_URL@` for that address, because no tracked file holds the tailnet's name; `up` fills it in from `nas.env` as
  it writes the file, so a `web` label edited in the dashboard is replaced by the next `up`.
- Each of the three is written under a new name and moved into place, so an `.env` that already exists ends up mode 600
  on a filesystem that keeps modes, and a dropped connection leaves the old file whole.
- It never rewrites `name`, `project_name`, `description`, `autostart`, `icon_url`, `webui_url`, or a file the dashboard
  owns (`last_result.json`, `started_at`, `has_build`) in a folder that exists, so an `icon_url` or `webui_url` changed
  in the dashboard stays.

The `.env` holds the generated storage secret and the provider keys. The NAS's flash does not enforce file modes, so
treat `.env` as readable by anyone who can read the flash; `nas.env` here stays mode 600.

`up` then turns the `svc:openseo` binding off and runs
`compose.sh -cup --recreate -popenseo -f<dir>/compose.yaml -f<dir>/compose.override.yaml -e<dir>/.env -s<dir>`, the
command the dashboard runs, with its recreate option. Every service is recreated, so settings reach `init`, `web`, and
`crawl-gateway`. There is no separate pull step: the plugin pulls an image the NAS lacks and no newer release of one it
has, so [Update OpenSEO](#update-openseo) is how a newer release arrives. A pull failure is [up-failed](#up-failed).
`up` waits for `init`, then for `/api/health`, and tries to bind the address.

### Fresh install

```bash
cd ~/dotfiles && git pull
gtime -f '%e s' scripts/openseo-deploy.sh up --host nas
gtime -f '%e s' scripts/openseo-deploy.sh create-admin --host nas
scripts/openseo-deploy.sh status --host nas
```

These are the steps of [First deploy](#first-deploy) on the NAS. `up --host nas` renders `nas.env` here (mode 600),
writes the stack, starts it, waits for `init`, and ends with a `NOTE:` naming
`scripts/openseo-deploy.sh --host nas create-admin`. `create-admin --host nas` makes the first account in the stack's
`runtime` container, which closes registration, and binds `svc:openseo` from the NAS. Then sign in and create the
project as in [First read-only run](#first-read-only-run). If the stack's own sign-in page is needed before the address
binds, tunnel the NAS's loopback: `ssh -L 8946:127.0.0.1:8946 pool`.

### Start, stop, and change settings

- The dashboard's Compose Manager tab starts and stops the stack with the same `compose.sh`, and `autostart` starts it
  with the array. The script does the same: `up --host nas` starts it and `down --host nas` runs
  `compose.sh -cstop`, which stops the containers and keeps them, the volumes, the generated secrets, `nas.env`, and the
  stack folder. A start from the dashboard leaves the `svc:openseo` binding as it was; `status --host nas` shows whether it
  stands.
- An env change reaches the NAS in two steps. `render --host nas` rewrites `nas.env` here and touches nothing on the
  NAS; `up --host nas` then copies it to the stack's `.env` and recreates every service.
- The address moves between hosts with `tailscale serve drain svc:openseo` on the host that has it. `--https=443 off`
  only removes the binding, and the host stays in the service's host list.

### What `status` shows

`status --host nas` runs the loopback gate, the `CapMap` check, and the binding check on the NAS through ssh, with no
docker, and fetches the tailnet address from the Linux server. It prints
`OK: OpenSEO is up at https://openseo.<tailnet>.ts.net` and one `ok:` line each for `loopback`, `service`, `binding`,
and `address`, and exits 0, with a `NOTE:` that names `up` when the env file here names an image other than the pin's. A
refused address exits 1 with [address-unreachable](#address-unreachable) and the fix
`scripts/openseo-deploy.sh --host nas serve`; a NAS whose loopback is down exits 1 with [unhealthy](#unhealthy) and the
fix `scripts/openseo-deploy.sh --host nas up`; an unreachable NAS exits 1 with [nas-unreachable](#nas-unreachable).
Plain `status` on a host with `nas.env` and no `local.env` checks only the address and names the `--host nas` fix. After
the NAS restarts, run `status --host nas`: `autostart` brings the stack back, and a tailscaled restart there drops the
binding.

### Stop it

```bash
ssh pool tailscale serve drain svc:openseo
scripts/openseo-deploy.sh down --host nas
```

The first command ends the advertisement; `down --host nas` stops the stack and keeps the volumes, the generated
secrets, `nas.env`, and the stack folder. `up --host nas` starts it again. No verb removes the volumes.

## Update OpenSEO

The app image is `ghcr.io/every-app/open-seo-standalone:0`, the tag upstream moves to each 0.x release, so a pull takes
the newest release with no cooldown. RustFS and nginx stay pinned by digest, as upstream's compose file has them.
`latest` is not used: it follows upstream's main branch and moves with every merge there.

### Before updating

Upstream's migrations only go forward, and no backup exists yet, so pulling an older image does not undo a bad release.

The Update button refreshes images only, so the vendored `config/openseo/compose.yaml` stays at the commit the pin
records. This command compares it with the file in upstream's latest release and prints nothing when they match:

```bash
cd ~/dotfiles && diff <(gh api -H 'Accept: application/vnd.github.raw+json' "repos/every-app/open-seo/contents/deploy/standalone/compose.yaml?ref=$(gh api repos/every-app/open-seo/releases/latest --jq .tag_name)") config/openseo/compose.yaml
```

A difference means the vendored file lags upstream. Open a PR that re-vendors the file and updates the pin's `tag`,
`commit`, and `sha256` lines, merge it, and update with the re-vendor step below, because updating first runs a
release's migrations against the older file.

### Update

- **NAS.** The Update button reads the stack's own `.env`, which only `up --host nas` writes, so run
  `scripts/openseo-deploy.sh status --host nas` first. If it prints the image `NOTE:`, run
  `scripts/openseo-deploy.sh up --host nas`: it writes the pin's image into the stack's `.env` and pulls an image the
  NAS lacks. Otherwise press Update for the `openseo` stack in the dashboard's Compose tab: it pulls the newest 0.x
  release and recreates the stack. Then run `status --host nas` again.
- **Linux server.** `scripts/openseo-deploy.sh up` pulls the newest 0.x release and recreates `init`, `web`, and
  `crawl-gateway`. Then run `scripts/openseo-deploy.sh status`.
- **After a re-vendor PR merges.** On the NAS, pull the image first, so one recreate runs the new file with the new
  release: `ssh pool docker pull ghcr.io/every-app/open-seo-standalone:0`, then
  `scripts/openseo-deploy.sh up --host nas`. On the Linux server, `up` pulls and recreates in one run.

### After updating

A pull can leave the replaced image on disk with no tag. List the images, and remove each row whose TAG is `<none>` by
its ID, because the NAS's `docker.img` is 20 GiB shared by every container on it:

```bash
docker image ls ghcr.io/every-app/open-seo-standalone
docker image rm IMAGE_ID
```

Replace `IMAGE_ID` with the ID on that row. On the NAS, put `ssh pool` before each command. Never use
`docker image prune`: it removes every untagged image, and LanguageTool keeps a replaced image on purpose.

## First read-only run

Sign in, then create the project `anc.dev`. OpenSEO starts a 50-page site audit by itself, with Lighthouse `none` and no
JavaScript rendering. It makes no DataForSEO call, reads anc.dev's public pages from this host's public IP, and
identifies itself by the `OpenSEO-Audit/1.0` User-Agent. A full-site audit of up to 250 pages with the same settings may
follow. If Cloudflare challenges the crawl, that is a finding for the note, never a reason to change Cloudflare.

Never click, and never enable:

- the IndexNow tool (`submit_indexnow_urls`) or anything that submits a sitemap or a URL;
- rank trackers and AI visibility, which are recurring work that spends;
- SAM, JavaScript rendering, API keys, and the MCP connection.

Afterwards check that nothing listed in the limits above shows a change, and that DataForSEO spend stays within the
account's signup credit.

## Search Console

OpenSEO connects Search Console through an OAuth client of Brett's own, read-only. Brett does the first six steps in the
Google Cloud console and Search Console; the seventh happens in OpenSEO at the first deploy.

1. In a Google Cloud project Brett owns, enable the Search Console API.
2. Set the OAuth consent screen to External and publish it to production. A client left in testing loses its refresh
   token after 7 days.
3. Create a Web application OAuth client whose only authorized redirect URI is
   `https://openseo.<tailnet>.ts.net/api/gsc/oauth/callback`. The address survives a move between hosts, so the client
   never changes.
4. Grant it `https://www.googleapis.com/auth/webmasters.readonly` as its only Google API scope. OpenSEO requests it with
   the identity scopes `openid`, `email`, and `profile`, none of which can change Search Console. Do not add the
   Analytics scope.
5. Confirm Brett's Google account has access to the anc.dev property in Search Console. Adding it, if it is missing, is
   his own change there.
6. Store the client in `secrets-dev` as `OpenSEO - Google OAuth Client (openseo)`, an API Credential with `client_id` as
   text and `client_secret` concealed. The script's header names the item's UUID (`OS_GOOGLE_ITEM`); setting
   `OPENSEO_GOOGLE_ITEM=` to the empty string makes `render` leave both keys empty and say so.
7. After `render` and `up` have applied the keys, sign in, open Integrations, connect with Google, and bind the anc.dev
   property. OpenSEO shows its clicks and impressions.

The DataForSEO key works the same way: Brett creates the account with no automatic top-up and stores the Base64
credential in an item named `DataForSEO API Key` (field `credential`), whose UUID the header names as
`OS_DATAFORSEO_ITEM`. The OpenRouter key is the item `OpenRouter API Key - OpenSEO` (field `credential`), named by
`OS_OPENROUTER_ITEM`; `render` writes it as `OPENROUTER_API_KEY` beside `OPENROUTER_MODEL`, the constant
`OS_OPENROUTER_MODEL` in the header.

## OpenSEO API keys

OpenSEO's API keys are rows in each install's own database, the `apikey` table in upstream's
`src/db/better-auth-schema.ts`. A key made on another install returns 401, and so does a key made before `svc:openseo`
moved to a host with a different install, because the two installs share no data. Make the key in the install you call.
A new key needs Brett's decision, like any new key (see the limits at the top).

## Troubleshooting

An error prints `ERROR: <reason>: <message>`, any `cause:` lines holding the failing command's last stderr, and a final
`fix:` line. `status --output json` prints the same error as one JSON object whose `next_step.docs` links to the
reason's heading below. Messages say whether a rerun is safe.

An error from a `--host nas` verb is about the NAS: read "this host" as the NAS, run the `fix:` line as printed
(`scripts/openseo-deploy.sh --host nas <verb>`), and run any `tailscale` command below as `ssh pool tailscale ...`.

### usage

The verb or an option is unknown. `scripts/openseo-deploy.sh --help` lists the verbs and marks the ones that run docker.

### tool-missing

A tool the verb needs is not on `PATH`: `jq`, `curl`, `tailscale`, or `docker`. On the Linux server `jq` and `curl` come
from Homebrew (`brew install jq`); Docker is installed with the machine.

### unsupported-host

Only the Linux server runs OpenSEO. `render` refuses on macOS before it reads a secret.

### pin-invalid

`config/openseo/openseo.pin` is malformed. The error names the line.
`git -C ~/dotfiles checkout -- config/openseo/openseo.pin` restores it; a hand edit must keep the shapes the parser
accepts: a `v` tag, a 40-hex commit, an image on `ghcr.io/every-app/open-seo-standalone` at a rolling tag of digits (`0`
or `0.1`; `latest`, `main`, a release tag, and a digest are refused), and the compose file's sha256.

### pin-mismatch

`config/openseo/compose.yaml` differs from the checksum the pin records. The file is upstream's, byte for byte, so
`git -C ~/dotfiles checkout -- config/openseo/compose.yaml` restores it.

### item-unreadable

A 1Password read failed. The error names the item's UUID and title. Check that the item exists and that the service
account reaches `secrets-dev` with `get_item.sh <uuid>` (it redacts secret fields). `render` changes nothing on this
error, so a rerun is safe. For the DataForSEO, Google, and OpenRouter items the message also names the variable that
skips the item: `OPENSEO_DATAFORSEO_ITEM=`, `OPENSEO_GOOGLE_ITEM=`, or `OPENSEO_OPENROUTER_ITEM=` set to the empty string
renders its keys empty.

### value-unsafe

A 1Password field holds a character an env file cannot carry safely, such as `$`. Change the field to letters, digits,
and `+ / = . _ : @ -`, then rerun `render`.

### storage-key-changed

The env file's storage credentials differ from the storage item's. Upstream restores a backup only into an installation
with the same storage credentials and documents no way to rotate them, so `render` refuses to change them. Put the
previous value back in the item from its 1Password history. Do not rotate it.

### tailscale-unavailable

`tailscale status --json` gave no MagicDNS suffix, so this host is logged out or tailscaled is down. The `cause:` lines
hold `tailscale status`. Run `tailscale up`, then retry.

### env-missing

This host has no `~/.config/openseo/local.env`. Run `scripts/openseo-deploy.sh render`. A host that retired OpenSEO has
none by design.

### pull-failed

`docker compose pull` failed for the pin's image tag. The `cause:` lines show Docker's message. Check that GHCR answers
for the tag with `docker pull ghcr.io/every-app/open-seo-standalone:0`, then rerun `scripts/openseo-deploy.sh up`;
nothing was started.

### up-failed

`docker compose up` failed for a reason other than `init`, or under `--host nas` the plugin's `compose.sh -cup` did, which
includes an image it could not pull. The `cause:` lines show why. Rerun
`scripts/openseo-deploy.sh up`, which is safe.

### init-failed

`init` exited non-zero, exited without printing its ready line, or kept a `docker compose up -d` waiting past 360 s.
Read its log with the command on the `fix:` line. The runtime needs a kernel with 4 KiB memory pages and about 4 GiB of
memory for Docker. Rerun `scripts/openseo-deploy.sh up` once the cause is fixed.

### stop-failed

`docker compose stop` failed, or under `--host nas` the plugin's `compose.sh -cstop` did. The `cause:` lines show why.
Rerun `scripts/openseo-deploy.sh down`.

### unhealthy

The message names the endpoint it asked, `/api/health` or `/api/sign-up-status`, and what it answered. A stack that is
stopped, still starting, or failing a check answers `/api/health` with something other than `status: ok`; one whose
`/api/sign-up-status` gives no boolean `firstAccount` cannot be judged safe to bind. Wait a minute, then
`scripts/openseo-deploy.sh up` if it stays down. `down` leaves the binding in place, so the tailnet address answers with
an error until `up` runs; `up` turns the binding off first and binds again once the gate passes.

### first-account-open

OpenSEO has no account, so its first visitor would become administrator. The address stays unbound until
`scripts/openseo-deploy.sh create-admin` makes the account. `status` raises this error when the service is, or may still
be, bound, for instance because `tailscale serve status` could not be read; `scripts/openseo-deploy.sh serve` turns the
binding off.

### account-exists

OpenSEO already has an account, and `create-admin` makes only the first. The first account may not be yours: before
`serve`, sign in at `http://127.0.0.1:8946` with the admin item. Once it works, run `scripts/openseo-deploy.sh serve` to
bind the address. If it fails, someone else registered first; do not bind. Further accounts come from invitations in
OpenSEO's Team settings.

### create-admin-failed

Upstream's operator command failed; the `cause:` lines hold its message. Read the runtime log with the command on the
`fix:` line. No account is known to exist, so `create-admin` can be rerun.

### bind-failed

`tailscale serve` could not bind `svc:openseo`, or `status` found the service advertised with no binding on this host
(or `tailscale serve status` could not be read), so peers time out. Check that tailscaled is up and that this user is
the Tailscale operator, then rerun `scripts/openseo-deploy.sh serve`.

### unbind-failed

OpenSEO has no account, or `up` is about to start the stack, and the service is bound or its serve config cannot be
read, and turning the binding off failed. The `cause:` lines hold tailscale's message. Run the command on the `fix:`
line by hand; until it succeeds, anyone with a grant can create the administrator account. `up` starts nothing while
this stands.

### service-not-advertised

The binding exists, but the control plane does not list this host for `svc:openseo`. The service is not defined,
granted, or approved. Follow [Tailnet policy](#tailnet-policy), then `scripts/openseo-deploy.sh serve`.

### address-unreachable

`status` could not fetch the tailnet address from a host that does not run OpenSEO. On the host that does, run
`scripts/openseo-deploy.sh status`, and `scripts/openseo-deploy.sh serve` if the service is unbound.

### nas-unreachable

A `--host nas` verb could not run `ssh pool 'docker version && curl --version && tailscale version'` (or the alias in
`OPENSEO_NAS_SSH`; `status` leaves out `docker version`, and `up` and `down` start with
`test -x /usr/local/emhttp/plugins/compose.manager/scripts/compose.sh`) from this host, so it changed nothing, read nothing from
1Password, and started nothing. The `cause:` lines hold what ssh or the NAS's shell said. Run the command by hand to see
the failure: the key is not loaded, the alias is missing from `~/.ssh/config`, the NAS is off, its Docker service is
stopped, the Compose Manager plugin is not installed (the `cause:` line then says so), or `docker`, `curl`, or `tailscale`
is not on root's `PATH` there. Every verb is safe to rerun once it answers.

### stack-write-failed

`up --host nas` could not write the stack folder `openseo` under `PROJECTS_FOLDER` on the NAS, so it started nothing and
changed nothing outside that folder. The `cause:` lines hold what the NAS's shell said. A rerun fails the same way until
the cause is fixed. The `fix:` line prints a command that shows `PROJECTS_FOLDER` from
`/boot/config/plugins/compose.manager/compose.manager.cfg` (default `/boot/config/plugins/compose.manager/projects`) and
whether the flash is mounted read-write. Check that the folder is a directory and that the mount is `rw`, then rerun
`scripts/openseo-deploy.sh --host nas up`; the files it replaces are the same every time.

## Reporting problems upstream

OpenSEO's bugs go to its GitHub issues, `https://github.com/every-app/open-seo/issues`. A security problem goes through
the process in its `SECURITY.md`. A problem in this repo's scripts goes in this repo's issues.
