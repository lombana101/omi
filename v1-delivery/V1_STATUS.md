# V1 status

Result: **V1 complete**, with the limitations below.

Owner verification was on a physical iPhone, launched from the Home Screen, using the signed privacy build. No transcript, note, task text, token, or device identifier is recorded here.

Base: `a1cfd2683b38cff64522a890acb5ea8467ef0567`. This remains an uncommitted shallow working tree. No production STT, ledger, firmware, or repository publication change was made.

| Surface | Status | Evidence |
|---|---|---|
| Home Screen launch, recording off | Verified end-to-end with owner | Signed privacy app. No “Local store unavailable.” |
| Connection test without capture | Verified end-to-end with owner | Probe did not start capture. |
| Button on, audio unsubscribed before authorization | Verified end-to-end with owner | Pendant check before start. |
| Authorization before recording | Verified end-to-end with owner | Self-only capture. |
| Live transcript persisted | Verified end-to-end with owner | Received and stored. |
| Session-only retention | Verified end-to-end with owner | Deleted on the next launch, as designed. |
| Longer retention across restart | Verified end-to-end with owner | Session remained after restart. |
| Machine text separate from correction | Verified end-to-end with owner | Separate fields. |
| Owner note | Verified end-to-end with owner | Separate field. |
| Transcript-to-task review | Verified end-to-end with owner | Title reviewed before save. |
| Suggestions require acceptance | Verified end-to-end with owner | No automatic task creation. |
| Task edit, project, due date, complete, reopen, delete | Verified end-to-end with owner | Owner exercised the controls. |
| Session deletion | Verified end-to-end with owner | Local-only language. Kept commitment had no source excerpt. |
| Lock or leave interrupts capture | Verified end-to-end with owner | Did not resume. Reopen stayed recording-off and Interrupted. |
| Fail-closed store protection | Verified on physical device | See storage note below. |
| Automated admission, persistence, and UI tests | Verified by automated test | Privacy suite passed before the owner loop. |
| Signed profile build | Verified by build inspection | arm64, `com.sergiolombana.omi.privacy`, strict signature check passed. |
| Background capture | Blocked | Intentionally unsupported. Leaving or locking interrupts capture. |
| Remote deletion | Deferred | Unavailable or unverified. |
| Production ledger | Deferred | Not in this build. |
| Mixed-party acceptance test | Deferred | Not used. |
| Firmware changes | Deferred | None made. |

Storage protection: verified on physical device through fail-closed initialization and native attribute readback. The device container was not externally inspected.

The app calls `PrivacyFileProtection.protect` while opening the store. The iOS channel sets `FileProtectionType.complete` and `isExcludedFromBackup`, reads both back, and returns success only if both match. A false result or channel failure becomes `PrivacyStoreUnavailable`. The owner’s app opened without that error.
