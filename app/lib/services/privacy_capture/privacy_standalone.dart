import 'package:flutter/material.dart';

import 'package:omi/services/privacy_capture/privacy_shell.dart';

enum PrivacyAppRoot { standalone, signedOut, signedIn }

/// Privacy mode never enters Omi sign-in, even when no Firebase user exists.
PrivacyAppRoot selectPrivacyAppRoot({required bool privacyMode, required bool signedIn}) {
  if (privacyMode) return PrivacyAppRoot.standalone;
  return signedIn ? PrivacyAppRoot.signedIn : PrivacyAppRoot.signedOut;
}

class PrivacyStandalonePage extends StatelessWidget {
  const PrivacyStandalonePage({super.key, this.findPendant});

  final Future<String> Function()? findPendant;

  @override
  Widget build(BuildContext context) {
    return PrivacyShell(findPendant: findPendant);
  }
}
