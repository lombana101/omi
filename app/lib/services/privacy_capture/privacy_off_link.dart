import 'dart:typed_data';

import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';

class PrivacyLinkDiagnostics {
  const PrivacyLinkDiagnostics({
    required this.buttonSubscribed,
    required this.audioSubscribed,
    this.lastButtonCode,
  });

  final bool buttonSubscribed;
  final bool audioSubscribed;
  final int? lastButtonCode;

  Map<String, Object?> toJson() => <String, Object?>{
        'buttonSubscribed': buttonSubscribed,
        'audioSubscribed': audioSubscribed,
        'lastButtonCode': lastButtonCode,
        'recording': 'off',
      };
}

int? privacyButtonCode(List<int> payload) {
  if (payload.length < 4) return null;
  final bytes = Uint8List.fromList(payload.sublist(0, 4).reversed.toList());
  return ByteData.view(bytes.buffer).getUint32(0);
}

/// Button notify is armed. Audio stays down until a later StartCaptureAck.
Future<PrivacyLinkDiagnostics> armPrivacyOffLink(
  PrivacyBlePort ble, {
  required void Function(int code) onButton,
}) async {
  await ble.unsubscribeAudio();
  int? lastCode;
  final confirmed = await ble.maintainButtonNotifications(onButton: (payload) {
    final code = privacyButtonCode(payload);
    if (code == null) return;
    lastCode = code;
    onButton(code);
  });
  return PrivacyLinkDiagnostics(
    buttonSubscribed: confirmed,
    audioSubscribed: false,
    lastButtonCode: lastCode,
  );
}

class PrivacyConnectDecision {
  const PrivacyConnectDecision({required this.armButton, required this.label});

  final bool armButton;
  final String label;
}

PrivacyConnectDecision decidePrivacyConnect({required bool linkEstablished, required String name}) {
  if (!linkEstablished || name.isEmpty) {
    return const PrivacyConnectDecision(armButton: false, label: 'Not connected');
  }
  return PrivacyConnectDecision(armButton: true, label: 'Connected $name');
}

bool privacyBlocksStockAudio({required bool privacyMode, required bool recordingAuthorized}) {
  return privacyMode && !recordingAuthorized;
}
