# Privacy behavior

Owner-only experiment. The retention choice on the phone is not settled project policy.

## Capture

Recording is off on every launch. Start requires a purpose and an explicit assertion. Self-only is the owner’s assertion, not a technical determination. Mixed-party consent resets after one start attempt. Mixed-party capture was not used for acceptance.

Audio stays unsubscribed, and no frame is sent, until a matching `StartCaptureAck` for version 1. Stop unsubscribes before `CloseStream`. Reconnect, relaunch, lock, and leaving the app do not resume capture. Background capture is intentionally unsupported: leaving or locking interrupts the session.

## Storage

Sessions and tasks are in `privacy_v1/store.json`. Raw audio is not stored on the phone. The bearer token stays in the keychain with `first_unlock_this_device` and synchronizable false. It is not shown again.

Opening the store calls the iOS protection channel. That channel sets `FileProtectionType.complete` and `isExcludedFromBackup`, reads both back, and succeeds only if both match. A false result or channel failure is `PrivacyStoreUnavailable`, and the app does not treat the store as ready. The owner’s launch did not show that error. The device container was not externally inspected.

Writes replace the store only after a same-directory temporary file is ready. A failed protection call does not discard the last valid store. A corrupt or unsupported store is not overwritten.

## Suggestions, tasks, and deletion

Suggestions stay suggestions until Accept or Edit and accept. Task controls cover title, note, a chosen due date and time, project selection, complete, reopen, and delete. Corrections and owner notes are separate from the machine transcript.

Session deletion says deleted from this phone. Remote deletion is unavailable or unverified. A kept commitment drops the source excerpt and link. Production ledger integration is deferred. No firmware was changed.
