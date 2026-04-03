import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

class BeepService {
  static final BeepService _i = BeepService._();
  factory BeepService() => _i;
  BeepService._();

  final _player = AudioPlayer();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    await _player.setReleaseMode(ReleaseMode.release);
    _ready = true;
  }

  /// Short tick beep — play on each countdown second
  Future<void> tick() => _play(
    frequency: 880,       // A5 — clear, sharp tick
    durationMs: 120,      // short
    amplitude: 0.6,
  );

  Future<void> go() => _play(
    frequency: 1320,      // E6 — bright, distinct from tick
    durationMs: 280,      // longer for emphasis
    amplitude: 0.85,
  );

  Future<void> _play({
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) async {
    try {
      await init();
      final bytes = _generateWav(
        frequency: frequency,
        durationMs: durationMs,
        amplitude: amplitude,
      );
      await _player.play(BytesSource(bytes));
    } catch (e) {
      print('=== BeepService: play error: $e');
    }
  }

  /// Generates a WAV file as bytes.
  /// Uses a sine wave with a short fade-out to avoid clicks.
  Uint8List _generateWav({
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) {
    const sampleRate   = 44100;
    const numChannels  = 1;      // mono
    const bitsPerSample = 16;

    final numSamples = (sampleRate * durationMs / 1000).round();
    final dataSize   = numSamples * numChannels * (bitsPerSample ~/ 8);

    // WAV header (44 bytes) + audio data
    final buffer = ByteData(44 + dataSize);

    // RIFF chunk
    _writeStr(buffer, 0,  'RIFF');
    buffer.setUint32(4,   36 + dataSize, Endian.little);
    _writeStr(buffer, 8,  'WAVE');

    // fmt sub-chunk
    _writeStr(buffer, 12, 'fmt ');
    buffer.setUint32(16, 16,           Endian.little); // chunk size
    buffer.setUint16(20,  1,           Endian.little); // PCM = 1
    buffer.setUint16(22, numChannels,  Endian.little);
    buffer.setUint32(24, sampleRate,   Endian.little);
    buffer.setUint32(28, sampleRate * numChannels * bitsPerSample ~/ 8,
                                       Endian.little); // byte rate
    buffer.setUint16(32, numChannels * bitsPerSample ~/ 8,
                                       Endian.little); // block align
    buffer.setUint16(34, bitsPerSample, Endian.little);

    // data sub-chunk
    _writeStr(buffer, 36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    // Generate sine wave samples with fade-out
    final fadeOutSamples = (sampleRate * 0.04).round(); // 40ms fade-out
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      double sample = math.sin(2 * math.pi * frequency * t) * amplitude;

      // Apply fade-out in the last 40ms to avoid audio click
      if (i >= numSamples - fadeOutSamples) {
        final fade = (numSamples - i) / fadeOutSamples;
        sample *= fade;
      }

      // Convert to 16-bit signed integer
      final int16 = (sample * 32767).round().clamp(-32768, 32767);
      buffer.setInt16(44 + i * 2, int16, Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  void _writeStr(ByteData buf, int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      buf.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  void dispose() => _player.dispose();
}