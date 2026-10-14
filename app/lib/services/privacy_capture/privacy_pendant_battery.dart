import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/transports/device_transport.dart';

@immutable
class PrivacyPendantBatteryStatus {
  const PrivacyPendantBatteryStatus.disconnected()
      : connected = false,
        level = null;

  const PrivacyPendantBatteryStatus.unavailable()
      : connected = true,
        level = null;

  const PrivacyPendantBatteryStatus.reading(int level)
      : assert(level >= 0 && level <= 100),
        level = level,
        connected = true;

  final bool connected;
  final int? level;

  bool get available => connected && level != null;

  @override
  bool operator ==(Object other) =>
      other is PrivacyPendantBatteryStatus && other.connected == connected && other.level == level;

  @override
  int get hashCode => Object.hash(connected, level);
}

/// Keeps the privacy build's pendant battery entirely on the local BLE link.
///
/// Some supported devices do not expose a real battery source. In particular,
/// Friend Pendant's connector carries a legacy placeholder value; that must not
/// be presented to the owner as a measured percentage.
class PrivacyPendantBatteryMonitor extends ValueNotifier<PrivacyPendantBatteryStatus> {
  PrivacyPendantBatteryMonitor() : super(const PrivacyPendantBatteryStatus.disconnected());

  StreamSubscription<List<int>>? _batterySubscription;
  StreamSubscription<DeviceTransportState>? _connectionSubscription;
  var _generation = 0;

  Future<void> bind(DeviceConnection connection) async {
    final generation = ++_generation;
    await _cancelSubscriptions();
    if (generation != _generation) return;

    if (!await _isConnected(connection)) {
      value = const PrivacyPendantBatteryStatus.disconnected();
      return;
    }

    value = const PrivacyPendantBatteryStatus.unavailable();
    _connectionSubscription = connection.transport.connectionStateStream.listen((state) {
      if (generation != _generation) return;
      switch (state) {
        case DeviceTransportState.connected:
          unawaited(_refresh(connection, generation));
        case DeviceTransportState.connecting:
        case DeviceTransportState.disconnected:
        case DeviceTransportState.disconnecting:
          value = const PrivacyPendantBatteryStatus.disconnected();
      }
    });

    if (!_hasMeasuredBattery(connection.device.type)) return;

    try {
      final subscription = await connection.getBleBatteryLevelListener(
        onBatteryLevelChange: (level) {
          if (generation == _generation) _publishLevel(level);
        },
      );
      if (generation != _generation) {
        await subscription?.cancel();
        return;
      }
      _batterySubscription = subscription;
    } catch (_) {
      // An unsupported notification characteristic does not prevent a direct
      // local read below.
    }
    await _refresh(connection, generation);
  }

  Future<void> clear() async {
    _generation++;
    await _cancelSubscriptions();
    value = const PrivacyPendantBatteryStatus.disconnected();
  }

  Future<void> _refresh(DeviceConnection connection, int generation) async {
    if (generation != _generation) return;
    if (!_hasMeasuredBattery(connection.device.type)) {
      value = const PrivacyPendantBatteryStatus.unavailable();
      return;
    }
    if (!await _isConnected(connection)) {
      if (generation == _generation) value = const PrivacyPendantBatteryStatus.disconnected();
      return;
    }
    try {
      final level = await connection.retrieveBatteryLevel();
      if (generation == _generation) _publishLevel(level);
    } catch (_) {
      if (generation == _generation) value = const PrivacyPendantBatteryStatus.unavailable();
    }
  }

  Future<bool> _isConnected(DeviceConnection connection) async {
    try {
      return await connection.isConnected();
    } catch (_) {
      return false;
    }
  }

  void _publishLevel(int level) {
    value = level >= 0 && level <= 100
        ? PrivacyPendantBatteryStatus.reading(level)
        : const PrivacyPendantBatteryStatus.unavailable();
  }

  bool _hasMeasuredBattery(DeviceType type) {
    return type != DeviceType.friendPendant && type != DeviceType.raybanMeta;
  }

  Future<void> _cancelSubscriptions() async {
    await _batterySubscription?.cancel();
    _batterySubscription = null;
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_cancelSubscriptions());
    super.dispose();
  }
}
