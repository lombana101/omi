# Run the Personal Intelligence API on a Mac

This guide runs the standalone, owner-scoped Personal Intelligence API locally
on a MacBook. It is the smallest path for developing and exercising the
personal-intelligence features; it does not start the full Firebase/Redis-backed
Omi backend and does not change an Ubuntu deployment.

The service deliberately listens on loopback only. Requests from the same Mac
can use `http://127.0.0.1:8792`; exposing it to another device requires a
separately reviewed private proxy such as Tailscale Serve. Do not change
`PIS_LISTEN_HOST` to `0.0.0.0`—startup rejects non-loopback listeners.

## 1. Install the local prerequisites

From Terminal:

```bash
brew install python@3.11
python3.11 --version
```

Python must report `3.11.x`. Ollama and TimeTree are optional and can remain
disabled for API, authentication, storage, and commitment-risk development.

## 2. Create an isolated environment

From the repository checkout:

```bash
cd backend
python3.11 -m venv .venv-personal-intelligence
source .venv-personal-intelligence/bin/activate
python -m pip install --upgrade pip
python -m pip install --requirement personal_intelligence/deploy/requirements.txt
```

The standalone requirements are fully pinned and intentionally smaller than
the standard Omi backend environment.

## 3. Create local configuration

The local file is ignored by Git. Keep it private because it contains the same
bearer credential used by test clients.

```bash
cp personal_intelligence/deploy/omi-personal-intelligence.env.example \
  .env.personal-intelligence.local
chmod 600 .env.personal-intelligence.local
```

Edit `.env.personal-intelligence.local` and set at least:

```dotenv
PIS_OWNER_UID=local-owner
PIS_API_TOKEN=REPLACE_WITH_64_LOWERCASE_HEX_CHARACTERS
PIS_LISTEN_HOST=127.0.0.1
PIS_LISTEN_PORT=8792
PIS_STATE_PATH=.local-state/personal-intelligence/operations.sqlite3
TIMETREE_INTEGRATION_ENABLED=false
PIS_LLM_ENABLED=false
```

Generate a token (the command is stored in history, but its random output is
not):

```bash
openssl rand -hex 32
```

Copy the output directly into `PIS_API_TOKEN`. Never commit the local
environment file.

## 4. Start the API

In the first Terminal window, from `backend/` with the virtual environment
active:

```bash
set -a
source .env.personal-intelligence.local
set +a
python -m personal_intelligence
```

Expected local address: `http://127.0.0.1:8792`. API schema routes are disabled
by design, so `/docs` returning `404` is expected.

## 5. Exercise the local service

Open a second Terminal window:

```bash
cd /absolute/path/to/omi/backend
set -a
source .env.personal-intelligence.local
set +a
```

Health does not require authentication:

```bash
curl --fail --silent --show-error http://127.0.0.1:8792/health
```

The expected result is `{"status":"ok"}`. Confirm the private routes reject an
unauthenticated request:

```bash
curl --silent --show-error --output /dev/null --write-out '%{http_code}\n' \
  http://127.0.0.1:8792/v1/integrations
```

The expected status is `401`. Then authenticate using the values loaded from
the private local file:

```bash
curl --fail --silent --show-error \
  --header "Authorization: Bearer ${PIS_API_TOKEN}" \
  --header "X-PIS-Owner-Uid: ${PIS_OWNER_UID}" \
  http://127.0.0.1:8792/v1/integrations
```

With both optional integrations disabled, the expected response is:

```json
{"local_intelligence":false,"timetree":false,"generic_calendar_uses_timetree":false}
```

The commitment-risk evaluator has a deterministic path and can be exercised
without Ollama or TimeTree:

```bash
curl --fail --silent --show-error \
  --request POST \
  --header 'Content-Type: application/json' \
  --header "Authorization: Bearer ${PIS_API_TOKEN}" \
  --header "X-PIS-Owner-Uid: ${PIS_OWNER_UID}" \
  --data '{
    "timezone":"America/Toronto",
    "now":"2026-11-02T09:00:00-05:00",
    "open_tasks":[]
  }' \
  http://127.0.0.1:8792/v1/intelligence/proactive/evaluate
```

Use only synthetic text while learning the API. Do not paste private
conversation content into terminal history.

## 6. Run the focused tests

Stop the server with `Control-C`. The repository test harness needs three
additional pinned packages that are not part of the production service:

```bash
python -m pip install \
  google-api-core==2.19.1 \
  pytest==8.4.1 \
  pytest-asyncio==1.4.0
```

Then run from `backend/`:

```bash
python -m pytest -q \
  tests/unit/test_personal_intelligence_api.py \
  tests/unit/test_personal_intelligence_service.py \
  tests/unit/test_personal_intelligence_timetree.py
```

These are hermetic tests: they do not contact TimeTree, Ollama, Firebase, Redis,
or the deployed Ubuntu service.

## Optional: enable local intelligence with Ollama

Install and start Ollama using its supported macOS distribution, install a
model, and verify that `http://127.0.0.1:11434/api/version` responds. Then update
the local environment file:

```dotenv
PIS_LLM_ENABLED=true
PIS_LLM_BASE_URL=http://127.0.0.1:11434
PIS_LLM_MODEL=REPLACE_WITH_THE_EXACT_INSTALLED_MODEL_NAME
```

Restart the API after configuration changes. The base URL must remain loopback;
the service rejects a remote model endpoint so private text is not silently sent
off-device.

## Optional: enable TimeTree reads

TimeTree access uses an unsupported private API that may change without notice.
Put its credentials only in `.env.personal-intelligence.local`, set
`TIMETREE_INTEGRATION_ENABLED=true`, and restart the API. Start with the
read-only calendar-list endpoint. Calendar create, update, and delete require a
prepare/confirm flow; do not perform a live write merely as a smoke test.

For the Ubuntu service lifecycle, private tailnet route, rollback, and the
redaction-safe TimeTree smoke test, use [DEPLOYMENT.md](DEPLOYMENT.md). The
implementation-versus-deployment evidence remains tracked in
[STATUS.md](STATUS.md).
