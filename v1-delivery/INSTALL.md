# Install

Installed on the owner’s iPhone and launched from the Home Screen. This did not replace the production Omi app.

## Artifact

- Path: `app/build/ios/iphoneos/Runner.app`
- Bundle ID: `com.sergiolombana.omi.privacy`
- Profile, arm64, `OMI_PRIVACY_CAPTURE=true`
- Team: `W6LC5NFNZW`
- Embedded profile expiry: 2027-10-10
- Runner binary SHA-256: `d5ab7853e149665f679aac56794e299253fed2e2889737f3934ab03f0063c4cb`

## Reinstall

Connect and unlock the iPhone, then from `app/`:

```bash
xcrun devicectl device install app --device <connected-iphone> build/ios/iphoneos/Runner.app
```

Open it from the Home Screen. Do not use `flutter run`.

## Rollback

Delete the privacy app from the Home Screen. That removes this bundle only.
