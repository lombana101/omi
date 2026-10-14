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

## Configure Personal Intelligence

This configuration is separate from the capture/STT URL and token. It never
changes the working `:8443/live` capture route.

1. Deploy the loopback-only Ubuntu service by following
   `backend/personal_intelligence/DEPLOYMENT.md`.
2. Obtain explicit approval before adding the proposed tailnet-only TLS route
   on `:8444`.
3. In the privacy app, open Settings → Personal Intelligence.
4. Enter `https://home-server.tailf58dfc.ts.net:8444`, the exact opaque owner
   mapping ID, and the Personal Intelligence bearer token. These values are
   stored in the iOS Keychain and are not shared with the capture credential.
5. Tap **Test connection**. A successful test proves authenticated API access;
   listing calendars separately proves the read-only TimeTree path.

Do not run a live TimeTree create/update/delete test without separate explicit
approval. The feature is not deployed or end-to-end complete until this app has
successfully communicated with the deployed Ubuntu API.

## Install with a free Apple ID

1. Install Xcode and sign in with your Apple ID under Settings → Accounts.
2. In the local generated file `app/ios/Flutter/Custom.xcconfig`, set `APP_BUNDLE_IDENTIFIER=com.sergiolombana.omi.privacy`. Do not commit that file.
3. Open `app/ios/Runner.xcworkspace`. Select the Runner target, Signing & Capabilities, Team = your Personal Team. Enable automatic signing.
4. From `app/`, prepare the privacy-only build prerequisites and build the
   dedicated privacy entry point as an untethered profile artifact. The helper
   installs only the repository's local placeholder plist required by the
   existing Xcode graph; the privacy entry point does not initialize Firebase:

```bash
bash scripts/prepare_privacy_ios.sh
flutter build ios --profile \
  --flavor privacy \
  --target=lib/privacy_main.dart \
  --dart-define=OMI_PRIVACY_CAPTURE=true
```

5. Install the resulting `build/ios/iphoneos/Runner.app` from Xcode or with
   `xcrun devicectl device install app --device <device-id>
   build/ios/iphoneos/Runner.app`. A free Apple ID provisioning profile expires
   after 7 days. Trust the developer certificate on the phone under Settings →
   General → VPN & Device Management.
6. Do not flash pendant firmware.
