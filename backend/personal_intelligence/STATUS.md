# Personal Intelligence V1.1 status

Snapshot date: 2026-10-15. This matrix distinguishes implementation from live
deployment. A checked-in file or passing mocked test is not evidence that the
Ubuntu service or iOS-to-server path is live.

## Mac verification update — 2026-10-19

The original Ubuntu matrix below is historical and remains unchanged by this
local verification. Ubuntu deployment and physical-iPhone-to-Ubuntu acceptance
are still pending.

Tested source: feature branch fast-forwarded to `f6bb7bb1ab`, plus the current
uncommitted build/reprocessing repair. Prior app/store work was preserved.

- Fixed dangling privacy configuration IDs in the Xcode project. Added real
  project/Runner/watch/widget configurations, isolated Runner-only Flutter/Pods
  settings from extensions, and mapped privacy configurations in CocoaPods.
- `bash setup.sh ios privacy` explicitly selects the privacy scheme and entrypoint;
  ordinary dev/beta command selection is preserved. Debug and Profile settings
  queries resolve successfully to the matching privacy configuration and app ID.
- A fresh Debug-privacy simulator artifact built, installed, and launched. The
  inspected parent ID was `com.sergiolombana.omi.privacy`; its embedded widget ID
  was `com.sergiolombana.omi.privacy.widget`.
- The interrupted-session gesture previously called only the local regex
  extractor. It now calls the owner-authenticated Personal Intelligence API via
  the coordinator, sharing session source identity with intelligent extraction.
- Both session extraction gestures use retained corrected transcript/owner notes
  and persisted consent. Atomic source-existence checks fence late model results
  after source deletion. Suggestions remain pending until accepted.
- Real simulator execution exposed the interactive failure with the installed
  thinking-enabled `gemma4:latest`. Its `/api/show` metadata reported default
  thinking enabled and support for disabling it. Structured requests now set
  `think: false`. With the normal 45-second backend timeout, a direct synthetic
  request returned HTTP 200 and two suggestions in 12.68 seconds. No timeout
  increase is part of the fix.
- The opt-in live integration test passed in the iPhone 15 Pro simulator against
  the real loopback API and Ollama: actual reprocess gesture, saved suggestions,
  second processing request, dismissal, and store reopen/persistence. Total live
  test execution was 36 seconds after the build. Only synthetic text was used.
- Hermetic verification: 29 focused app tests passed across coordinator, V2
  store, shell, and intelligence UI; 86 backend API/service/TimeTree tests passed.
  The app tests include backend failure/retry, duplicate suppression, accepted
  edited-task retention, dismissal tombstones, and source-deletion races.
- Backend preflight: latest run 16 passed, 0 failed (10 optional warnings); an
  earlier run reported 17 passed and 9 warnings. Root `make
  preflight` ran and failed its UI-evidence gate because no PR body or tracked
  screenshot reference was available. It is not recorded as a full preflight pass.
- A separate smoke run of the normal privacy entrypoint exposed simulator
  data-protection attestation failure. A native probe confirmed data protection
  false and backup exclusion true. The wrapper now explicitly opts debug
  simulators into local test storage; physical/release builds keep the strict
  protection check. Native host and debug/release simulator policy tests passed:
  2 tests, 9 assertions, no failures. The normal `privacy_main.dart` entrypoint
  was then rebuilt/installed/launched with the simulator opt-in; an agent-flutter
  connection, snapshot, and screenshot confirmed the local-store error was gone.
  The existing protection-failure/store-replacement regression also passed,
  as did the native engine-lifecycle and batch-audio checks. Focused analysis
  reported no issues. This is not physical-device encryption proof.
- Store reopen is persistence evidence; this run does not claim a separate
  physical-device or Ubuntu process-restart verification. Reprocessing uses saved
  text and cannot recover missing audio/transcripts.

| Workstream | Implemented | Unit tested | Integration tested | Deployed on Ubuntu | Physically verified | Current evidence / blocker |
|---|---|---|---|---|---|---|
| Owner-authenticated standalone API | Yes, in this branch | Yes; hermetic API tests pass | Mocked only | No | No | Ubuntu SSH authentication unavailable |
| TimeTree auth/read client | Yes, in this branch | Yes; mocked HTTP tests pass | Mocked only | No | No | Live credentials intentionally not used |
| TimeTree create/update/delete with preview and confirmation | Yes, in this branch | Yes; mocked HTTP and service tests pass | Mocked only | No | No | Destructive live test requires explicit approval |
| SQLite idempotency and uncertain-write handling | Yes, in this branch | Yes; filesystem and restart-state tests pass | Mocked only | No | No | Live filesystem/service lifecycle not exercised |
| Local Ollama extraction and assistant planning | Yes, in this branch | Yes; structured-output and service tests pass | Mocked only | No | No | Ubuntu model name and live structured output not verified |
| Intelligent commitments and proactive deadline risk | Yes, in this branch | Yes; deterministic routing, busy-calendar, provider-unavailable, and stable-source tests pass | Mocked only | No | No | Current Ubuntu release still needs this commit deployed and verified |
| Ubuntu systemd/env/release/rollback artifacts | Yes, in this branch | Local shell/config/pin/isolation checks passed | No | No | No | `systemd-analyze verify` still requires Ubuntu; artifacts deliberately not installed |
| Read-only TimeTree authentication smoke test | Yes, in this branch | Synthetic success, disabled, and error-redaction checks passed | Mocked only | No | No | Live run requires deployed service and server-side credentials |
| Tailscale private API route on `:8444` | Proposal only | N/A | No | No | No | Requires current-config inspection and explicit approval |
| iOS Personal Intelligence client | Yes, in this branch | Yes; 26 focused Flutter tests and focused analyzer pass | Mocked only | N/A | Build/install/launch only | Signed privacy profile build installed and launched on Sergio's physical iPhone; it still requires a deployed private endpoint |
| iOS-to-Ubuntu API communication | No | N/A | No | No | No | Ubuntu and Ollama are reachable over Tailscale, but SSH authentication, deployment, and the private route remain unavailable |
| Existing privacy STT `127.0.0.1:8766` and TLS `:8443/live` | Preserved | Existing coverage only | Not rerun here | Existing service reported active | Existing capture previously verified | No file, service, or route change made by this work |
| Existing Ubuntu context app / `pis-backend` suitability | Keep separate for this release | N/A | On-host read-only audit pending | Existing deployment unknown | No | No verified extension contract or safe noninteractive SSH credential; deployment runbook requires a collision/lifecycle audit |

Backend verification on 2026-10-15: the three dedicated suites completed with
`85 passed` in an isolated Python environment. The repository-pinned
Black 26.5.1 formatter and Ruff 0.4.4 passed for the package and its tests;
bytecode compilation also passed. The repository-wide bootstrap, Flutter tests,
import-time side-effect scanner, shell checks, and installed-package compatibility
checks were not rerun in this sparse Ubuntu checkout. These are local and mocked
checks only, not Ubuntu deployment or provider evidence.

iOS verification on 2026-10-14: the 26 focused Personal Intelligence unit and
widget tests passed, focused analysis reported no issues, and a signed profile
build of `lib/privacy_main.dart` using the `privacy` scheme was installed and
launched on Sergio's physical iPhone as `com.sergiolombana.omi.privacy`. This
proves the artifact is installable and untethered; it does not prove the
iOS-to-Ubuntu path until the backend is deployed and the authenticated calendar
read succeeds.

Deployment-package verification on 2026-10-13: a fresh Python 3.11 environment
installed the 17 version-pinned runtime packages with no dependency conflicts; an
archive containing only `backend/personal_intelligence` imported and started
independently of the rest of the Omi backend. Health, owner-auth rejection and
acceptance, disabled schema routes, operation-state permissions, and the
redaction-safe smoke script were exercised locally. The TimeTree-MCP v0.5.0
reference commit and MIT license were verified, and the exact license text is
included in `THIRD_PARTY_NOTICES.md`. Systemd parsing, Ubuntu ownership, live
Ollama/TimeTree behavior, and Tailscale routing remain intentionally unverified.

The milestone remains **BLOCKED**, not complete, until all of the following are
recorded without private content:

1. The Ubuntu service is installed and healthy on loopback.
2. The read-only TimeTree smoke test succeeds and reports only a calendar count.
3. The proposed tailnet-only route is explicitly approved, applied, and shown
   not to alter `:8443/live`.
4. The installed iOS privacy app successfully authenticates to the Ubuntu API
   and receives a real TimeTree read response.
5. Any live TimeTree write round trip is separately approved before execution.
