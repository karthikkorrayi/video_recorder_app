import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/video_processor.dart';
import '../services/beep_service.dart';

enum _S { init, detecting, countdown, recording, splitting, stopping }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _ctrl;
  _S _state = _S.init;
  bool _torchOn = false;
  int _countdown = 0;
  Duration _elapsed = Duration.zero;
  DateTime? _blockStart;
  int  _blockNumber = 0;
  bool _processingFrame = false;
  bool _autoDetect  = false;

  static const int _blockSecs = 20 * 60;
  static const int _warnSecs  = 10;

  Timer? _ticker;
  bool _warnFired = false;

  final _pose = PoseDetector(options: PoseDetectorOptions());
  final _beep = BeepService();

  // Rotation needed for ML Kit (not for preview — CameraPreview handles its own display)
  InputImageRotation _mlRotation = InputImageRotation.rotation90deg;

  static const _green   = Color(0xFF00C853);
  static const _red     = Color(0xFFE53935);
  static const _white   = Color(0xFFFFFFFF);
  static const _surface = Color(0xFFF5F5F5);
  static const _text    = Color(0xFF1A1A1A);
  static const _sub     = Color(0xFF888888);
  static const _border  = Color(0xFFE8E8E8);

  bool get _isRecording => _state == _S.recording;
  bool get _isCounting  => _state == _S.countdown;
  bool get _isSplitting => _state == _S.splitting;
  bool get _isDetecting => _state == _S.detecting;
  bool get _isWarning   => _isRecording && _elapsed.inSeconds >= _blockSecs - _warnSecs;

  @override
  void initState() {
    super.initState();

    // Force landscape
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Hide the Android navigation bar (immersive sticky mode)
    // This prevents the nav buttons from overlapping our UI
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    WakelockPlus.enable();
    _beep.init(); // pre-warm audio session
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (!mounted) return;
    final cam = cams[0];

    // ── Camera orientation — the correct approach ──────────────────────────
    //
    // WRONG: RotatedBox(quarterTurns: N, child: CameraPreview(...))
    //   CameraPreview internally applies a Transform for device orientation.
    //   Adding RotatedBox on top creates double-rotation → unpredictable results.
    //
    // CORRECT: lockCaptureOrientation(landscapeLeft)
    //   This tells the camera plugin to always produce landscape-oriented frames,
    //   regardless of how the user holds the device.
    //   CameraPreview then renders the frame correctly with no extra rotation needed.
    //
    // ML Kit rotation:
    //   When capture is locked to landscapeLeft and sensor is at 90° (typical back cam):
    //   The frame data is already rotated by the plugin, so ML Kit gets rotation0deg.
    //   For a sensor at 270°: still rotation0deg after lock.
    //   This is because lockCaptureOrientation compensates the sensor offset internally.

    _ctrl = CameraController(
      cam,
      ResolutionPreset.veryHigh, // 1080p
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _ctrl!.initialize();

    // Lock orientation BEFORE starting any stream or recording
    // This is the key fix — no RotatedBox needed
    try {
      await _ctrl!.lockCaptureOrientation(DeviceOrientation.landscapeLeft);
    } catch (e) {
      print('=== lockCaptureOrientation failed: $e');
      // Some devices don't support this — fall back gracefully
    }

    // After locking to landscape, ML Kit should use rotation0deg because
    // the plugin already compensates the sensor orientation in the locked frame
    _mlRotation = InputImageRotation.rotation0deg;

    try { await _ctrl!.setZoomLevel(await _ctrl!.getMinZoomLevel()); } catch (_) {}
    try { await _ctrl!.setExposureMode(ExposureMode.auto); } catch (_) {}

    if (!mounted) return;
    setState(() => _state = _S.detecting);
  }

  // ── ML Kit hand detection ─────────────────────────────────────────────────

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

  // ── Toggle auto-detect ────────────────────────────────────────────────────

  Future<void> _toggleAutoDetect() async {
    if (_isRecording || _isCounting) return;
    final next = !_autoDetect;
    setState(() => _autoDetect = next);
    if (next) {
      _startStream();
    } else {
      await _stopStream();
    }
  }

  // ── 5-second countdown with beeps ─────────────────────────────────────────

  Future<void> _doCountdown() async {
    if (!mounted) return;
    setState(() { _state = _S.countdown; _countdown = 5; });
    for (int i = 5; i >= 1; i--) {
      if (!mounted || _state != _S.countdown) return;
      setState(() => _countdown = i);

      // Play tick beep — do NOT await so it doesn't delay the countdown
      _beep.tick();
      await Future.delayed(const Duration(seconds: 1));
    }

    if (!mounted || _state != _S.countdown) return;

    // Final GO beep when recording actually starts
    setState(() => _countdown = 0);
    await _beep.go(); // await this one so it plays before camera starts
    await Future.delayed(const Duration(milliseconds: 100));

    if (!mounted || _state != _S.countdown) return;
    await _startRecording();
  }

  Future<void> _manualStart() async {
    if (_state != _S.detecting) return;
    await _stopStream();
    setState(() => _autoDetect = false);
    if (mounted) _doCountdown();
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    try {
      await _ctrl!.startVideoRecording();
      _blockStart = DateTime.now();
      _warnFired  = false;
      if (!mounted) return;
      setState(() { _state = _S.recording; _elapsed = Duration.zero; });

      _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }
        final secs = DateTime.now().difference(_blockStart!).inSeconds;
        setState(() => _elapsed = Duration(seconds: secs));
        if (!_warnFired && secs >= _blockSecs - _warnSecs) {
          _warnFired = true;
          _beep.blockWarning();
        }
        if (secs >= _blockSecs) { _ticker?.cancel(); await _autoSplitBlock(); }
      });
    } catch (e) {
      print('=== startRecording: $e');
      if (mounted) setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
    }
  }

  Future<void> _autoSplitBlock() async {
    if (!_isRecording) return;
    setState(() => _state = _S.splitting);
    try {
      final endTime = DateTime.now();
      final file    = await _ctrl!.stopVideoRecording();
      _blockNumber++;
      VideoProcessor().startBackgroundProcessing(
        rawVideoPath: file.path, sessionTime: _blockStart!, recordingEnd: endTime);
      await _beep.blockTransition();
      await Future.delayed(const Duration(milliseconds: 600));
      if (mounted) await _startRecording();
    } catch (e) {
      if (mounted) setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    _ticker?.cancel();
    setState(() => _state = _S.stopping);
    try {
      final endTime = DateTime.now();
      final file    = await _ctrl!.stopVideoRecording();
      _blockNumber++;
      VideoProcessor().startBackgroundProcessing(
        rawVideoPath: file.path,
        sessionTime: _blockStart ?? endTime.subtract(const Duration(minutes: 1)),
        recordingEnd: endTime);
      if (!mounted) return;
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      Navigator.popUntil(context, (r) => r.isFirst);
    } catch (e) {
      if (mounted) setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
    }
  }

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    try { await _ctrl?.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off); } catch (_) {}
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2,'0')}:${(d.inSeconds%60).toString().padLeft(2,'0')}';

  String get _remainingLabel {
    final r = _blockSecs - _elapsed.inSeconds;
    return r <= 0 ? '00:00' : _fmt(Duration(seconds: r));
  }

  double get _blockProgress => (_elapsed.inSeconds / _blockSecs).clamp(0.0, 1.0);

  @override
  void dispose() {
    _ticker?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();
    _stopStream();
    _ctrl?.dispose();
    _pose.close();
    _beep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _S.init || _ctrl == null) {
      return const Scaffold(backgroundColor: Color(0xFF0D0D0D),
          body: Center(child: CircularProgressIndicator(color: _green)));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(children: [

        // ── LEFT: Camera preview (no RotatedBox — lockCaptureOrientation handles it) ──
        Expanded(flex: 58, child: Stack(children: [
          Positioned.fill(child: CameraPreview(_ctrl!)),

          // Info badge top-left
          Positioned(top: 14, left: 14,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _pill('Standard · 1.0x · 1080p · 30fps',
                  Colors.black.withOpacity(0.6), Colors.white),
              const SizedBox(height: 6),
              if (_isRecording || _isSplitting)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                      color: _red.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(20)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.fiber_manual_record, color: Colors.white, size: 9),
                    const SizedBox(width: 4),
                    Text(_fmt(_elapsed), style: const TextStyle(color: Colors.white,
                        fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  ]),
                ),
            ])),

          // Countdown overlay
          if (_isCounting && _countdown > 0)
            Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 110, height: 110,
                decoration: BoxDecoration(shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.65),
                  border: Border.all(
                      color: _countdown <= 2 ? _red : _green, width: 3)),
                child: Center(child: Text('$_countdown',
                    style: TextStyle(
                        color: _countdown <= 2 ? _red : Colors.white,
                        fontSize: 58, fontWeight: FontWeight.bold))),
              ),
              const SizedBox(height: 10),
              _pill('Recording starts soon...',
                  Colors.black.withOpacity(0.6), Colors.white70),
            ])),

          // Splitting overlay
          if (_isSplitting)
            Container(color: Colors.black.withOpacity(0.45),
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: _green, strokeWidth: 2.5),
                const SizedBox(height: 12),
                _pill('Saving block & starting next...',
                    Colors.black.withOpacity(0.65), Colors.white),
              ]))),

          // Warning banner
          if (_isWarning && !_isSplitting)
            Positioned(bottom: 14, left: 14, right: 14,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(color: _red.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Text('Block ends in $_remainingLabel — get ready!',
                      style: const TextStyle(color: Colors.white,
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ]),
              )),
        ])),

        // ── RIGHT: Control panel ───────────────────────────────────────────
        Expanded(flex: 42, child: Container(
          color: _surface,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

            // ── HEADER: timer + block info ─────────────────────────────────
            Container(
              color: _white,
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Label row
                Row(children: [
                  const Text('RECORDING', style: TextStyle(fontSize: 10,
                      fontWeight: FontWeight.w800, color: _sub, letterSpacing: 1.5)),
                  const Spacer(),
                  if (_blockNumber > 0 || _isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                          color: _green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _green.withOpacity(0.4))),
                      child: Text('Block ${_blockNumber + 1}',
                          style: const TextStyle(color: _green, fontSize: 11,
                              fontWeight: FontWeight.w700)),
                    ),
                ]),
                const SizedBox(height: 8),

                // Large elapsed time + REC badge
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Text(
                    _isRecording || _isSplitting ? _fmt(_elapsed) : '--:--',
                    style: TextStyle(
                      fontSize: 38, fontWeight: FontWeight.bold,
                      color: _isWarning ? _red : _text,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (_isRecording)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: _red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: _red.withOpacity(0.4))),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(width: 7, height: 7,
                            decoration: const BoxDecoration(
                                color: _red, shape: BoxShape.circle)),
                        const SizedBox(width: 5),
                        const Text('REC', style: TextStyle(color: _red,
                            fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
                      ]),
                    ),
                ]),

                // Block progress bar
                if (_isRecording || _isSplitting) ...[
                  const SizedBox(height: 10),
                  ClipRRect(borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _blockProgress, minHeight: 6,
                      backgroundColor: _border,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          _isWarning ? _red : _green))),
                  const SizedBox(height: 5),
                  Row(children: [
                    Text('Block time', style: TextStyle(color: _sub, fontSize: 10)),
                    const Spacer(),
                    Text('$_remainingLabel left', style: TextStyle(
                      color: _isWarning ? _red : _sub, fontSize: 10,
                      fontWeight: _isWarning ? FontWeight.w700 : FontWeight.normal)),
                  ]),
                ],

                // Countdown status
                if (_isCounting) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: (_countdown <= 2 ? _red : _green).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: (_countdown <= 2 ? _red : _green).withOpacity(0.4)),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.volume_up_rounded, size: 13,
                          color: _countdown <= 2 ? _red : _green),
                      const SizedBox(width: 6),
                      Text('Starting in $_countdown...',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                              color: _countdown <= 2 ? _red : _green)),
                    ]),
                  ),
                ],
              ]),
            ),

            const Divider(height: 1, color: _border),

            // ── MIDDLE: control buttons ────────────────────────────────────
            Expanded(child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [

                // ── Home + Flash: fixed height row ─────────────────────────
                SizedBox(
                  height: 56, // explicit height so icons are not small
                  child: Row(children: [
                    Expanded(child: _CtrlTile(
                      icon: Icons.home_rounded,
                      label: 'Home',
                      onTap: () {
                        SystemChrome.setPreferredOrientations(
                            [DeviceOrientation.portraitUp]);
                        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                        Navigator.pop(context);
                      },
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: _CtrlTile(
                      icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                      label: _torchOn ? 'Flash ON' : 'Flash',
                      active: _torchOn,
                      activeColor: const Color(0xFFFFB300),
                      onTap: _toggleTorch,
                    )),
                  ]),
                ),
                const SizedBox(height: 10),

                // ── Hand detect: fixed height ──────────────────────────────
                SizedBox(
                  height: 56,
                  child: _CtrlTile(
                    icon: _autoDetect
                        ? Icons.back_hand_rounded
                        : Icons.back_hand_outlined,
                    label: _autoDetect ? 'Hand Detect: ON' : 'Hand Detect: OFF',
                    active: _autoDetect,
                    activeColor: _green,
                    fullWidth: true,
                    onTap: (!_isRecording && !_isCounting) ? _toggleAutoDetect : null,
                  ),
                ),
                const SizedBox(height: 12),

                // ── Info card ──────────────────────────────────────────────
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(color: _white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _border)),
                  child: Row(children: [
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('1080p · 30fps', style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w700, color: _text)),
                      const SizedBox(height: 2),
                      const Text('Standard 1.0x',
                          style: TextStyle(fontSize: 10, color: _sub)),
                    ]),
                    const Spacer(),
                    Container(width: 1, height: 28, color: _border),
                    const SizedBox(width: 14),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      const Text('Auto-split', style: TextStyle(fontSize: 12,
                          fontWeight: FontWeight.w700, color: _text)),
                      const SizedBox(height: 2),
                      const Text('Every 20 min',
                          style: TextStyle(fontSize: 10, color: _sub)),
                    ]),
                  ]),
                ),
              ]),
            )),

            // ── BOTTOM: action button ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: _buildActionBtn(),
            ),
          ]),
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
    if (_isDetecting) return _ActionBtn(icon: Icons.play_arrow_rounded,
        label: 'Start New Recording', color: _green, onTap: _manualStart);
    if (_isRecording) return _ActionBtn(icon: Icons.stop_rounded,
        label: 'Stop Recording', color: _red, onTap: _stopRecording);
    if (_isCounting) return _ActionBtn(icon: Icons.hourglass_top_rounded,
        label: 'Starting in $_countdown...', color: Colors.grey.shade400, onTap: null);
    if (_isSplitting) return _ActionBtn(icon: Icons.sync_rounded,
        label: 'Saving & starting next...', color: _green.withOpacity(0.7), onTap: null);
    return _ActionBtn(icon: Icons.hourglass_bottom_rounded,
        label: 'Saving...', color: Colors.grey.shade400, onTap: null);
  }
}

// ── Control tile — fills its parent's height explicitly ─────────────────────

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
    final bg = active ? activeColor.withOpacity(0.08) : Colors.white;
    final bd = active ? activeColor.withOpacity(0.5) : const Color(0xFFE0E0E0);

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.35 : 1.0,
        child: Container(
          width: double.infinity,
          // No explicit height — fills the SizedBox parent
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: bd, width: 1.2),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: fg, size: 20),   // larger icon
              const SizedBox(width: 8),
              Text(label, style: TextStyle(
                color: fg, fontSize: 13,         // slightly larger text
                fontWeight: FontWeight.w600,
              )),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Primary action button ─────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionBtn({required this.icon, required this.label,
      required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.55 : 1.0,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: Colors.white, size: 22),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
          ]),
        ),
      ),
    );
  }
}