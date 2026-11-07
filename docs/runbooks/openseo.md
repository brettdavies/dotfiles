# OpenSEO on the Linux server

OpenSEO is a self-hosted SEO research and site-audit tool (`every-app/open-seo`, MIT). Its standalone Docker edition is
a five-container Compose stack. This repo vendors that stack in `config/openseo/` and pins the image by digest, and
`scripts/openseo-deploy.sh` renders its secrets from 1Password and runs it. The stack publishes one nginx port on
loopback (8946). The Tailscale Service `svc:openseo` is the only way in: `https://openseo.<tailnet>.ts.net`, reachable
from inside the tailnet and nowhere else.

## Who runs what

| Step                                                                    | Who                          |
| ----------------------------------------------------------------------- | ---------------------------- |
| `up`, `down`, `create-admin` (they run `docker`)                        | the operator, never an agent |
| tailnet policy edits, `sudo systemctl` restarts                         | the operator                 |
| `render`, `serve` (no docker; `serve` changes what the tailnet can see) | the operator                 |
| `status` (no docker, no sudo; read-only)                                | the operator or any agent    |
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

- `up` renders `~/.config/openseo/local.env` (mode 600) and pulls the pinned image (about 115 MiB). It then turns the
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
   text and `client_secret` concealed, and set the item's UUID in the script's header (`OS_GOOGLE_ITEM`). Until then
   `render` leaves both keys empty and says so.
7. After `render` and `up` have applied the keys, sign in, open Integrations, connect with Google, and bind the anc.dev
   property. OpenSEO shows its clicks and impressions.

The DataForSEO key works the same way: Brett creates the account with no automatic top-up, stores the Base64 credential
in an item named `DataForSEO API Key` (field `credential`), and sets the item's UUID in `OS_DATAFORSEO_ITEM`.

## Troubleshooting

An error prints `ERROR: <reason>: <message>`, any `cause:` lines holding the failing command's last stderr, and a final
`fix:` line. `status --output json` prints the same error as one JSON object whose `next_step.docs` links to the
reason's heading below. Messages say whether a rerun is safe.

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
accepts: a `v` tag, a 40-hex commit, an ISO release time, an image reference by digest only, and the compose file's
sha256.

### pin-mismatch

`config/openseo/compose.yaml` differs from the checksum the pin records. The file is upstream's, byte for byte, so
`git -C ~/dotfiles checkout -- config/openseo/compose.yaml` restores it.

### item-unreadable

A 1Password read failed. The error names the item's UUID and title. Check that the item exists and that the service
account reaches `secrets-dev` with `get_item.sh <uuid>` (it redacts secret fields). `render` changes nothing on this
error, so a rerun is safe.

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

`docker compose pull` failed for the pinned image. The `cause:` lines show Docker's message. Check that GHCR answers for
the digest in `config/openseo/openseo.pin`, then rerun `scripts/openseo-deploy.sh up`; nothing was started.

### up-failed

`docker compose up` failed for a reason other than `init`. The `cause:` lines show why. Rerun
`scripts/openseo-deploy.sh up`, which is safe.

### init-failed

`init` exited non-zero, exited without printing its ready line, or kept a `docker compose up -d` waiting past 360 s.
Read its log with the command on the `fix:` line. The runtime needs a kernel with 4 KiB memory pages and about 4 GiB of
memory for Docker. Rerun `scripts/openseo-deploy.sh up` once the cause is fixed.

### stop-failed

`docker compose stop` failed. Rerun `scripts/openseo-deploy.sh down`.

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

## Reporting problems upstream

OpenSEO's bugs go to its GitHub issues, `https://github.com/every-app/open-seo/issues`. A security problem goes through
the process in its `SECURITY.md`. A problem in this repo's scripts goes in this repo's issues.
