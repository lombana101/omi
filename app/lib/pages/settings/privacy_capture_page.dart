import 'package:flutter/material.dart';

import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/ui/ui.dart';

/// Device-settings entry. Capture itself stays on the privacy shell.
class PrivacyCapturePage extends StatelessWidget {
  const PrivacyCapturePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const OmiBackButton(), title: const Text(PrivacyCopy.settings)),
      body: ListView(
        padding: const EdgeInsets.all(OmiSpacing.md),
        children: const [
          Text(PrivacyCopy.privacyExplain),
          Text(PrivacyCopy.offExplain),
          Text(PrivacyCopy.selfOnlyExplain),
          Text(PrivacyCopy.remoteUnavailable),
        ],
      ),
    );
  }
}
