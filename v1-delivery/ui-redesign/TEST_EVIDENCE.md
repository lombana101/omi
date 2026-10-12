# UI redesign test evidence

Synthetic content only. No transcript, token, or device identifier.

```text
cd app && flutter test test/unit/privacy_theme_test.dart test/unit/privacy_redesign_shots_test.dart
```

Plus the existing privacy suite.

Screenshots, if the shot test passes:

- `signal-green-capture.png`
- `signal-green-sessions.png`
- `signal-green-tasks.png`
- `signal-green-settings.png`
- `theme-electric-blue.png`
- `theme-warm-ember.png`
- `theme-quiet-light.png`

Known limitation: screenshots are widget renders, not device photos. Physical theme persistence is separate from this file.
