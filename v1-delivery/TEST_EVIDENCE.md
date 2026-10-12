# Test evidence

No transcript, note, task text, token, or device identifier is included.

## Owner loop

Verified end-to-end with the owner on a physical iPhone, launched from the Home Screen:

- Recording was off. “Local store unavailable” was not shown.
- Connection test did not start capture.
- Button notifications were on and audio was unsubscribed before authorization.
- A self-only capture authorized before recording. The transcript was received and persisted.
- Session-only retention deleted that session on the next launch.
- A longer retention choice survived restart.
- Machine transcription and owner correction stayed separate. The owner note used its own field.
- Transcript-to-task review worked. Suggestions stayed suggestions until accepted.
- Task edit, selected project, due date, complete, reopen, and delete worked.
- Session deletion used local-only language and kept a chosen commitment without its source excerpt.
- Locking or leaving interrupted capture. Reopen stayed recording-off, labeled Interrupted, and did not resume.

## Automated checks before that loop

```text
cd app && flutter test \
  test/unit/privacy_capture_controller_test.dart \
  test/unit/privacy_connection_probe_test.dart \
  test/unit/privacy_off_link_test.dart \
  test/unit/privacy_standalone_test.dart \
  test/unit/privacy_v1_store_test.dart \
  test/unit/privacy_protocol_fixture_test.dart \
  test/unit/privacy_shell_test.dart \
  test/unit/privacy_gap_ui_test.dart
```

Result: all tests passed.

`dart analyze lib/services/privacy_capture`: no issues.

## Build inspection

```text
cd app && flutter build ios --profile --flavor privacy --dart-define=OMI_PRIVACY_CAPTURE=true --no-pub
codesign --verify --deep --strict build/ios/iphoneos/Runner.app
```

- Identifier: `com.sergiolombana.omi.privacy`
- Architecture: arm64
- Team: `W6LC5NFNZW`
- Profile expiry: 2027-10-10
- Runner binary SHA-256: `d5ab7853e149665f679aac56794e299253fed2e2889737f3934ab03f0063c4cb`

That binary is the one installed on the owner’s phone.
