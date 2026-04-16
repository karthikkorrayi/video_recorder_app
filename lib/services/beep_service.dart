import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Generates and plays pure-tone beeps using raw WAV data.
/// Android-only app — iOS context omitted to avoid assertion errors.
class BeepService {
  static final BeepService _i = BeepService._();
  factory BeepService() => _i;
  BeepService._();

  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      // Android audio context — plays through speaker even during camera recording.
      // assistanceSonification = system sound type, bypasses camera audio routing.
      // audioFocus: none = doesn't interrupt other audio, just plays on top.
      AudioPlayer.global.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          usageType:       AndroidUsageType.alarm, // bypasses silent/vibration mode
          contentType:     AndroidContentType.sonification,
          audioFocus:      AndroidAudioFocus.gainTransientMayDuck, // duck other audio briefly
          isSpeakerphoneOn: true,
          stayAwake:       false,
        ),
        // iOS: use defaults — this is Android-only app
      ));
      _ready = true;
      debugPrint('=== BeepService: initialized');
    } catch (e) {
      // If AudioContext setup fails, mark ready anyway and try plain playback
      _ready = true;
      debugPrint('=== BeepService: AudioContext setup failed (will use defaults): $e');
    }
  }

  /// Short tick — each countdown second (5,4,3,2,1)
  Future<void> tick() => _play(frequency: 880, durationMs: 150, amplitude: 0.7);

  /// GO beep — recording starts
  Future<void> go() => _play(frequency: 1320, durationMs: 300, amplitude: 0.9);

  /// Warning — session ending soon (fires every 2 sec from 19:50)
  Future<void> blockWarning() async {
    await _play(frequency: 660,  durationMs: 180, amplitude: 1.0);
    await Future.delayed(const Duration(milliseconds: 80));
    await _play(frequency: 880,  durationMs: 180, amplitude: 1.0);
    await Future.delayed(const Duration(milliseconds: 80));
    await _play(frequency: 1100, durationMs: 280, amplitude: 1.0);
  }

  /// Block transition chime — soft double tone
  Future<void> blockTransition() async {
    await _play(frequency: 440, durationMs: 250, amplitude: 0.85);
    await Future.delayed(const Duration(milliseconds: 100));
    await _play(frequency: 880, durationMs: 350, amplitude: 0.9);
  }

  Future<void> _play({
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) async {
    if (!_ready) await init();
    try {
      final bytes  = _generateWav(
          frequency: frequency, durationMs: durationMs, amplitude: amplitude);
      final player = AudioPlayer();

      // Per-player Android context (belt and suspenders)
      try {
        await player.setAudioContext(AudioContext(
          android: AudioContextAndroid(
            usageType:        AndroidUsageType.alarm, // bypasses silent/vibration mode
            contentType:      AndroidContentType.sonification,
            audioFocus:       AndroidAudioFocus.gainTransientMayDuck,
            isSpeakerphoneOn: true,
            stayAwake:        false,
          ),
        ));
      } catch (_) {
        // If per-player context fails, proceed with global context
      }

      await player.setReleaseMode(ReleaseMode.release);
      await player.setVolume(1.0);
      await player.play(BytesSource(bytes));

      debugPrint('=== BeepService: ♪ ${frequency.toInt()}Hz ${durationMs}ms');

      // Dispose after playback completes
      Future.delayed(Duration(milliseconds: durationMs + 300), () {
        player.dispose();
      });
    } catch (e) {
      debugPrint('=== BeepService error: $e');
    }
  }

  /// Pure sine wave WAV — no file assets needed.
  Uint8List _generateWav({
    required double frequency,
    required int durationMs,
    required double amplitude,
  }) {
    const sampleRate    = 44100;
    const numChannels   = 1;
    const bitsPerSample = 16;
    final  numSamples   = (sampleRate * durationMs / 1000).round();
    final  dataSize     = numSamples * 2;
    final  buf          = ByteData(44 + dataSize);

    // WAV header
    _str(buf, 0,  'RIFF');
    buf.setUint32(4,  36 + dataSize, Endian.little);
    _str(buf, 8,  'WAVE');
    _str(buf, 12, 'fmt ');
    buf.setUint32(16, 16,                                         Endian.little);
    buf.setUint16(20, 1,                                          Endian.little); // PCM
    buf.setUint16(22, numChannels,                                Endian.little);
    buf.setUint32(24, sampleRate,                                 Endian.little);
    buf.setUint32(28, sampleRate * numChannels * bitsPerSample ~/ 8, Endian.little);
    buf.setUint16(32, numChannels * bitsPerSample ~/ 8,           Endian.little);
    buf.setUint16(34, bitsPerSample,                              Endian.little);
    _str(buf, 36, 'data');
    buf.setUint32(40, dataSize,                                   Endian.little);

    // Sine wave with fade-in (5ms) and fade-out (20ms) to prevent clicks
    final fadeIn  = (sampleRate * 0.005).round();
    final fadeOut = (sampleRate * 0.020).round();
    for (int i = 0; i < numSamples; i++) {
      double s = math.sin(2 * math.pi * frequency * i / sampleRate) * amplitude;
      if (i < fadeIn)                        s *= i / fadeIn;
      if (i >= numSamples - fadeOut)         s *= (numSamples - i) / fadeOut;
      buf.setInt16(44 + i * 2,
          (s * 32767).round().clamp(-32768, 32767), Endian.little);
    }
    return buf.buffer.asUint8List();
  }

  void _str(ByteData b, int offset, String s) {
    for (int i = 0; i < s.length; i++) b.setUint8(offset + i, s.codeUnitAt(i));
  }

  void dispose() { _ready = false; }
}