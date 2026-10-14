import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:omi/l10n/app_localizations.dart';
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

/// Minimal privacy-only root. It deliberately has no Firebase, normal Omi
/// provider graph, analytics, notification, WAL, or upstream-health dependency.
class PrivacyStandaloneApp extends StatelessWidget {
  const PrivacyStandaloneApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Omi Privacy',
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PrivacyStandalonePage(),
      );
}
