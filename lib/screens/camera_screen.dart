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
  bool _autoDetect = false;

  final _pose = PoseDetector(options: PoseDetectorOptions());
  Timer? _ticker;

  static const _green = Color(0xFF00C853);
  static const _red   = Colors.redAccent;

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
    );
    await _ctrl!.initialize();
    if (!mounted) return;
    setState(() => _state = _S.detecting);
  }

  // ── ML Kit stream ─────────────────────────────────────────────────────────

  void _startStream() {
    if (_state != _S.detecting || _ctrl == null) return;
    try { _ctrl!.startImageStream(_onFrame); } catch (_) {}
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

  // ── Countdown ─────────────────────────────────────────────────────────────

  Future<void> _doCountdown() async {
    if (!mounted) return;
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
    setState(() => _autoDetect = false);
    if (mounted) _doCountdown();
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
      if (mounted) { setState(() { _state = _S.detecting; _countdown = 0; }); }
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
        setState(() { _state = _S.detecting; _autoDetect = false; });
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    } catch (e) {
      print('=== Camera: stopRecording error: $e');
      if (mounted) setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
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
        body: Center(child: CircularProgressIndicator(color: _green)));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      // No AppBar — full immersive camera view
      body: Stack(children: [

        // ── Full-screen camera preview ─────────────────────────────────────
        Positioned.fill(child: CameraPreview(_ctrl!)),

        // Countdown big number
        if (_isCounting && _countdown > 0)
          Center(
            child: Container(
            width: 120, height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withOpacity(0.6),
              border: Border.all(color: _green, width: 2),
            ),
            child: Center(
              child: Text('$_countdown',
                style: const TextStyle(
                  color: Colors.white, fontSize: 72,
                    fontWeight: FontWeight.bold))),
          )),

        // Stopping overlay
        if (_isStopping)
          Container(
            color: Colors.black54,
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: const [
                CircularProgressIndicator(color: _green, strokeWidth: 2.5),
              SizedBox(height: 12),
              Text('Saving...', style: TextStyle(color: Colors.white70, fontSize: 14)),
            ]),
          ),
        ),

        // Recording timer — top left
        if (_isRecording)
          Positioned(top: 16, left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: _red.withOpacity(0.9),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
                const SizedBox(width: 5),
                Text(_fmt(_elapsed), 
                  style: const TextStyle(color: Colors.white, fontSize: 17, 
                    fontWeight: FontWeight.bold, letterSpacing: 1.1)),
              ]),
            )),

        // Auto-detect status badge (top-left when detecting)
        if (_isDetecting)
          Positioned(top: 16, left: 20,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _autoDetect
                    ? _green.withOpacity(0.15)
                    : Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _autoDetect ? _green : Colors.white24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_autoDetect
                    ? Icons.back_hand_rounded
                    : Icons.back_hand_outlined,
                    color: _autoDetect ? _green : Colors.white70, size: 14),
                const SizedBox(width: 5),
                Text(_autoDetect ? 'Hand detect ON' : 'Hand detect OFF',
                    style: TextStyle(
                        color: _autoDetect ? _green : Colors.white70,
                        fontSize: 11, fontWeight: FontWeight.w500)),
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
                colors: [Colors.black.withOpacity(0.92), Colors.transparent],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [

                // Left: Exit
                _BarBtn(icon: Icons.arrow_back_ios_new_rounded,
                    label: 'Exit',
                    onTap: () => Navigator.pop(context),
                  ),

                // Centre group
                Row(mainAxisSize: MainAxisSize.min, children: [

                  // Flash toggle
                  _BarBtn(
                    icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                    label: 'Flash',
                    active: _torchOn,
                    activeColor: const Color(0xFFFFD700),
                    onTap: _toggleTorch,
                  ),
                  const SizedBox(width: 20),

                  // Primary: Start / Stop
                  if (_isDetecting)
                    _BigBtn(
                      icon: Icons.play_arrow_rounded,
                      label: 'Start', 
                      color: _green, 
                      onTap: _manualStart,
                    ),
                  if (_isRecording)
                    _BigBtn(
                      icon: Icons.stop_rounded,
                      label: 'Stop', 
                      color: _red, 
                      onTap: _stopRecording,
                    ),
                  if (_isCounting)
                    _BigBtn(
                      icon: Icons.hourglass_top_rounded,
                        label: 'Wait...', 
                        color: Colors.white30, 
                        onTap: null,
                      ),
                  if (_isStopping)
                    _BigBtn(
                      icon: Icons.hourglass_top_rounded,
                        label: 'Saving', 
                        color: Colors.white30, 
                        onTap: null,
                      ),

                  const SizedBox(width: 20),

                  // Auto-detect toggle
                  _BarBtn(
                    icon: _autoDetect
                        ? Icons.back_hand_rounded
                        : Icons.back_hand_outlined,
                    label: 'Auto',
                    active: _autoDetect,
                    activeColor: _green,
                    onTap: (!_isRecording && !_isCounting)
                        ? _toggleAutoDetect : null,
                  ),
                ]),

                // Right: spacer mirror for visual balance
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
              color: active
                  ? activeColor.withOpacity(0.15)
                  : Colors.white.withOpacity(0.1),
              border: Border.all(color: color.withOpacity(0.6), width: 1.2),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(color: color.withOpacity(0.8),
              fontSize: 10, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}

// ── Large primary action button ────────────────────────────────────────────────

class _BigBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _BigBtn({
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
            width: 66, height: 66,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withOpacity(0.15),
              border: Border.all(color: color, width: 2.5),
            ),
            child: Icon(icon, color: color, size: 32),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(color: color,
              fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}