import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/video_processor.dart';
import '../services/beep_service.dart';

// ── States ────────────────────────────────────────────────────────────────────
// init      → camera initialising
// detecting → waiting for hands or manual tap
// countdown → 5-4-3-2-1 beeps before recording
// recording → actively recording
// splitting → silent 5-min chunk boundary (camera stops/starts in background)
// sessionEnd→ 20-min session complete, saved, prompting for next session
// stopping  → user manually stopped
// saved     → brief confirmation before returning to detecting
enum _S { init, detecting, countdown, recording, splitting, sessionEnd, stopping, saved }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _ctrl;
  _S _state = _S.init;
  bool _torchOn       = false;
  int  _countdown     = 0;
  bool _processingFrame = false;
  bool _autoDetect    = false;
  int  _savedCount    = 0;

  // ── Timing constants ──────────────────────────────────────────────────────
  static const int _sessionSecs = 20 * 60; // 20 min — full session duration
  static const int _chunkSecs   =  5 * 60; // 5 min  — silent chunk boundary
  static const int _warnSecs    =     30;  // warn 30s before session ends

  // ── Timers & tracking ─────────────────────────────────────────────────────
  Timer?   _ticker;
  DateTime? _sessionStart; // when the 20-min session started
  DateTime? _chunkStart;   // when the current 5-min chunk started
  bool _sessionWarnFired = false;
  bool _chunkWarnFired   = false;

  // Session elapsed = total time since _sessionStart
  Duration get _sessionElapsed => _sessionStart == null
      ? Duration.zero
      : DateTime.now().difference(_sessionStart!);

  // Chunk elapsed = time since current chunk started
  Duration get _chunkElapsed => _chunkStart == null
      ? Duration.zero
      : DateTime.now().difference(_chunkStart!);

  // For UI display — show session total time
  Duration _displayElapsed = Duration.zero;

  final _pose = PoseDetector(options: PoseDetectorOptions());
  final _beep = BeepService();
  InputImageRotation _mlRotation = InputImageRotation.rotation90deg;

  static const _green   = Color(0xFF00C853);
  static const _red     = Color(0xFFE53935);
  static const _white   = Color(0xFFFFFFFF);
  static const _surface = Color(0xFFF5F5F5);
  static const _text    = Color(0xFF1A1A1A);
  static const _sub     = Color(0xFF888888);
  static const _border  = Color(0xFFE8E8E8);

  bool get _isRecording  => _state == _S.recording;
  bool get _isCounting   => _state == _S.countdown;
  bool get _isSplitting  => _state == _S.splitting;
  bool get _isDetecting  => _state == _S.detecting;
  bool get _isSessionEnd => _state == _S.sessionEnd;
  bool get _isSaved      => _state == _S.saved;

  // Warning: 30s before session end
  bool get _isWarning => _isRecording &&
      _sessionElapsed.inSeconds >= _sessionSecs - _warnSecs;

  // Progress bar: session progress (0.0 → 1.0)
  double get _sessionProgress =>
      (_sessionElapsed.inSeconds / _sessionSecs).clamp(0.0, 1.0);

  String get _remainingLabel {
    final r = _sessionSecs - _sessionElapsed.inSeconds;
    return r <= 0 ? '00:00' : _fmt(Duration(seconds: r));
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _beep.init();
    _initCamera();
  }

  // ── Camera init ───────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (!mounted) return;
    _ctrl = CameraController(
      cams[0], ResolutionPreset.veryHigh,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _ctrl!.initialize();
    try {
      await _ctrl!.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
    } catch (_) {}
    _mlRotation = InputImageRotation.rotation0deg;
    try { await _ctrl!.setZoomLevel(await _ctrl!.getMinZoomLevel()); } catch (_) {}
    try { await _ctrl!.setExposureMode(ExposureMode.auto); } catch (_) {}
    if (!mounted) return;
    setState(() => _state = _S.detecting);
  }

  // ── Hand detection stream ─────────────────────────────────────────────────
  void _startStream() {
    if (_state != _S.detecting || _ctrl == null) return;
    try { _ctrl!.startImageStream(_onFrame); } catch (_) {}
  }

  Future<void> _stopStream() async {
    try {
      if (_ctrl?.value.isStreamingImages == true) await _ctrl!.stopImageStream();
    } catch (_) {}
  }

  Future<void> _onFrame(CameraImage img) async {
    if (_state != _S.detecting || _processingFrame) return;
    _processingFrame = true;
    try {
      final buf = WriteBuffer();
      for (final p in img.planes) buf.putUint8List(p.bytes);
      final input = InputImage.fromBytes(
        bytes: buf.done().buffer.asUint8List(),
        metadata: InputImageMetadata(
          size: Size(img.width.toDouble(), img.height.toDouble()),
          rotation: _mlRotation,
          format: InputImageFormat.nv21,
          bytesPerRow: img.planes[0].bytesPerRow,
        ),
      );
      final poses = await _pose.processImage(input);
      if (!mounted || _state != _S.detecting) return;
      bool both = false;
      if (poses.isNotEmpty) {
        final lw = poses.first.landmarks[PoseLandmarkType.leftWrist];
        final rw = poses.first.landmarks[PoseLandmarkType.rightWrist];
        if (lw != null && rw != null) both = lw.likelihood > 0.55 && rw.likelihood > 0.55;
      }
      if (both) {
        await _stopStream();
        if (mounted && _state == _S.detecting) _doCountdown();
      }
    } finally {
      _processingFrame = false;
    }
  }

  Future<void> _toggleAutoDetect() async {
    if (_isRecording || _isCounting) return;
    final next = !_autoDetect;
    setState(() => _autoDetect = next);
    if (next) _startStream(); else await _stopStream();
  }

  // ── 5-sec countdown with beeps ────────────────────────────────────────────
  Future<void> _doCountdown() async {
    if (!mounted) return;
    setState(() { _state = _S.countdown; _countdown = 5; });
    for (int i = 5; i >= 1; i--) {
      if (!mounted || _state != _S.countdown) return;
      setState(() => _countdown = i);
      _beep.tick();
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted || _state != _S.countdown) return;
    setState(() => _countdown = 0);
    await _beep.go();
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted || _state != _S.countdown) return;
    await _startSession();
  }

  Future<void> _manualStart() async {
    if (_state != _S.detecting && _state != _S.sessionEnd) return;
    await _stopStream();
    setState(() => _autoDetect = false);
    if (mounted) _doCountdown();
  }

  // ── Start a full 20-min session ───────────────────────────────────────────
  Future<void> _startSession() async {
    try {
      await _ctrl!.startVideoRecording();
      final now = DateTime.now();
      _sessionStart       = now;
      _chunkStart         = now;
      _sessionWarnFired   = false;
      _chunkWarnFired     = false;
      if (!mounted) return;
      setState(() {
        _state          = _S.recording;
        _displayElapsed = Duration.zero;
      });

      _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }

        final sessionSecs = _sessionElapsed.inSeconds;
        final chunkSecs   = _chunkElapsed.inSeconds;

        setState(() => _displayElapsed = _sessionElapsed);

        // ── Session warning: 30s before 20-min mark ─────────────────────
        if (!_sessionWarnFired && sessionSecs >= _sessionSecs - _warnSecs) {
          _sessionWarnFired = true;
          _beep.blockWarning(); // 3 ascending beeps
          print('=== Session warning: ${_remainingLabel} remaining');
        }

        // ── Silent chunk boundary: every 5 min ──────────────────────────
        // This saves 5-min chunks for upload stability — user doesn't see it
        if (chunkSecs >= _chunkSecs && sessionSecs < _sessionSecs) {
          _ticker?.cancel();
          await _silentChunkSplit();
          return;
        }

        // ── Session end: 20 min reached ──────────────────────────────────
        if (sessionSecs >= _sessionSecs) {
          _ticker?.cancel();
          await _endSession();
        }
      });
    } catch (e) {
      print('=== startSession: $e');
      if (mounted) setState(() { _state = _S.detecting; _displayElapsed = Duration.zero; });
    }
  }

  // ── Silent 5-min chunk split — user sees nothing except brief indicator ───
  Future<void> _silentChunkSplit() async {
    if (!_isRecording) return;
    setState(() => _state = _S.splitting);
    try {
      final endTime = DateTime.now();
      final file    = await _ctrl!.stopVideoRecording();
      // Save this chunk — processing runs in background
      VideoProcessor().startBackgroundProcessing(
        rawVideoPath: file.path,
        sessionTime:  _chunkStart!,
        recordingEnd: endTime,
      );
      await _beep.blockTransition(); // soft chime
      // Immediately start next chunk — seamless for user
      await _ctrl!.startVideoRecording();
      _chunkStart       = DateTime.now();
      _chunkWarnFired   = false;
      if (!mounted) return;
      setState(() => _state = _S.recording);
      // Restart ticker
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }
        final sessionSecs = _sessionElapsed.inSeconds;
        final chunkSecs   = _chunkElapsed.inSeconds;
        setState(() => _displayElapsed = _sessionElapsed);
        if (!_sessionWarnFired && sessionSecs >= _sessionSecs - _warnSecs) {
          _sessionWarnFired = true;
          _beep.blockWarning();
        }
        if (chunkSecs >= _chunkSecs && sessionSecs < _sessionSecs) {
          _ticker?.cancel();
          await _silentChunkSplit();
          return;
        }
        if (sessionSecs >= _sessionSecs) {
          _ticker?.cancel();
          await _endSession();
        }
      });
    } catch (e) {
      print('=== chunk split error: $e');
      if (mounted) setState(() { _state = _S.detecting; _displayElapsed = Duration.zero; });
    }
  }

  // ── 20-min session complete — save final chunk, prompt for next session ───
  Future<void> _endSession() async {
    if (!_isRecording) return;
    _ticker?.cancel();
    setState(() => _state = _S.splitting);
    try {
      final endTime = DateTime.now();
      final file    = await _ctrl!.stopVideoRecording();
      // Save the final chunk
      VideoProcessor().startBackgroundProcessing(
        rawVideoPath: file.path,
        sessionTime:  _chunkStart!,
        recordingEnd: endTime,
      );
      _savedCount++;
      if (!mounted) return;

      // ── Show session-end prompt ──────────────────────────────────────
      // Play 3 descending beeps to signal session complete
      await _beep.blockWarning();
      setState(() {
        _state          = _S.sessionEnd;
        _displayElapsed = Duration.zero;
        _sessionStart   = null;
        _chunkStart     = null;
      });

      // Auto-start hand detection for next session
      if (_autoDetect) {
        await Future.delayed(const Duration(seconds: 1));
        if (mounted && _state == _S.sessionEnd) _startStream();
      }
    } catch (e) {
      print('=== endSession error: $e');
      if (mounted) setState(() { _state = _S.detecting; _displayElapsed = Duration.zero; });
    }
  }

  // ── Manual stop by user ───────────────────────────────────────────────────
  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    _ticker?.cancel();
    setState(() => _state = _S.stopping);
    try {
      final endTime = DateTime.now();
      final file    = await _ctrl!.stopVideoRecording();
      VideoProcessor().startBackgroundProcessing(
        rawVideoPath: file.path,
        sessionTime:  _chunkStart ?? endTime.subtract(const Duration(minutes: 1)),
        recordingEnd: endTime,
      );
      _savedCount++;
      if (!mounted) return;
      setState(() {
        _state          = _S.saved;
        _displayElapsed = Duration.zero;
        _sessionStart   = null;
        _chunkStart     = null;
      });
      await Future.delayed(const Duration(seconds: 3));
      if (mounted && _state == _S.saved) setState(() => _state = _S.detecting);
    } catch (e) {
      if (mounted) setState(() { _state = _S.detecting; _displayElapsed = Duration.zero; });
    }
  }

  void _goHome() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    Navigator.popUntil(context, (r) => r.isFirst);
  }

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    try { await _ctrl?.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off); } catch (_) {}
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  void dispose() {
    _ticker?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();
    _stopStream();
    _ctrl?.dispose();
    _pose.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _S.init || _ctrl == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
        body: Center(child: CircularProgressIndicator(color: _green)));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(children: [
        // ── LEFT: Camera preview ────────────────────────────────────────
        Expanded(flex: 58, child: Stack(children: [
          Positioned.fill(child: CameraPreview(_ctrl!)),

          // Info badges top-left
          Positioned(top: 14, left: 14,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _pill('Standard · 1.0x · 1080p · 30fps',
                  Colors.black.withValues(alpha: 0.6), Colors.white),
              const SizedBox(height: 6),
              if (_isRecording || _isSplitting)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.fiber_manual_record, color: Colors.white, size: 9),
                    const SizedBox(width: 4),
                    Text(_fmt(_displayElapsed),
                        style: const TextStyle(color: Colors.white, fontSize: 14,
                            fontWeight: FontWeight.bold, letterSpacing: 1)),
                  ])),
              if (_savedCount > 0 && !_isRecording) ...[
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _green.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.check_circle, color: Colors.white, size: 12),
                    const SizedBox(width: 4),
                    Text('$_savedCount saved',
                        style: const TextStyle(color: Colors.white, fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ])),
              ],
            ])),

          // ── Countdown overlay ──────────────────────────────────────────
          if (_isCounting && _countdown > 0)
            Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 110, height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.65),
                  border: Border.all(
                      color: _countdown <= 2 ? _red : _green, width: 3)),
                child: Center(child: Text('$_countdown',
                    style: TextStyle(
                        color: _countdown <= 2 ? _red : Colors.white,
                        fontSize: 58, fontWeight: FontWeight.bold)))),
              const SizedBox(height: 10),
              _pill('Recording starts soon...',
                  Colors.black.withValues(alpha: 0.6), Colors.white70),
            ])),

          // ── Session end overlay — "Show hands for next session" ────────
          if (_isSessionEnd)
            Container(
              color: Colors.black.withValues(alpha: 0.75),
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle, color: _green, size: 52),
                const SizedBox(height: 12),
                const Text('20-Min Session Complete!',
                    style: TextStyle(color: Colors.white, fontSize: 18,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                _pill('Session saved · $_savedCount total',
                    _green.withValues(alpha: 0.3), Colors.white),
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white24)),
                  child: const Column(children: [
                    Icon(Icons.back_hand_rounded, color: _green, size: 32),
                    SizedBox(height: 8),
                    Text('Show both hands to start next session',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 14,
                            fontWeight: FontWeight.w500)),
                    SizedBox(height: 4),
                    Text('or tap "Start Next" button →',
                        style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ])),
              ])),
            ),

          // ── Silent chunk split overlay (brief flash) ───────────────────
          if (_isSplitting && !_isSessionEnd)
            Positioned(top: 60, left: 0, right: 0,
              child: Center(child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 12, height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: _green)),
                  SizedBox(width: 8),
                  Text('Auto-saving chunk...',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ])))),

          // ── Saved confirmation overlay ─────────────────────────────────
          if (_isSaved)
            Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(16)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.check_circle, color: _green, size: 48),
                const SizedBox(height: 10),
                const Text('Recording Saved!',
                    style: TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text('Ready for next session',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
              ]))),

          // ── Warning banner: 30s before session end ─────────────────────
          if (_isWarning)
            Positioned(bottom: 14, left: 14, right: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Text('Session ends in $_remainingLabel — get ready!',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ]))),
        ])),

        // ── RIGHT: Control panel ────────────────────────────────────────
        Expanded(flex: 42, child: Container(
          color: _surface,
          child: LayoutBuilder(builder: (ctx, constraints) {
            return Column(children: [

              // Header
              Container(
                color: _white,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Text('SESSION', style: TextStyle(fontSize: 9,
                        fontWeight: FontWeight.w800, color: _sub, letterSpacing: 1.4)),
                    const Spacer(),
                    if (_savedCount > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                            color: _green.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: _green.withValues(alpha: 0.4))),
                        child: Text('$_savedCount done',
                            style: const TextStyle(color: _green, fontSize: 10,
                                fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 4),
                  // Timer display
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Flexible(child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _isRecording || _isSplitting
                            ? _fmt(_displayElapsed) : '--:--',
                        style: TextStyle(
                          fontSize: 34, fontWeight: FontWeight.bold,
                          color: _isWarning ? _red : _text,
                          letterSpacing: 1.2)),
                    )),
                    const SizedBox(width: 8),
                    if (_isRecording)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                            color: _red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(color: _red.withValues(alpha: 0.4))),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(width: 6, height: 6,
                              decoration: const BoxDecoration(
                                  color: _red, shape: BoxShape.circle)),
                          const SizedBox(width: 4),
                          const Text('REC', style: TextStyle(color: _red,
                              fontSize: 10, fontWeight: FontWeight.w800,
                              letterSpacing: 1)),
                        ])),
                  ]),

                  // Session progress bar (20-min total)
                  if (_isRecording || _isSplitting) ...[
                    const SizedBox(height: 6),
                    ClipRRect(borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: _sessionProgress, minHeight: 5,
                        backgroundColor: _border,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            _isWarning ? _red : _green))),
                    const SizedBox(height: 3),
                    Row(children: [
                      const Text('20-min session',
                          style: TextStyle(color: _sub, fontSize: 9)),
                      const Spacer(),
                      Text('$_remainingLabel left',
                          style: TextStyle(
                              color: _isWarning ? _red : _sub, fontSize: 9,
                              fontWeight: _isWarning
                                  ? FontWeight.w700 : FontWeight.normal)),
                    ]),
                  ],

                  // Countdown display
                  if (_isCounting) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: (_countdown <= 2 ? _red : _green)
                            .withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                            color: (_countdown <= 2 ? _red : _green)
                                .withValues(alpha: 0.4))),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.volume_up_rounded, size: 12,
                              color: _countdown <= 2 ? _red : _green),
                          const SizedBox(width: 5),
                          Text('Starting in $_countdown...',
                              style: TextStyle(fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: _countdown <= 2 ? _red : _green)),
                        ])),
                  ],

                  // Session-end prompt in control panel too
                  if (_isSessionEnd) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: _green.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _green.withValues(alpha: 0.3))),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.back_hand_outlined, size: 14, color: _green),
                          SizedBox(width: 6),
                          Text('Show hands or tap Start',
                              style: TextStyle(color: _green, fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        ])),
                  ],
                ]),
              ),

              const Divider(height: 1, color: _border),

              // Controls
              Expanded(child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(children: [
                  // Home + Flash
                  Expanded(flex: 2, child: Row(children: [
                    Expanded(child: _CtrlTile(
                      icon: Icons.home_rounded, label: 'Home',
                      onTap: _goHome)),
                    const SizedBox(width: 8),
                    Expanded(child: _CtrlTile(
                      icon: _torchOn
                          ? Icons.flashlight_on : Icons.flashlight_off,
                      label: _torchOn ? 'Flash ON' : 'Flash',
                      active: _torchOn,
                      activeColor: const Color(0xFFFFB300),
                      onTap: _toggleTorch)),
                  ])),
                  const SizedBox(height: 8),
                  // Hand detect
                  Expanded(flex: 2, child: _CtrlTile(
                    icon: _autoDetect
                        ? Icons.back_hand_rounded
                        : Icons.back_hand_outlined,
                    label: _autoDetect
                        ? 'Hand Detect: ON' : 'Hand Detect: OFF',
                    active: _autoDetect,
                    activeColor: _green,
                    fullWidth: true,
                    onTap: (!_isRecording && !_isCounting)
                        ? _toggleAutoDetect : null)),
                  const SizedBox(height: 8),
                  // Info card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(color: _white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _border)),
                    child: const Row(children: [
                      Column(crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('1080p · 30fps', style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700,
                              color: _text)),
                          SizedBox(height: 1),
                          Text('Standard 1.0x',
                              style: TextStyle(fontSize: 9, color: _sub)),
                        ]),
                      Spacer(),
                      Column(crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('Session = 20 min', style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700,
                              color: _text)),
                          SizedBox(height: 1),
                          Text('Chunk = 5 min',
                              style: TextStyle(fontSize: 9, color: _sub)),
                        ]),
                    ]),
                  ),
                  const SizedBox(height: 8),
                  _buildActionBtn(),
                ]),
              )),
            ]);
          }),
        )),
      ]),
    );
  }

  Widget _pill(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
    child: Text(text, style: TextStyle(color: fg, fontSize: 11,
        fontWeight: FontWeight.w500)),
  );

  Widget _buildActionBtn() {
    if (_isDetecting || _isSaved) {
      return _ActionBtn(
        icon: Icons.play_arrow_rounded,
        label: _isSaved ? 'Record Again' : 'Start Recording',
        color: _green,
        onTap: _isSaved
            ? () => setState(() => _state = _S.detecting)
            : _manualStart,
      );
    }
    // Session end — prompt for next session
    if (_isSessionEnd) {
      return _ActionBtn(
        icon: Icons.replay_rounded,
        label: 'Start Next Session',
        color: _green,
        onTap: _manualStart,
      );
    }
    if (_isRecording) {
      return _ActionBtn(
        icon: Icons.stop_rounded,
        label: 'Stop Recording',
        color: _red,
        onTap: _stopRecording,
      );
    }
    if (_isCounting) {
      return _ActionBtn(
        icon: Icons.hourglass_top_rounded,
        label: 'Starting in $_countdown...',
        color: Colors.grey.shade400,
        onTap: null,
      );
    }
    if (_isSplitting) {
      return _ActionBtn(
        icon: Icons.sync_rounded,
        label: 'Saving chunk...',
        color: _green.withValues(alpha: 0.7),
        onTap: null,
      );
    }
    return _ActionBtn(
      icon: Icons.hourglass_bottom_rounded,
      label: 'Saving...',
      color: Colors.grey.shade400,
      onTap: null,
    );
  }
}

// ── Widgets ───────────────────────────────────────────────────────────────────
class _CtrlTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;
  final bool fullWidth;

  const _CtrlTile({
    required this.icon, required this.label,
    this.onTap, this.active = false,
    this.activeColor = Colors.black87, this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = active ? activeColor : const Color(0xFF444444);
    final bg = active ? activeColor.withValues(alpha: 0.08) : Colors.white;
    final bd = active ? activeColor.withValues(alpha: 0.5) : const Color(0xFFE0E0E0);
    return GestureDetector(
      onTap: onTap,
      child: Opacity(opacity: onTap == null ? 0.35 : 1.0,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: bd, width: 1.2)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: fg, size: 18),
            const SizedBox(width: 7),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, fontSize: 12,
                    fontWeight: FontWeight.w600))),
          ]))));
  }
}

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _ActionBtn({required this.icon, required this.label,
      required this.color, this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Opacity(opacity: onTap == null ? 0.55 : 1.0,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(color: color,
            borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white,
                  fontSize: 13, fontWeight: FontWeight.w700))),
        ]))));
}