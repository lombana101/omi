#!/usr/bin/env bash
# Authenticate through the deployed API and list TimeTree calendars read-only.
# The response body is reduced to a count and is never written to stdout/logs.
set -euo pipefail

if [[ "${TIMETREE_INTEGRATION_ENABLED:-false}" != "true" ]]; then
  echo "TimeTree smoke test refused: TIMETREE_INTEGRATION_ENABLED is not true" >&2
  exit 2
fi

: "${PIS_OWNER_UID:?PIS_OWNER_UID is required}"
: "${PIS_API_TOKEN:?PIS_API_TOKEN is required}"

if [[ ! "${PIS_OWNER_UID}" =~ ^[A-Za-z0-9._:@-]{1,200}$ ]]; then
  echo "TimeTree smoke test refused: PIS_OWNER_UID contains unsupported characters" >&2
  exit 2
fi
if [[ ! "${PIS_API_TOKEN}" =~ ^[A-Za-z0-9._~-]+$ ]] || \
  ((${#PIS_API_TOKEN} < 24 || ${#PIS_API_TOKEN} > 256)); then
  echo "TimeTree smoke test refused: PIS_API_TOKEN must be a URL-safe token of 24-256 characters" >&2
  exit 2
fi

pis_host="${PIS_LISTEN_HOST:-127.0.0.1}"
pis_port="${PIS_LISTEN_PORT:-8792}"
case "${pis_host}" in
  127.0.0.1 | localhost)
    pis_url="http://${pis_host}:${pis_port}/v1/timetree/calendars"
    ;;
  ::1)
    pis_url="http://[::1]:${pis_port}/v1/timetree/calendars"
    ;;
  *)
    echo "TimeTree smoke test refused: PIS_LISTEN_HOST is not loopback" >&2
    exit 2
    ;;
esac
if [[ ! "${pis_port}" =~ ^[0-9]{1,5}$ ]] || ((pis_port < 1 || pis_port > 65535)); then
  echo "TimeTree smoke test refused: PIS_LISTEN_PORT is invalid" >&2
  exit 2
fi

# Supplying curl configuration on stdin keeps the bearer token out of argv and
# process listings. Python receives the private JSON only on stdin and emits the
# array length; it never prints calendar names or raw provider responses.
calendar_count="$({
  printf 'request = "GET"\n'
  printf 'url = "%s"\n' "${pis_url}"
  printf 'header = "Accept: application/json"\n'
  printf 'header = "Authorization: Bearer %s"\n' "${PIS_API_TOKEN}"
  printf 'header = "X-PIS-Owner-Uid: %s"\n' "${PIS_OWNER_UID}"
  printf 'silent\nshow-error\nfail\nmax-time = 30\n'
} | /usr/bin/curl --config - | /usr/bin/python3 -c '
import json
import sys

payload = json.load(sys.stdin)
if not isinstance(payload, list):
    raise SystemExit("TimeTree smoke test received an unexpected response shape")
print(len(payload))
')"

unset PIS_API_TOKEN
printf 'TimeTree authentication succeeded; calendar_count=%s\n' "${calendar_count}"
