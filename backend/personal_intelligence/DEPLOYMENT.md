# Ubuntu deployment: Omi Personal Intelligence API

This runbook installs the owner-scoped API as a small, independently restartable
Ubuntu service. It does **not** install the standard Omi backend. It does not
change, restart, or depend on the privacy STT listener on `127.0.0.1:8766`, the
existing TLS gateway on `:8443`, the optional ledger on `:8791`, Memoria, or
Weaviate.

No deployment or Tailscale change was performed while preparing this runbook.
The final iOS-to-Ubuntu validation remains mandatory before the milestone can be
called complete.

## Architecture decision

The Ubuntu host was reachable over Tailscale during the read-only audit, but no
noninteractive SSH credential was available. The deployed context app and the
`pis-backend` utility therefore could not be inspected for their unit names,
language, dependency graph, lifecycle, or authentication boundary.

The in-repository alternatives are not safe server extension points:

- `desktop/context-for-claude` is a macOS-only Swift menu-bar application whose
  own README says it is standalone and not meant to be merged.
- `desktop/windows` on Linux is an Electron GUI tied to a logged-in graphical
  session and Omi cloud/Firebase authentication, not a headless private API.

The architecture decision for this release is therefore to keep the service
separate. An unverified process is not a safe extension point. Deployment still
requires the read-only compatibility audit below, but discovering a candidate
unit does not authorize folding this API into it. Any future integration with
`pis-backend` requires a separately reviewed change after its extension
contract, authentication, dependencies, restart boundary, and rollback have
all been verified. This service uses Python 3.11, FastAPI, SQLite, the loopback
Ollama API, and an in-process TimeTree client. It has no Firebase, Redis,
Firestore, Memoria, Weaviate, or privacy-STT dependency.

```text
iOS privacy app
  |  HTTPS inside the tailnet; bearer token + owner header
  v
Tailscale Serve :8444 (proposed, not applied)
  |
  v
127.0.0.1:8792  omi-personal-intelligence.service
  |-- TimeTree private HTTPS API
  |-- 127.0.0.1:11434 Ollama
  `-- /var/lib/omi-personal-intelligence/operations.sqlite3

Existing and unchanged:
Tailscale Serve :8443/live -> 127.0.0.1:8766 privacy STT
```

## Private API and authentication

The process refuses to bind outside loopback. Its local base URL is
`http://127.0.0.1:8792`. The proposed configurable iOS base URL is
`https://home-server.tailf58dfc.ts.net:8444`; this is an example deployment
value, not a hardcoded client default.

Every `/v1/*` request requires both headers:

```http
Authorization: Bearer <PIS_API_TOKEN>
X-PIS-Owner-Uid: <PIS_OWNER_UID>
```

The bearer token must contain 24-256 URL-safe characters; a 64-character
lowercase hex token is recommended. The owner identifier is an opaque value
shared only between the server configuration and iOS Keychain-backed
configuration. The exact character constraints are listed below. A tailnet ACL
is the network boundary; application authentication remains required even
inside that boundary. Do not put either credential in a URL, source file, shell
history, screenshot, or service log.

`GET /health` is unauthenticated and returns only `{"status":"ok"}`. The API
schema endpoints are disabled. Useful authenticated endpoints are:

| Method and path | Purpose |
|---|---|
| `GET /v1/integrations` | Enabled-feature flags only |
| `GET /v1/timetree/calendars` | Authenticate and list calendars |
| `GET /v1/timetree/events` | Read/search calendar events |
| `POST /v1/intelligence/extract` | Validate structured suggestions from authorized owner text |
| `POST /v1/assistant` | Answer using supplied local-task context and configured integrations |
| `POST /v1/timetree/operations/prepare` | Persist an exact write preview; does not write to TimeTree |
| `POST /v1/timetree/operations/confirm` | Execute only a previously prepared, unexpired operation |

Calendar writes are never part of the smoke test. Live create/update/delete
validation requires separate explicit approval.

## Ubuntu environment

Copy `deploy/omi-personal-intelligence.env.example` to the protected path in the
installation steps. Blank required values fail startup closed.

| Variable | Required | Default / constraint |
|---|---|---|
| `PIS_OWNER_UID` | Always | No default; must match iOS; 1-200 characters from `A-Z a-z 0-9 . _ : @ -` |
| `PIS_API_TOKEN` | Always | No default; 24-256 URL-safe characters from `A-Z a-z 0-9 . _ ~ -`; 64 lowercase hex characters recommended |
| `PIS_LISTEN_HOST` | No | `127.0.0.1`; loopback values only |
| `PIS_LISTEN_PORT` | No | `8792` |
| `PIS_STATE_PATH` | No | `/var/lib/omi-personal-intelligence/operations.sqlite3`; keep it under that systemd-managed state directory with the supplied unit |
| `PIS_CONFIRMATION_TTL_SECONDS` | No | `900`; allowed range 60-3600 |
| `TIMETREE_INTEGRATION_ENABLED` | No | `false`; set `true` for TimeTree |
| `TIMETREE_EMAIL` | With TimeTree | Server-side credential; never returned to iOS |
| `TIMETREE_PASSWORD` | With TimeTree | Server-side credential; never returned to iOS |
| `TIMETREE_DEFAULT_CALENDAR_ID` | No | Empty means select explicitly unless only one exists |
| `TIMETREE_PREFER_FOR_GENERIC_CALENDAR` | No | `false`; explicit TimeTree requests still use TimeTree |
| `TIMETREE_TIMEOUT_SECONDS` | No | `20` |
| `TIMETREE_REQUESTS_PER_SECOND` | No | `10`; values above 10 are rejected |
| `PIS_LLM_ENABLED` | No | `false`; set `true` for extraction/assistant planning |
| `PIS_LLM_BASE_URL` | No | `http://127.0.0.1:11434`; loopback only |
| `PIS_LLM_MODEL` | With local LLM | Exact installed Ollama model name |
| `PIS_LLM_TIMEOUT_SECONDS` | No | `45` |

The environment file follows systemd `EnvironmentFile=` quoting, not arbitrary
shell syntax. Quote values containing whitespace or `#`. Never source the live
file in an interactive shell. The restricted owner/token alphabets above are
the operational deployment contract used by the redaction-safe smoke test.

The isolated TimeTree protocol client is informed by TimeTree-MCP v0.5.0 at
commit `5d25b4b3af539f714230e90bc038d2cdffc92b4f`. It does not install that
project's Node/MCP runtime. Its required MIT attribution is shipped in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Build an immutable release artifact

Run these commands in a clean, committed checkout on the trusted source machine.
Do not package an uncommitted tree because rollback would not identify its
contents.

```bash
REPO_CHECKOUT=/absolute/path/to/omi
RELEASE_SHA="$(git -C "${REPO_CHECKOUT}" rev-parse HEAD)"
RELEASE_ARCHIVE="/tmp/omi-personal-intelligence-${RELEASE_SHA}.tar.gz"

git -C "${REPO_CHECKOUT}" diff --quiet
git -C "${REPO_CHECKOUT}" diff --cached --quiet
test -z "$(git -C "${REPO_CHECKOUT}" status --porcelain)"
git -C "${REPO_CHECKOUT}" archive \
  --format=tar.gz \
  --output="${RELEASE_ARCHIVE}" \
  "${RELEASE_SHA}" \
  backend/personal_intelligence
shasum -a 256 "${RELEASE_ARCHIVE}" > "${RELEASE_ARCHIVE}.sha256"
```

Transfer both files using an approved Ubuntu login. SSH access was not available
to the implementation session, so `<approved-ubuntu-user>` is intentionally not
invented:

```bash
UBUNTU_SSH_USER='REPLACE_WITH_APPROVED_LOGIN'
scp "${RELEASE_ARCHIVE}" "${RELEASE_ARCHIVE}.sha256" \
  "${UBUNTU_SSH_USER}@home-server.tailf58dfc.ts.net:/tmp/"
```

## Install on Ubuntu

The following steps create only the new service. They do not stop or restart
Tailscale, privacy STT, Ollama, the ledger, or any Omi context application.

1. Inspect current state without changing it. Stop if `:8792` is already in use.

   ```bash
   tailscale version
   sudo tailscale serve status --json
   sudo ss -H -ltnp | awk '$4 ~ /:(8443|8444|8766|8791|8792|11434)$/ {print}'
   python3.11 --version
   curl --fail --silent --show-error http://127.0.0.1:11434/api/version >/dev/null
   sudo systemctl --no-pager --full status omi-personal-intelligence.service || true
   sudo ls -ld /etc/omi-personal-intelligence \
     /opt/omi-personal-intelligence \
     /var/lib/omi-personal-intelligence 2>/dev/null || true
   ```

   On a first deployment, stop if the proposed unit name or any of those three
   paths already exists until its ownership and purpose are reviewed. Do not let
   `StateDirectory=` change ownership of a pre-existing directory. For a known
   prior release of this same service, follow **Upgrade and rollback** instead.

   Inventory likely intelligence/context services without reading their
   environment values or command arguments (either can contain secrets):

   ```bash
   sudo systemctl list-units --type=service --all --no-legend |
     awk 'tolower($1) ~ /(omi|context|pis|memoria|weaviate)/ {print $1, $3, $4}'
   sudo find /etc/systemd/system /usr/lib/systemd/system /lib/systemd/system \
     -maxdepth 2 -type f \
     \( -iname '*omi*.service' -o -iname '*context*.service' -o -iname '*pis*.service' \) \
     -print
   command -v pis-backend || true
   ```

   For each candidate unit, replace `CANDIDATE.service` with the exact listed
   name and inspect only lifecycle metadata:

   ```bash
   sudo systemctl show CANDIDATE.service --no-pager \
     --property=Id,LoadState,ActiveState,SubState,MainPID,User,Group \
     --property=FragmentPath,WorkingDirectory,StateDirectory \
     --property=After,Requires,Wants,PartOf
   candidate_pid="$(sudo systemctl show CANDIDATE.service \
     --value --property=MainPID)"
   if test "${candidate_pid}" -gt 1; then
     sudo readlink -f "/proc/${candidate_pid}/exe"
   fi
   ```

   Record a redacted audit containing unit names, executable types, ownership,
   bound ports, dependencies, and restart boundaries, but no environment
   values, arguments, credentials, or private data. Continue with the separate
   service only if it neither conflicts with `:8792` nor requires changing or
   restarting an existing unit. Stop for review if an existing tool owns that
   port or declares a dependency/restart relationship with privacy STT,
   Tailscale, or another production component.

2. Install prerequisites through the server's approved package mechanism. On an
   Ubuntu release that already provides Python 3.11 packages:

   ```bash
   sudo apt-get update
   sudo apt-get install --yes python3.11 python3.11-venv ca-certificates curl tzdata
   ```

   Do not add an unreviewed package repository merely to obtain Python 3.11.

3. Create a dedicated, non-login service account and immutable release root:

   ```bash
   getent passwd omi-intelligence >/dev/null || \
     sudo useradd --system --user-group \
       --home-dir /var/lib/omi-personal-intelligence \
       --shell /usr/sbin/nologin omi-intelligence
   sudo install -d -o root -g root -m 0755 \
     /opt/omi-personal-intelligence/releases
   ```

4. On Ubuntu, verify and unpack the transferred release. Replace `<full-git-sha>`
   with the same 40-character SHA used in the archive name.

   ```bash
   RELEASE_SHA='REPLACE_WITH_FULL_40_CHARACTER_GIT_SHA'
   RELEASE_ARCHIVE="/tmp/omi-personal-intelligence-${RELEASE_SHA}.tar.gz"
   RELEASE_DIR="/opt/omi-personal-intelligence/releases/${RELEASE_SHA}"

   cd /tmp
   sha256sum --check "${RELEASE_ARCHIVE}.sha256"
   test "${#RELEASE_SHA}" -eq 40
   test -z "${RELEASE_SHA//[0-9a-f]/}"
   test ! -e "${RELEASE_DIR}"
   if test -e /opt/omi-personal-intelligence/current && \
     ! test -L /opt/omi-personal-intelligence/current; then
     echo 'Refusing to replace a non-symlink current path' >&2
     exit 1
   fi
   sudo install -d -o root -g root -m 0755 "${RELEASE_DIR}"
   sudo tar --extract --gzip --file="${RELEASE_ARCHIVE}" \
     --directory="${RELEASE_DIR}" --no-same-owner
   sudo python3.11 -m venv "${RELEASE_DIR}/.venv"
   sudo "${RELEASE_DIR}/.venv/bin/python" -m pip install \
     --disable-pip-version-check \
     --requirement \
     "${RELEASE_DIR}/backend/personal_intelligence/deploy/requirements.txt"
   sudo chown -R root:root "${RELEASE_DIR}"
   sudo chmod -R go-w "${RELEASE_DIR}"
   sudo ln -sfn "${RELEASE_DIR}" /opt/omi-personal-intelligence/current
   ```

5. Install a root-only configuration and edit it without echoing values:

   ```bash
   sudo install -d -o root -g root -m 0700 /etc/omi-personal-intelligence
   if ! sudo test -e /etc/omi-personal-intelligence/personal-intelligence.env; then
     sudo install -o root -g root -m 0600 \
       /opt/omi-personal-intelligence/current/backend/personal_intelligence/deploy/omi-personal-intelligence.env.example \
       /etc/omi-personal-intelligence/personal-intelligence.env
   fi
   sudoedit /etc/omi-personal-intelligence/personal-intelligence.env
   sudo stat -c '%U:%G %a %n' \
     /etc/omi-personal-intelligence/personal-intelligence.env
   ```

   Set a random 64-character hex `PIS_API_TOKEN`, an opaque URL-safe
   `PIS_OWNER_UID` matching the constraints above,
   the TimeTree credentials, and an installed Ollama model. Then set
   `TIMETREE_INTEGRATION_ENABLED=true` and `PIS_LLM_ENABLED=true`. Do not print
   the completed file. Startup validation rejects missing integration secrets,
   owner/token values outside the declared alphabet or length, a non-loopback
   bind, a non-loopback Ollama URL, or a rate above 10 requests/second.

6. Install and start only the new units:

   ```bash
   sudo systemd-analyze verify \
     /opt/omi-personal-intelligence/current/backend/personal_intelligence/deploy/omi-personal-intelligence.service \
     /opt/omi-personal-intelligence/current/backend/personal_intelligence/deploy/omi-personal-intelligence-timetree-smoke.service
   sudo install -o root -g root -m 0644 \
     /opt/omi-personal-intelligence/current/backend/personal_intelligence/deploy/omi-personal-intelligence.service \
     /etc/systemd/system/omi-personal-intelligence.service
   sudo install -o root -g root -m 0644 \
     /opt/omi-personal-intelligence/current/backend/personal_intelligence/deploy/omi-personal-intelligence-timetree-smoke.service \
     /etc/systemd/system/omi-personal-intelligence-timetree-smoke.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now omi-personal-intelligence.service
   sudo systemctl --no-pager --full status omi-personal-intelligence.service
   ```

7. Verify loopback health and binding before proposing network ingress:

   ```bash
   curl --fail --silent --show-error http://127.0.0.1:8792/health
   sudo ss -H -ltnp 'sport = :8792'
   ```

   The listener must show `127.0.0.1:8792` (or approved loopback equivalent),
   never `0.0.0.0:8792`, a LAN address, or a Tailscale address.

8. Run the read-only TimeTree authentication smoke test. It calls only
   `GET /v1/timetree/calendars` and logs only the count:

   ```bash
   sudo systemctl start omi-personal-intelligence-timetree-smoke.service
   sudo journalctl --no-pager \
     -u omi-personal-intelligence-timetree-smoke.service -n 10
   ```

   Expected output is `TimeTree authentication succeeded; calendar_count=N`.
   Names, events, notes, locations, cookies, CSRF tokens, credentials, and raw
   TimeTree responses are never printed.

## Tailscale Serve change: proposal only

Do **not** run this section without explicit approval. The implementation
session did not inspect or modify the live Serve configuration. The existing
`:8443/live` privacy route must remain untouched, and `tailscale serve reset`
must never be used here.

After approval, first capture and review the current state and confirm `:8444`
is unused:

```bash
sudo tailscale serve status --json
sudo ss -H -ltnp 'sport = :8444'
```

For Tailscale 1.52 or newer, the exact proposed tailnet-only route is:

```bash
sudo tailscale serve --bg --https=8444 http://127.0.0.1:8792
```

This uses a new listener rather than changing `:8443` or relying on path-prefix
rewriting. Do not use `tailscale funnel`; Funnel would make the service public.
Immediately inspect the result and compare the `:8443` entry with the pre-change
state. Run the HTTPS health request from a second device on the same tailnet:

```bash
sudo tailscale serve status --json
curl --fail --silent --show-error \
  https://home-server.tailf58dfc.ts.net:8444/health
```

The exact route-only rollback is:

```bash
sudo tailscale serve --https=8444 off
```

That rollback must remove only `:8444`. Never use `tailscale serve reset`, and
do not restart Tailscale. The current command syntax is documented in the
[Tailscale Serve CLI reference](https://tailscale.com/docs/reference/tailscale-cli/serve).

## iOS-to-Ubuntu acceptance

Only after the service, read-only TimeTree smoke test, and approved TLS route are
healthy:

1. Configure the privacy app's **configurable** intelligence base URL as
   `https://home-server.tailf58dfc.ts.net:8444`.
2. Enter the exact opaque owner UID and bearer token; the token must remain in
   iOS Keychain storage.
3. Use the app to request the integration status and list TimeTree calendars.
4. Verify the response came from persisted/provider state and that backend
   unavailability still leaves local tasks and capture usable.
5. Record a redacted success receipt containing only timestamp, app build,
   endpoint host/port, HTTP outcome, and calendar count.

Do not perform a live create/update/delete round trip without separate explicit
approval. Do not call the milestone deployed or complete until this iOS request
has succeeded against the Ubuntu service.

## Upgrade and rollback

Before an upgrade, record the current immutable target:

```bash
readlink -f /opt/omi-personal-intelligence/current
```

Install a new release beside the old one using the same procedure, move the
`current` symlink, and restart **only** this service. If health or the read-only
smoke test fails, restore the recorded release path:

```bash
PREVIOUS_RELEASE='/opt/omi-personal-intelligence/releases/REPLACE_WITH_PREVIOUS_FULL_GIT_SHA'
sudo ln -sfn "${PREVIOUS_RELEASE}" /opt/omi-personal-intelligence/current
sudo systemctl restart omi-personal-intelligence.service
curl --fail --silent --show-error http://127.0.0.1:8792/health
```

To withdraw a first deployment without deleting recoverable state:

```bash
sudo systemctl disable --now omi-personal-intelligence.service
```

If the `:8444` proposal had been approved and applied, remove only that route
with the route-only rollback command above. Leave the root-only environment,
SQLite state, and prior release directories in place until the rollback has
been reviewed. Never stop or restart privacy STT, Tailscale, Ollama, the context
app, or the optional ledger as part of this rollback.

## Operations

Service metadata and sanitized logs:

```bash
sudo systemctl --no-pager --full status omi-personal-intelligence.service
sudo journalctl --no-pager -u omi-personal-intelligence.service -n 100
```

The application must not log TimeTree credentials, cookies, CSRF tokens, event
titles, notes, locations, raw private-API responses, transcript text, or local
task text. Back up the SQLite file only into owner-approved encrypted storage;
it contains operation previews and outcomes. A backup or deletion policy must
be approved separately.

