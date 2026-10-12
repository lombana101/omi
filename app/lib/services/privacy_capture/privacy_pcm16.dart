import 'dart:typed_data';

/// Pendant audio the staging listener accepts: 16 kHz, mono, signed PCM16 LE.
class PrivacyPcm16 {
  static const sampleRate = 16000;
  static const channels = 1;
  static const headerSize = 3;
  static const pcm8CodecId = 1;
  static const opusCodecId = 20;
  static const opusFs320CodecId = 21;
  static const pcm16CodecId = 0;

  /// Returns null when the packet cannot be proven to be the required format.
  static List<int>? encode(
    List<int> packet, {
    required int codecId,
    List<int> Function(List<int> opusPayload)? decodeOpus,
  }) {
    if (packet.length <= headerSize) return null;
    final payload = packet.sublist(headerSize);
    if (payload.isEmpty) return null;
    switch (codecId) {
      case pcm16CodecId:
        return payload.length.isEven ? payload : null;
      case pcm8CodecId:
        return _pcm8ToPcm16(payload);
      case opusCodecId:
      case opusFs320CodecId:
        final decode = decodeOpus;
        if (decode == null) return null;
        try {
          final samples = decode(payload);
          if (samples.isEmpty) return null;
          return _int16ToLittleEndian(samples);
        } catch (_) {
          return null;
        }
      default:
        return null;
    }
  }

  static List<int> _pcm8ToPcm16(List<int> payload) {
    final bytes = Uint8List(payload.length * 4);
    final data = ByteData.view(bytes.buffer);
    var offset = 0;
    for (final sample in payload) {
      final signed = ((sample & 0xff) - 128) << 8;
      data.setInt16(offset, signed, Endian.little);
      data.setInt16(offset + 2, signed, Endian.little);
      offset += 4;
    }
    return bytes;
  }

  static List<int> _int16ToLittleEndian(List<int> samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.view(bytes.buffer);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }
}
