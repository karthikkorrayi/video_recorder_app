import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

class BeepService {
  static final BeepService _i = BeepService._();
  factory BeepService() => _i;
  BeepService._();

  // Use fresh players each time instead of reusing disposed ones
  bool _ready = false;

  Future<void> init() async {
    _ready = true;
  }

  /// Short tick — each countdown second
  Future<void> tick() => _play(frequency: 880, durationMs: 120, amplitude: 0.6);

  /// GO beep — when recording starts
  Future<void> go() => _play(frequency: 1320, durationMs: 280, amplitude: 0.85);

  /// Warning — block about to end
  Future<void> blockWarning() async {
    await _play(frequency: 660,  durationMs: 180, amplitude: 0.9);
    await Future.delayed(const Duration(milliseconds: 80));
    await _play(frequency: 880,  durationMs: 180, amplitude: 0.9);
    await Future.delayed(const Duration(milliseconds: 80));
    await _play(frequency: 1100, durationMs: 280, amplitude: 0.9);
  }

  /// Block transition chime
  Future<void> blockTransition() async {
    await _play(frequency: 440, durationMs: 250, amplitude: 0.9);
    await Future.delayed(const Duration(milliseconds: 100));
    await _play(frequency: 880, durationMs: 350, amplitude: 0.95);
  }

  // ── KEY FIX: create a new AudioPlayer for every sound ──────────────────
  // AudioPlayer.dispose() permanently kills the player — reusing a disposed
  // player silently fails. Creating a fresh one each time is cheap and correct.
  Future<void> _play({
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) async {
    try {
      final bytes = _wav(frequency: frequency, durationMs: durationMs, amplitude: amplitude);
      final player = AudioPlayer();
      await player.setReleaseMode(ReleaseMode.release);
      await player.play(BytesSource(bytes));
      // Dispose after sound finishes (non-blocking)
      Future.delayed(Duration(milliseconds: durationMs + 200), () {
        player.dispose();
      });
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
    buf.setUint32(16, 16,             Endian.little);
    buf.setUint16(20, 1,              Endian.little);
    buf.setUint16(22, numChannels,    Endian.little);
    buf.setUint32(24, sampleRate,     Endian.little);
    buf.setUint32(28, sampleRate * 2, Endian.little);
    buf.setUint16(32, 2,              Endian.little);
    buf.setUint16(34, bitsPerSample,  Endian.little);
    _str(buf, 36, 'data');
    buf.setUint32(40, dataSize,       Endian.little);

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

  // Don't dispose the singleton — just mark not ready so init() re-runs
  void dispose() { _ready = false; }
}