import 'dart:async';
import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:omi/services/devices/models.dart';
import 'package:omi/services/devices/transports/device_transport.dart';
import 'package:omi/services/devices/transports/native_ble_transport.dart';
import 'package:omi/services/privacy_capture/privacy_capture_config.dart';
import 'package:omi/services/privacy_capture/privacy_capture_controller.dart';

SimpleOpusDecoder? _pendantOpus;

List<int> decodePendantOpus(List<int> payload) {
  final decoder = _pendantOpus ??= SimpleOpusDecoder(sampleRate: 16000, channels: 1);
  return decoder.decode(input: Uint8List.fromList(payload));
}

/// Subscribes to the button characteristic and can drop the audio CCCD.
class TransportPrivacyBle implements PrivacyBlePort {
  TransportPrivacyBle(this.transport);

  final DeviceTransport transport;
  StreamSubscription<List<int>>? _buttonSub;
  void Function(List<int> payload)? onButton;

  @override
  Future<bool> get isConnected => transport.isConnected();

  @override
  Future<bool> maintainButtonNotifications({void Function(List<int> payload)? onButton}) async {
    if (onButton != null) this.onButton = onButton;
    _buttonSub ??=
        transport.getCharacteristicStream(buttonServiceUuid, buttonTriggerCharacteristicUuid).listen((payload) {
      this.onButton?.call(payload);
    });
    final native = transport;
    if (native is NativeBleTransport) {
      return native.confirmNotification(buttonServiceUuid, buttonTriggerCharacteristicUuid);
    }
    return _buttonSub != null;
  }

  @override
  Future<Stream<List<int>>> subscribeAudio() async {
    return transport.getCharacteristicStream(omiServiceUuid, audioDataStreamCharacteristicUuid);
  }

  @override
  Future<int> audioCodecId() async {
    final value = await transport.readCharacteristic(omiServiceUuid, audioCodecCharacteristicUuid);
    if (value.isEmpty) return -1;
    return value[0];
  }

  @override
  Future<void> unsubscribeAudio() async {
    final native = transport;
    if (native is NativeBleTransport) {
      await native.releaseCharacteristic(omiServiceUuid, audioDataStreamCharacteristicUuid);
      return;
    }
  }
}

class IoPrivacySocket implements PrivacySocketPort {
  @override
  Future<PrivacySocketSession> connect({required Uri url, required String authorizationHeader}) async {
    final channel = IOWebSocketChannel.connect(
      url,
      headers: <String, dynamic>{'Authorization': authorizationHeader},
      pingInterval: PrivacyCaptureConfig.socketPingInterval,
    );
    await channel.ready;
    return _IoPrivacySocketSession(channel);
  }
}

class _IoPrivacySocketSession implements PrivacySocketSession {
  _IoPrivacySocketSession(this._channel) {
    _channel.stream.listen(
      _incoming.add,
      onError: (_) => _incoming.add(const PrivacySocketClosed(1008)),
      onDone: () => _incoming.add(PrivacySocketClosed(_channel.closeCode, reason: _channel.closeReason)),
    );
  }

  final WebSocketChannel _channel;
  final StreamController<Object?> _incoming = StreamController<Object?>.broadcast();

  @override
  Stream<Object?> get messages => _incoming.stream;

  @override
  void sendText(String text) => _channel.sink.add(text);

  @override
  void sendBytes(List<int> bytes) => _channel.sink.add(bytes);

  @override
  Future<void> close() async {
    await _channel.sink.close();
    await _incoming.close();
  }
}
