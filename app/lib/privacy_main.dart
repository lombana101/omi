import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

import 'package:omi/backend/preferences.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/privacy_capture/privacy_capture_feature.dart';
import 'package:omi/services/privacy_capture/privacy_copy.dart';
import 'package:omi/services/privacy_capture/privacy_standalone.dart';

/// Dedicated entry point for the personal privacy build.
///
/// Keeping this separate from `main.dart` prevents the privacy artifact from
/// depending on generated Firebase configuration or the normal Omi startup
/// graph at compile time as well as at runtime.
void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      try {
        await SharedPreferencesUtil.init();
        await SharedPreferencesUtil().setCaptureMuted(true);
        initOpus(await opus_flutter.load());
        BleFlutterApi.setUp(BleBridge.instance);
        PrivacyCaptureHost.startDeviceRuntime();
        await PrivacyCaptureHost.ensureReady();
      } catch (_) {
        PrivacyCaptureHost.bootError = PrivacyCopy.storeUnavailable;
      }
      runApp(const PrivacyStandaloneApp());
    },
    (error, stack) {
      // Never print exception text here: plugin errors can include private
      // endpoint details. The type is enough to diagnose the failure class.
      debugPrint('Privacy runtime error: ${error.runtimeType}');
    },
  );
}
