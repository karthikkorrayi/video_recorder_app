import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

class BeepService {
  static final BeepService _i = BeepService._();
  factory BeepService() => _i;
  BeepService._();

  final _player = AudioPlayer();
  final _player2 = AudioPlayer(); // second player for overlapping alerts
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    await _player.setReleaseMode(ReleaseMode.release);
    await _player2.setReleaseMode(ReleaseMode.release);
    _ready = true;
  }

  /// Short tick — each countdown second (5, 4, 3, 2, 1)
  Future<void> tick() => _play(_player,
    frequency: 880, durationMs: 120, amplitude: 0.6);

  /// GO beep — when recording starts
  Future<void> go() => _play(_player,
    frequency: 1320, durationMs: 280, amplitude: 0.85);

  /// Warning alert — plays at 19:50 (block about to end)
  /// Three rapid ascending beeps to grab attention
  Future<void> blockWarning() async {
    await init();
    // beep-beep-beep ascending
    await _play(_player,  frequency: 660,  durationMs: 180, amplitude: 0.9);
    await Future.delayed(const Duration(milliseconds: 80));
    await _play(_player2, frequency: 880,  durationMs: 180, amplitude: 0.9);
    await Future.delayed(const Duration(milliseconds: 80));
    await _play(_player,  frequency: 1100, durationMs: 280, amplitude: 0.9);
  }

  /// Block save + new start tone — plays at 20:00 when auto-splitting
  /// Two-tone chime: save → start fresh
  Future<void> blockTransition() async {
    await init();
    // Low-high chime: "saving... new block starting"
    await _play(_player,  frequency: 440,  durationMs: 250, amplitude: 0.9);
    await Future.delayed(const Duration(milliseconds: 100));
    await _play(_player2, frequency: 880,  durationMs: 350, amplitude: 0.95);
  }

  Future<void> _play(AudioPlayer p, {
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) async {
    try {
      await init();
      final bytes = _wav(frequency: frequency, durationMs: durationMs, amplitude: amplitude);
      await p.play(BytesSource(bytes));
    } catch (e) {
      print('=== BeepService: $e');
    }
  }

  Uint8List _wav({
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) {
    const sampleRate    = 44100;
    const numChannels   = 1;
    const bitsPerSample = 16;
    final numSamples = (sampleRate * durationMs / 1000).round();
    final dataSize   = numSamples * 2;
    final buf        = ByteData(44 + dataSize);

    _str(buf, 0,  'RIFF');
    buf.setUint32(4,  36 + dataSize, Endian.little);
    _str(buf, 8,  'WAVE');
    _str(buf, 12, 'fmt ');
    buf.setUint32(16, 16,          Endian.little);
    buf.setUint16(20, 1,           Endian.little);
    buf.setUint16(22, numChannels, Endian.little);
    buf.setUint32(24, sampleRate,  Endian.little);
    buf.setUint32(28, sampleRate * 2, Endian.little);
    buf.setUint16(32, 2,           Endian.little);
    buf.setUint16(34, bitsPerSample, Endian.little);
    _str(buf, 36, 'data');
    buf.setUint32(40, dataSize,    Endian.little);

    final fadeOut = (sampleRate * 0.04).round();
    for (int i = 0; i < numSamples; i++) {
      double s = math.sin(2 * math.pi * frequency * i / sampleRate) * amplitude;
      if (i >= numSamples - fadeOut) s *= (numSamples - i) / fadeOut;
      buf.setInt16(44 + i * 2, (s * 32767).round().clamp(-32768, 32767), Endian.little);
    }
    return buf.buffer.asUint8List();
  }

  void _str(ByteData b, int o, String s) {
    for (int i = 0; i < s.length; i++) b.setUint8(o + i, s.codeUnitAt(i));
  }

  void dispose() {
    _player.dispose();
    _player2.dispose();
  }
}