# Privacy capture install

Do not install this build until you choose to. Nothing here changes pendant firmware.

The privacy workflow is compiled only when `OMI_PRIVACY_CAPTURE=true`. Stock builds are unchanged.

## Backend

`deploy/PRIVACY_PROTOCOL.md` requires:

- `Authorization: Bearer <token>` on the WebSocket upgrade to `/live`
- first message is StartCapture v1
- audio before acknowledgement is rejected
- invalid authorization closes with `1008`
- privacy listener stays on `127.0.0.1:8766`
- a phone must use an authenticated TLS reverse proxy, never raw port `8766`
- the bearer secret stays in `/etc/omi-stt/privacy.env` mode `0600`

The verified acknowledgement is:

```json
{
  "type": "StartCaptureAck",
  "version": 1,
  "capture_id": "<canonical lowercase UUID>",
  "authorized_at": "2026-10-09T12:00:01Z"
}
```

`type` and `version` are required. `capture_id` must be the same UUID as the request, ignoring letter case. `authorized_at` is optional metadata. Extra fields are ignored and do not authorize capture.

## Configure the phone

1. Open the app's Device settings and choose Privacy capture. That row exists only in a privacy build.
2. Enter the `wss://` proxy URL ending in `/live`.
3. Paste the bearer token. It is written to the iOS keychain, not source.
4. Leave the consent box unchecked for `self_only`.
5. Check it only after the other people have consented. That arms `participants_consented` for one start, then returns to `self_only`.
6. Double-tap the pendant. Recording stays off until StartCaptureAck. Double-tap again to stop.

## Install with a free Apple ID

1. Install Xcode and sign in with your Apple ID under Settings → Accounts.
2. In the local generated file `app/ios/Flutter/Custom.xcconfig`, set `APP_BUNDLE_IDENTIFIER=com.sergiolombana.omi.privacy`. Do not commit that file.
3. Open `app/ios/Runner.xcworkspace`. Select the Runner target, Signing & Capabilities, Team = your Personal Team. Enable automatic signing.
4. From `app/`, build for your phone without installing from this session:

```bash
flutter build ios --debug \
  --dart-define=OMI_PRIVACY_CAPTURE=true
```

5. In Xcode, select your iPhone and press Run. A free Apple ID provisioning profile expires after 7 days. Trust the developer certificate on the phone under Settings → General → VPN & Device Management.
6. Do not flash pendant firmware.
