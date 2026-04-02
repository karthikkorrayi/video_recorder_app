import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'review_screen.dart';

enum _S { init, detecting, countdown, recording, stopping }

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
  DateTime? _recStart;
  bool _processingFrame = false;
  bool _showHint = true;

  final _pose = PoseDetector(options: PoseDetectorOptions());
  Timer? _ticker;

  static const _orange = Color(0xFFE8620A);

  bool get _isRecording => _state == _S.recording;
  bool get _isCounting  => _state == _S.countdown;
  bool get _isStopping  => _state == _S.stopping;
  bool get _isDetecting => _state == _S.detecting;

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
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cams = await availableCameras();
    if (!mounted) return;
    _ctrl = CameraController(
      cams[0],
      ResolutionPreset.high,
      enableAudio: false,           // no audio
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _ctrl!.initialize();
    if (!mounted) return;
    setState(() => _state = _S.detecting);
    _showHintBriefly();
    _startStream();
  }

  void _showHintBriefly() {
    setState(() => _showHint = true);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  // ── ML Kit stream ─────────────────────────────────────────────────────────

  void _startStream() {
    if (_state != _S.detecting) return;
    try { _ctrl?.startImageStream(_onFrame); } catch (_) {}
  }

  Future<void> _stopStream() async {
    try {
      if (_ctrl?.value.isStreamingImages == true) {
        await _ctrl!.stopImageStream();
      }
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
          rotation: InputImageRotation.rotation0deg,
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
        if (lw != null && rw != null) {
          both = lw.likelihood > 0.55 && rw.likelihood > 0.55;
        }
      }
      if (both) {
        await _stopStream();
        if (mounted && _state == _S.detecting) _runCountdown();
      }
    } finally {
      _processingFrame = false;
    }
  }

  // ── Countdown ─────────────────────────────────────────────────────────────

  Future<void> _runCountdown() async {
    if (!mounted || _state != _S.detecting) return;
    setState(() { _state = _S.countdown; _countdown = 3; });
    for (int i = 2; i >= 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted || _state != _S.countdown) return;
      setState(() => _countdown = i);
    }
    await Future.delayed(const Duration(milliseconds: 150));
    if (!mounted || _state != _S.countdown) return;
    await _startRecording();
  }

  Future<void> _manualStart() async {
    if (_state != _S.detecting) return;
    await _stopStream();
    if (mounted) _runCountdown();
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    try {
      await _ctrl!.startVideoRecording();
      _recStart = DateTime.now();
      if (!mounted) return;
      setState(() { _state = _S.recording; _elapsed = Duration.zero; _countdown = 0; });
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted || !_isRecording) { _ticker?.cancel(); return; }
        setState(() => _elapsed = DateTime.now().difference(_recStart!));
      });
    } catch (e) {
      print('=== Camera: startRecording error: $e');
      if (mounted) {
        setState(() { _state = _S.detecting; _countdown = 0; });
        _startStream();
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    _ticker?.cancel();
    setState(() => _state = _S.stopping);
    try {
      final file = await _ctrl!.stopVideoRecording();
      if (!mounted) return;
      setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
      await Navigator.push(context,
        MaterialPageRoute(builder: (_) => ReviewScreen(videoPath: file.path)));
      if (mounted) {
        setState(() => _state = _S.detecting);
        _showHintBriefly();
        _startStream();
        // Re-enable immersive mode after returning from review screen
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    } catch (e) {
      print('=== Camera: stopRecording error: $e');
      if (mounted) {
        setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
        _startStream();
      }
    }
  }

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    try {
      await _ctrl?.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2,'0')}:${(d.inSeconds%60).toString().padLeft(2,'0')}';

  @override
  void dispose() {
    _ticker?.cancel();
    // Restore portrait + show system UI when leaving camera
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
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: _orange)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      // No AppBar — full immersive camera view
      body: Stack(children: [

        // ── Full-screen camera preview ─────────────────────────────────────
        Positioned.fill(child: CameraPreview(_ctrl!)),

        // ── Countdown big number ───────────────────────────────────────────
        if (_isCounting && _countdown > 0)
          Center(
            child: Container(
              width: 140, height: 140,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black.withOpacity(0.55),
              ),
              child: Center(
                child: Text('$_countdown',
                  style: const TextStyle(
                    color: Colors.white, fontSize: 86,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 12)],
                  )),
              ),
            ),
          ),

        // ── Stopping overlay ──────────────────────────────────────────────
        if (_isStopping)
          Container(
            color: Colors.black54,
            child: const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                SizedBox(height: 14),
                Text('Saving...', style: TextStyle(color: Colors.white70, fontSize: 14)),
              ]),
            ),
          ),

        // ── Instruction overlay (auto-hides in 4s) ────────────────────────
        if (_showHint && _isDetecting)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.back_hand_outlined, color: Colors.white60, size: 28),
                SizedBox(height: 8),
                Text('Show both hands to auto-start',
                  style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                SizedBox(height: 3),
                Text('or tap  ▶ Start  to begin manually',
                  style: TextStyle(color: Colors.white54, fontSize: 11)),
              ]),
            ),
          ),

        // ── Top-left: recording pill ──────────────────────────────────────
        if (_isRecording)
          Positioned(top: 16, left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.9),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
                const SizedBox(width: 5),
                Text(_fmt(_elapsed),
                  style: const TextStyle(color: Colors.white, fontSize: 17,
                    fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              ]),
            )),

        // ── Top-left: hand hint badge (when not recording) ────────────────
        if (_isDetecting && !_showHint)
          Positioned(top: 16, left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.2)),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.back_hand_outlined, color: Colors.white60, size: 14),
                SizedBox(width: 5),
                Text('Show hands', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
            )),

        // ══════════════════════════════════════════════════════════════════
        // ── BOTTOM CONTROL BAR (landscape-friendly, clear of nav bar) ────
        // ══════════════════════════════════════════════════════════════════
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: Container(
            // Gradient so controls are readable over any background
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black.withOpacity(0.88), Colors.transparent],
                stops: const [0, 1],
              ),
            ),
            padding: const EdgeInsets.only(top: 20, bottom: 18, left: 24, right: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [

                // ── Left group: Home ───────────────────────────────────────
                _BarBtn(
                  icon: Icons.arrow_back_ios_new_rounded,
                  label: 'Exit',
                  onTap: () => Navigator.pop(context),
                ),

                // ── Centre group: primary action ───────────────────────────
                Row(mainAxisSize: MainAxisSize.min, children: [

                  // Flash toggle
                  _BarBtn(
                    icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                    label: 'Flash',
                    active: _torchOn,
                    activeColor: const Color(0xFFFFD700),
                    onTap: _toggleTorch,
                  ),

                  const SizedBox(width: 28),

                  // Main record / stop button — large
                  if (_isDetecting)
                    _BigActionBtn(
                      icon: Icons.play_arrow_rounded,
                      label: 'Start',
                      color: _orange,
                      onTap: _manualStart,
                    ),
                  if (_isRecording)
                    _BigActionBtn(
                      icon: Icons.stop_rounded,
                      label: 'Stop',
                      color: Colors.redAccent,
                      onTap: _stopRecording,
                    ),
                  if (_isCounting)
                    _BigActionBtn(
                      icon: Icons.hourglass_top_rounded,
                      label: 'Wait...',
                      color: Colors.white30,
                      onTap: null,
                    ),
                  if (_isStopping)
                    _BigActionBtn(
                      icon: Icons.stop_circle_outlined,
                      label: 'Saving',
                      color: Colors.white30,
                      onTap: null,
                    ),

                  const SizedBox(width: 28),

                  // Spacer mirror so centre stays centred
                  const SizedBox(width: 52),
                ]),

                // ── Right: empty placeholder for visual balance ────────────
                const SizedBox(width: 52),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Small bar button (Exit, Flash) ────────────────────────────────────────────

class _BarBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;

  const _BarBtn({
    required this.icon, required this.label,
    this.onTap, this.active = false, this.activeColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? activeColor : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.3 : 1.0,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withOpacity(0.08),
              border: Border.all(color: color.withOpacity(0.5), width: 1.2),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color.withOpacity(0.7),
            fontSize: 10, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

// ── Large primary action button ────────────────────────────────────────────────

class _BigActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _BigActionBtn({
    required this.icon, required this.label,
    required this.color, this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1.0,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 68, height: 68,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.18),
              border: Border.all(color: color, width: 2.5),
            ),
            child: Icon(icon, color: color, size: 34),
          ),
          const SizedBox(height: 5),
          Text(label, style: TextStyle(color: color,
            fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
        ]),
      ),
    );
  }
}