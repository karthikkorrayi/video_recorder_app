import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../services/beep_service.dart';
import '../services/chunk_upload_queue.dart';

enum _S { init, detecting, countdown, recording, stopping, saved }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _ctrl;
  _S   _state     = _S.init;
  bool _torchOn   = false;
  int  _countdown = 0;
  bool _processingFrame = false;
  bool _autoDetect      = false;

  // ── Timing constants ──────────────────────────────────────────────────────
  // CHUNK   = 2 min — silent background split + upload, user never aware
  // SESSION = 20 min — user-visible boundary with alert beeps + auto-restart
  static const int _chunkSecs   =  2 * 60;
  static const int _sessionSecs = 20 * 60;
  static const int _warnSecs    = 10;       // beep from 19:50 → 20:00

  // ── Session state ─────────────────────────────────────────────────────────
  String?   _sessionId;
  DateTime? _sessionStart;
  DateTime? _chunkStart;
  int       _partNumber        = 0;
  int       _displaySecs       = 0;
  bool      _warnFired         = false;

  // Q2: track current session part count for "0/N uploading" reset
  int       _sessionPartCount  = 0;

  Timer? _ticker;
  Timer? _alertTimer;

  final _queue = ChunkUploadQueue();
  final _beep  = BeepService();
  final _pose  = PoseDetector(options: PoseDetectorOptions());
  InputImageRotation _mlRotation = InputImageRotation.rotation0deg;

  String get _userId =>
      FirebaseAuth.instance.currentUser?.uid ?? 'unknown';

  // ── Elapsed helpers ───────────────────────────────────────────────────────
  int get _sessionElapsedSecs => _sessionStart == null ? 0
      : DateTime.now().difference(_sessionStart!).inSeconds.clamp(0, _sessionSecs);

  int get _chunkElapsedSecs => _chunkStart == null ? 0
      : DateTime.now().difference(_chunkStart!).inSeconds.clamp(0, _chunkSecs);

  double get _sessionProgress => (_sessionElapsedSecs / _sessionSecs).clamp(0.0, 1.0);
  bool   get _isWarning => _isRecording && _sessionElapsedSecs >= _sessionSecs - _warnSecs;

  // ── State helpers ─────────────────────────────────────────────────────────
  bool get _isRecording => _state == _S.recording;
  bool get _isCounting  => _state == _S.countdown;
  bool get _isDetecting => _state == _S.detecting;
  bool get _isSaved     => _state == _S.saved;

  // ── Colors ────────────────────────────────────────────────────────────────
  static const _green   = Color(0xFF00C853);
  static const _red     = Color(0xFFE53935);
  static const _white   = Color(0xFFFFFFFF);
  static const _surface = Color(0xFFF5F5F5);
  static const _text    = Color(0xFF1A1A1A);
  static const _sub     = Color(0xFF888888);
  static const _border  = Color(0xFFE8E8E8);

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _beep.init();
    _queue.startNetworkMonitor();
    _initCamera();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused && _isRecording) {
      _saveAndStop(navigateHome: false);
    } else if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _alertTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();
    _stopStream();
    _ctrl?.dispose();
    _pose.close();
    super.dispose();
  }

  // ── Camera ────────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (!mounted) return;
    _ctrl = CameraController(cams[0], ResolutionPreset.veryHigh,
        enableAudio: false, imageFormatGroup: ImageFormatGroup.nv21);
    await _ctrl!.initialize();
    try { await _ctrl!.lockCaptureOrientation(DeviceOrientation.landscapeLeft); } catch (_) {}
    _mlRotation = InputImageRotation.rotation0deg;
    try { await _ctrl!.setZoomLevel(await _ctrl!.getMinZoomLevel()); } catch (_) {}
    try { await _ctrl!.setExposureMode(ExposureMode.auto); } catch (_) {}
    if (!mounted) return;
    setState(() => _state = _S.detecting);
  }

  // ── Hand detection ────────────────────────────────────────────────────────
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
          rotation: _mlRotation, format: InputImageFormat.nv21,
          bytesPerRow: img.planes[0].bytesPerRow),
      );
      final poses = await _pose.processImage(input);
      if (!mounted || _state != _S.detecting) return;
      bool both = false;
      if (poses.isNotEmpty) {
        final lw = poses.first.landmarks[PoseLandmarkType.leftWrist];
        final rw = poses.first.landmarks[PoseLandmarkType.rightWrist];
        if (lw != null && rw != null) {
          both = lw.likelihood > 0.55 && rw.likelihood > 0.55;
        }
      }
      if (both) { await _stopStream(); if (mounted && _isDetecting) _doCountdown(); }
    } finally { _processingFrame = false; }
  }

  Future<void> _toggleAutoDetect() async {
    if (_isRecording || _isCounting) return;
    final next = !_autoDetect;
    setState(() => _autoDetect = next);
    if (next) _startStream(); else await _stopStream();
  }

  // ── Countdown ─────────────────────────────────────────────────────────────
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
    if (!_isDetecting && !_isSaved) return;
    await _stopStream();
    setState(() => _autoDetect = false);
    if (mounted) _doCountdown();
  }

  // ── Session start ─────────────────────────────────────────────────────────
  Future<void> _startSession() async {
    _sessionId        = _generateSessionId();
    _sessionStart     = DateTime.now();
    _partNumber       = 0;
    _sessionPartCount = 0;
    _warnFired        = false;

    // Q2: Clear completed so badge resets to "0/N uploading" for new session
    _queue.clearCompleted();

    debugPrint('=== Session started: $_sessionId');
    await _startChunk();
  }

  String _generateSessionId() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final rng = math.Random();
    return List.generate(6, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  // ── Start one 2-min chunk recording ───────────────────────────────────────
  Future<void> _startChunk() async {
    try {
      await _ctrl!.startVideoRecording();
      _partNumber++;
      _sessionPartCount++;
      _chunkStart = DateTime.now();

      if (!mounted) return;
      setState(() { _state = _S.recording; });

      _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }

        _displaySecs = _sessionStart == null ? 0
            : DateTime.now().difference(_sessionStart!).inSeconds;
        setState(() {});

        // ── 20-min session boundary: warn at 19:50 ──────────────────────
        if (!_warnFired && _sessionElapsedSecs >= _sessionSecs - _warnSecs) {
          _warnFired = true;
          _startSessionWarning(); // beep every 2s from 19:50
        }

        // ── 20-min session end: save last chunk, auto-restart session ───
        if (_sessionElapsedSecs >= _sessionSecs) {
          _ticker?.cancel();
          _alertTimer?.cancel();
          await _endSessionAndRestart();
          return;
        }

        // ── 2-min chunk boundary: SILENT split + upload ─────────────────
        // No beep, no UI change — completely transparent to user
        if (_chunkElapsedSecs >= _chunkSecs) {
          await _silentChunkSplit();
        }
      });
    } catch (e) {
      debugPrint('=== startChunk error: $e');
      if (mounted) setState(() => _state = _S.detecting);
    }
  }

  // ── Session warning (19:50–20:00): ascending beeps every 2s ──────────────
  void _startSessionWarning() {
    _alertTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || !_isRecording) { _alertTimer?.cancel(); return; }
      _beep.blockWarning();
    });
  }

  // ── SILENT 2-min chunk split ───────────────────────────────────────────────
  // stop → save to cache → start next → queue upload
  // No beep, no state change, no UI flash — user sees nothing
  Future<void> _silentChunkSplit() async {
    if (!_isRecording) return;

    // Cancel only the ticker (not alert timer — session warning continues)
    _ticker?.cancel();

    final capturedChunkStart = _chunkStart ?? DateTime.now();
    final capturedEnd        = DateTime.now();
    final capturedPart       = _partNumber;
    final capturedSessionId  = _sessionId!;
    final capturedStart0     = _sessionStart!;

    try {
      // Stop → start (0.5s gap — acceptable per Q1)
      final file = await _ctrl!.stopVideoRecording();
      await _ctrl!.startVideoRecording();
      _partNumber++;
      _sessionPartCount++;
      _chunkStart = DateTime.now();

      // Enqueue completed chunk for background upload
      final startSec = (capturedPart - 1) * _chunkSecs;
      final endSec   = capturedEnd.difference(capturedChunkStart).inSeconds + startSec;
      _queue.enqueue(PendingChunk(
        filePath:         file.path,
        sessionId:        capturedSessionId,
        userId:           _userId,
        partNumber:       capturedPart,
        sessionDate:      capturedStart0,
        sessionStartTime: capturedStart0,
        sessionEndTime:   capturedEnd,
        startSec:         startSec,
        endSec:           endSec,
      ));

      debugPrint('=== Silent split: part $capturedPart queued, part $_partNumber recording');

      // Restart ticker for new chunk — checks BOTH 2-min AND 20-min boundaries
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }
        _displaySecs = DateTime.now().difference(capturedStart0).inSeconds;
        setState(() {});

        if (!_warnFired && _sessionElapsedSecs >= _sessionSecs - _warnSecs) {
          _warnFired = true;
          _startSessionWarning();
        }
        if (_sessionElapsedSecs >= _sessionSecs) {
          _ticker?.cancel();
          _alertTimer?.cancel();
          await _endSessionAndRestart();
          return;
        }
        if (_chunkElapsedSecs >= _chunkSecs) {
          await _silentChunkSplit();
        }
      });

    } catch (e) {
      debugPrint('=== silentChunkSplit error: $e');
      // Try to restart recording if split fails
      try {
        await _ctrl!.startVideoRecording();
        _partNumber++;
        _chunkStart = DateTime.now();
      } catch (_) {
        if (mounted) setState(() => _state = _S.detecting);
      }
    }
  }

  // ── 20-min session end → save last chunk → immediately start new session ──
  Future<void> _endSessionAndRestart() async {
    if (!_isRecording) return;
    _ticker?.cancel();
    _alertTimer?.cancel();

    final capturedChunkStart = _chunkStart ?? DateTime.now();
    final capturedEnd        = DateTime.now();
    final capturedPart       = _partNumber;
    final capturedSessionId  = _sessionId!;
    final capturedStart0     = _sessionStart!;

    try {
      final file = await _ctrl!.stopVideoRecording();

      // Enqueue final chunk of this 20-min session
      final startSec = (capturedPart - 1) * _chunkSecs;
      final endSec   = capturedEnd.difference(capturedChunkStart).inSeconds + startSec;
      _queue.enqueue(PendingChunk(
        filePath:         file.path,
        sessionId:        capturedSessionId,
        userId:           _userId,
        partNumber:       capturedPart,
        sessionDate:      capturedStart0,
        sessionStartTime: capturedStart0,
        sessionEndTime:   capturedEnd,
        startSec:         startSec,
        endSec:           endSec,
      ));

      _beep.blockTransition(); // session-end chime

      // Start brand new session immediately (no countdown between sessions)
      _sessionId        = _generateSessionId();
      _sessionStart     = DateTime.now();
      _partNumber       = 0;
      _sessionPartCount = 0;
      _warnFired        = false;
      _queue.clearCompleted(); // Q2: reset badge for new session

      await _ctrl!.startVideoRecording();
      _partNumber       = 1;
      _sessionPartCount = 1;
      _chunkStart       = DateTime.now();

      debugPrint('=== New session after 20min: $_sessionId');

      // Restart ticker for new session
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }
        _displaySecs = DateTime.now().difference(_sessionStart!).inSeconds;
        setState(() {});
        if (!_warnFired && _sessionElapsedSecs >= _sessionSecs - _warnSecs) {
          _warnFired = true;
          _startSessionWarning();
        }
        if (_sessionElapsedSecs >= _sessionSecs) {
          _ticker?.cancel();
          _alertTimer?.cancel();
          await _endSessionAndRestart();
          return;
        }
        if (_chunkElapsedSecs >= _chunkSecs) {
          await _silentChunkSplit();
        }
      });

    } catch (e) {
      debugPrint('=== endSessionAndRestart error: $e');
      if (mounted) setState(() => _state = _S.detecting);
    }
  }

  // ── Manual stop ───────────────────────────────────────────────────────────
  Future<void> _saveAndStop({bool navigateHome = false}) async {
    if (!_isRecording) return;
    _ticker?.cancel();
    _alertTimer?.cancel();

    final capturedChunkStart = _chunkStart ?? DateTime.now();
    final capturedEnd        = DateTime.now();
    final capturedPart       = _partNumber;
    final capturedSessionId  = _sessionId!;
    final capturedStart0     = _sessionStart!;

    setState(() => _state = _S.stopping);
    try {
      final file = await _ctrl!.stopVideoRecording();

      final startSec = (capturedPart - 1) * _chunkSecs;
      final endSec   = capturedEnd.difference(capturedChunkStart).inSeconds + startSec;
      _queue.enqueue(PendingChunk(
        filePath:         file.path,
        sessionId:        capturedSessionId,
        userId:           _userId,
        partNumber:       capturedPart,
        sessionDate:      capturedStart0,
        sessionStartTime: capturedStart0,
        sessionEndTime:   capturedEnd,
        startSec:         startSec,
        endSec:           endSec,
      ));

      debugPrint('=== Session $_sessionId stopped: $capturedPart parts queued');

      if (!mounted) return;
      setState(() { _state = _S.saved; _displaySecs = 0; });

      if (navigateHome) {
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        Navigator.popUntil(context, (r) => r.isFirst);
      } else {
        await Future.delayed(const Duration(seconds: 3));
        if (mounted && _isSaved) setState(() => _state = _S.detecting);
      }
    } catch (e) {
      debugPrint('=== saveAndStop error: $e');
      if (mounted) setState(() { _state = _S.detecting; _displaySecs = 0; });
    }
  }

  Future<void> _goHome() async {
    if (_isRecording) {
      final confirm = await showDialog<bool>(
        context: context, barrierDismissible: false,
        builder: (_) => AlertDialog(
          title: const Text('Stop recording?'),
          content: const Text(
              'Saves current part and stops.\nUpload continues in background.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep Recording')),
            ElevatedButton(onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                    backgroundColor: _red, foregroundColor: Colors.white),
                child: const Text('Save & Exit')),
          ],
        ),
      );
      if (confirm != true) return;
      await _saveAndStop(navigateHome: true);
    } else {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    try { await _ctrl?.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off); } catch (_) {}
    if (mounted) setState(() {});
  }

  String _fmt(int secs) {
    final m = (secs ~/ 60).toString().padLeft(2, '0');
    final s = (secs % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Build ─────────────────────────────────────────────────────────────────
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

        // ── LEFT 58%: Camera preview ─────────────────────────────────────
        Expanded(flex: 58, child: Stack(children: [
          Positioned.fill(child: CameraPreview(_ctrl!)),

          // Top-left: format badge
          Positioned(top: 14, left: 14,
            child: _pill('Standard · 1.0x · 1080p · 30fps',
                Colors.black.withValues(alpha: 0.6), Colors.white)),

          // Top-left below: REC timer
          if (_isRecording)
            Positioned(top: 42, left: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.fiber_manual_record, color: Colors.white, size: 9),
                  const SizedBox(width: 4),
                  Text(_fmt(_displaySecs),
                      style: const TextStyle(color: Colors.white, fontSize: 14,
                          fontWeight: FontWeight.bold, letterSpacing: 1)),
                  const SizedBox(width: 6),
                  Text('Part $_partNumber',
                      style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ]))),

          // Top-right: upload status badge (current session only)
          Positioned(top: 14, right: 14,
            child: StreamBuilder<List<ChunkState>>(
              stream: _queue.stream,
              builder: (_, snap) {
                final chunks  = snap.data ?? _queue.current;
                final done    = chunks.where((c) => c.status == ChunkStatus.done).length;
                final total   = chunks.length;
                final active  = chunks.where((c) => c.status == ChunkStatus.uploading).firstOrNull;
                if (total == 0 && !_isRecording) return const SizedBox.shrink();
                // Q2: show "0/N uploading" at start of session
                final displayDone  = done;
                final displayTotal = total > 0 ? total : _sessionPartCount;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.cloud_upload,
                            color: active != null ? Colors.blue : _green, size: 13),
                        const SizedBox(width: 5),
                        Text('$displayDone/$displayTotal synced',
                            style: const TextStyle(color: Colors.white, fontSize: 11)),
                      ]),
                      if (active != null)
                        Text('${(active.progress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(color: Colors.blue, fontSize: 10)),
                    ]),
                );
              })),

          // Countdown overlay
          if (_isCounting && _countdown > 0)
            Center(child: Container(
              width: 110, height: 110,
              decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.65),
                  border: Border.all(
                      color: _countdown <= 2 ? _red : _green, width: 3)),
              child: Center(child: Text('$_countdown',
                  style: TextStyle(
                      color: _countdown <= 2 ? _red : Colors.white,
                      fontSize: 58, fontWeight: FontWeight.bold))))),

          // Saved overlay
          if (_isSaved)
            Center(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(16)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.cloud_upload, color: _green, size: 48),
                const SizedBox(height: 10),
                const Text('Session Saved!',
                    style: TextStyle(color: Colors.white, fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text('Upload continues in background',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
              ]))),

          // Warning banner (19:50 → 20:00)
          if (_isWarning)
            Positioned(bottom: 14, left: 14, right: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Text('Session ends in ${_sessionSecs - _sessionElapsedSecs}s',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ]))),
        ])),

        // ── RIGHT 42%: Control panel ──────────────────────────────────────
        Expanded(flex: 42, child: Container(
          color: _surface,
          child: Column(children: [

            // Header
            Container(
              color: _white,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Text('SESSION', style: TextStyle(fontSize: 9,
                      fontWeight: FontWeight.w800, color: _sub, letterSpacing: 1.4)),
                  const Spacer(),
                  if (_isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: _green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _green.withValues(alpha: 0.4))),
                      child: Text('Part $_partNumber',
                          style: const TextStyle(color: _green, fontSize: 10,
                              fontWeight: FontWeight.w700))),
                ]),
                const SizedBox(height: 4),

                // Session timer display
                Row(children: [
                  Flexible(child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _isRecording ? _fmt(_displaySecs) : '--:--',
                      style: TextStyle(fontSize: 34, fontWeight: FontWeight.bold,
                          color: _isWarning ? _red : _text, letterSpacing: 1.2)))),
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
                        const Text('REC', style: TextStyle(color: _red, fontSize: 10,
                            fontWeight: FontWeight.w800, letterSpacing: 1)),
                      ])),
                ]),

                // 20-min session progress bar
                if (_isRecording) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _sessionProgress, minHeight: 5,
                      backgroundColor: _border,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          _isWarning ? _red : _green))),
                  const SizedBox(height: 3),
                  Row(children: [
                    const Text('Session timer',
                        style: TextStyle(color: _sub, fontSize: 9)),
                    const Spacer(),
                    Text('${_sessionSecs - _sessionElapsedSecs}s left',
                        style: TextStyle(
                            color: _isWarning ? _red : _sub, fontSize: 9,
                            fontWeight: _isWarning ? FontWeight.w700 : FontWeight.normal)),
                  ]),
                ],

                if (_isCounting) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: (_countdown <= 2 ? _red : _green).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color:
                          (_countdown <= 2 ? _red : _green).withValues(alpha: 0.4))),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.volume_up_rounded, size: 12,
                          color: _countdown <= 2 ? _red : _green),
                      const SizedBox(width: 5),
                      Text('Starting in $_countdown...',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                              color: _countdown <= 2 ? _red : _green)),
                    ])),
                ],
              ]),
            ),

            const Divider(height: 1, color: _border),

            Expanded(child: Padding(
              padding: const EdgeInsets.all(10),
              child: Column(children: [

                // Q3: Fixed height buttons — removed info card to give full height
                SizedBox(height: 56, child: Row(children: [
                  Expanded(child: _CtrlTile(
                      icon: Icons.home_rounded, label: 'Home',
                      onTap: _goHome)),
                  const SizedBox(width: 8),
                  Expanded(child: _CtrlTile(
                      icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                      label: _torchOn ? 'Flash ON' : 'Flash',
                      active: _torchOn,
                      activeColor: const Color(0xFFFFB300),
                      onTap: _toggleTorch)),
                ])),
                const SizedBox(height: 8),

                SizedBox(height: 56, child: _CtrlTile(
                    icon: _autoDetect
                        ? Icons.back_hand_rounded : Icons.back_hand_outlined,
                    label: _autoDetect ? 'Hand Detect: ON' : 'Hand Detect: OFF',
                    active: _autoDetect,
                    activeColor: _green,
                    fullWidth: true,
                    onTap: (!_isRecording && !_isCounting) ? _toggleAutoDetect : null)),
                const SizedBox(height: 8),

                // Compact upload status (no info card — Q3)
                StreamBuilder<List<ChunkState>>(
                  stream: _queue.stream,
                  builder: (_, snap) {
                    final chunks   = snap.data ?? _queue.current;
                    if (chunks.isEmpty) return const SizedBox(height: 4);
                    final done     = chunks.where((c) => c.status == ChunkStatus.done).length;
                    final failed   = chunks.where((c) => c.status == ChunkStatus.failed).length;
                    final active   = chunks.where((c) => c.status == ChunkStatus.uploading).firstOrNull;
                    return Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: _white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: failed > 0 ? _red.withValues(alpha: 0.4) : _border)),
                      child: Row(children: [
                        Icon(failed > 0 ? Icons.cloud_off : Icons.cloud_upload,
                            color: failed > 0 ? _red : Colors.blue, size: 13),
                        const SizedBox(width: 6),
                        Expanded(child: Text(
                          active != null
                              ? 'Part ${active.chunk.partNumber}: ${(active.progress * 100).toStringAsFixed(0)}%'
                              : failed > 0 ? '$failed failed'
                              : '$done/${chunks.length} synced ✓',
                          style: TextStyle(fontSize: 11,
                              color: failed > 0 ? _red : _text,
                              fontWeight: FontWeight.w600))),
                        if (active != null)
                          SizedBox(width: 50, child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: LinearProgressIndicator(
                              value: active.progress, minHeight: 3,
                              backgroundColor: _border,
                              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue)))),
                      ]),
                    );
                  }),

                const Spacer(),
                _buildActionBtn(),
              ]),
            )),
          ]),
        )),
      ]),
    );
  }

  Widget _pill(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
    child: Text(text, style: TextStyle(color: fg, fontSize: 11,
        fontWeight: FontWeight.w500)));

  Widget _buildActionBtn() {
    if (_isDetecting || _isSaved) {
      return _ActionBtn(
        icon: Icons.play_arrow_rounded,
        label: _isSaved ? 'Record Again' : 'Start Recording',
        color: _green, onTap: _manualStart);
    }
    if (_isRecording) return _ActionBtn(
        icon: Icons.stop_rounded, label: 'Stop Recording',
        color: _red, onTap: _saveAndStop);
    if (_isCounting) return _ActionBtn(
        icon: Icons.hourglass_top_rounded,
        label: 'Starting in $_countdown...',
        color: Colors.grey.shade400, onTap: null);
    return _ActionBtn(
        icon: Icons.hourglass_bottom_rounded,
        label: 'Saving...', color: Colors.grey.shade400, onTap: null);
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────
class _CtrlTile extends StatelessWidget {
  final IconData icon; final String label;
  final VoidCallback? onTap; final bool active;
  final Color activeColor; final bool fullWidth;
  const _CtrlTile({required this.icon, required this.label,
      this.onTap, this.active = false,
      this.activeColor = Colors.black87, this.fullWidth = false});
  @override
  Widget build(BuildContext context) {
    final fg = active ? activeColor : const Color(0xFF444444);
    final bg = active ? activeColor.withValues(alpha: 0.08) : Colors.white;
    final bd = active ? activeColor.withValues(alpha: 0.5) : const Color(0xFFE0E0E0);
    return GestureDetector(
      onTap: onTap,
      child: Opacity(opacity: onTap == null ? 0.35 : 1.0,
        child: Container(
          width: double.infinity, height: double.infinity,
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
  final IconData icon; final String label;
  final Color color; final VoidCallback? onTap;
  const _ActionBtn({required this.icon, required this.label,
      required this.color, this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Opacity(opacity: onTap == null ? 0.55 : 1.0,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 14),
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