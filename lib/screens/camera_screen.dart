import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'review_screen.dart';

/// Single source of truth for every camera screen state.
/// Replaces the 5 independent booleans that caused race conditions.
enum CamState {
  init,       // camera not ready
  detecting,  // ML Kit watching for hands
  countdown,  // 3-2-1 countdown in progress
  recording,  // MediaRecorder actively writing
  stopping,   // stopVideoRecording() called, awaiting file
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  CamState _state = CamState.init;

  bool _torchOn = false;
  int _countdown = 0;
  Duration _elapsed = Duration.zero;
  DateTime? _recordStart;
  bool _processingFrame = false;
  bool _showInstruction = true;

  final _poseDetector = PoseDetector(options: PoseDetectorOptions());
  Timer? _elapsedTimer;

  // ── Convenience getters ───────────────────────────────────────────────────
  bool get _isRecording  => _state == CamState.recording;
  bool get _isDetecting  => _state == CamState.detecting;
  bool get _isCounting   => _state == CamState.countdown;
  bool get _isStopping   => _state == CamState.stopping;
  bool get _canStop      => _isRecording;
  bool get _canManualStart => _isDetecting; // show ▶ only while detecting

  // ─────────────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WakelockPlus.enable();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (!mounted) return;

    _controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,   // no audio ever
      imageFormatGroup: ImageFormatGroup.nv21,
    );

    await _controller!.initialize();
    if (!mounted) return;

    setState(() => _state = CamState.detecting);
    _showInstructionBriefly();
    _beginHandDetection();
  }

  void _showInstructionBriefly() {
    setState(() => _showInstruction = true);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showInstruction = false);
    });
  }

  // ── Hand detection ────────────────────────────────────────────────────────

  void _beginHandDetection() {
    if (!mounted) return;
    if (_state != CamState.detecting) return;

    try {
      _controller!.startImageStream(_onFrame);
    } catch (e) {
      print('=== Camera: startImageStream error: $e');
    }
  }

  Future<void> _stopStream() async {
    try {
      if (_controller?.value.isStreamingImages == true) {
        await _controller!.stopImageStream();
      }
    } catch (_) {}
  }

  Future<void> _onFrame(CameraImage image) async {
    // Only process frames while in detecting state
    if (_state != CamState.detecting) return;
    if (_processingFrame) return;
    _processingFrame = true;

    try {
      final input = _convertFrame(image);
      if (input == null) return;

      final poses = await _poseDetector.processImage(input);
      if (!mounted || _state != CamState.detecting) return;

      bool both = false;
      if (poses.isNotEmpty) {
        final lw = poses.first.landmarks[PoseLandmarkType.leftWrist];
        final rw = poses.first.landmarks[PoseLandmarkType.rightWrist];
        if (lw != null && rw != null) {
          both = lw.likelihood > 0.55 && rw.likelihood > 0.55;
        }
      }

      if (both) {
        // Hands detected — begin countdown
        await _stopStream();
        if (_state == CamState.detecting && mounted) {
          _triggerCountdown();
        }
      }
    } catch (e) {
      print('=== Camera: frame processing error: $e');
    } finally {
      _processingFrame = false;
    }
  }

  InputImage? _convertFrame(CameraImage image) {
    try {
      final buf = WriteBuffer();
      for (final p in image.planes) buf.putUint8List(p.bytes);
      return InputImage.fromBytes(
        bytes: buf.done().buffer.asUint8List(),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (_) { return null; }
  }

  // ── Countdown ─────────────────────────────────────────────────────────────

  Future<void> _triggerCountdown() async {
    if (!mounted) return;
    if (_state != CamState.detecting) return; // guard re-entry

    setState(() { _state = CamState.countdown; _countdown = 3; });

    for (int i = 2; i >= 0; i--) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      if (_state != CamState.countdown) return; // aborted
      setState(() => _countdown = i);
    }

    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted || _state != CamState.countdown) return;
    await _startRecording();
  }

  // ── Manual start ──────────────────────────────────────────────────────────

  Future<void> _manualStart() async {
    if (_state != CamState.detecting) return;
    await _stopStream();
    if (mounted && _state == CamState.detecting) {
      setState(() => _state = CamState.countdown);
      await _startRecording();
    }
  }

  // ── Recording ─────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    if (!mounted) return;
    try {
      await _controller!.startVideoRecording();
      _recordStart = DateTime.now();
      if (mounted) {
        setState(() {
          _state = CamState.recording;
          _elapsed = Duration.zero;
          _countdown = 0;
        });
        _startElapsedTimer();
      }
    } catch (e) {
      print('=== Camera: startVideoRecording error: $e');
      if (mounted) {
        setState(() { _state = CamState.detecting; _countdown = 0; });
        _beginHandDetection();
      }
    }
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || !_isRecording) {
        _elapsedTimer?.cancel();
        return;
      }
      setState(() => _elapsed = DateTime.now().difference(_recordStart!));
    });
  }

  Future<void> _stopRecording() async {
    if (!_canStop) return;

    setState(() => _state = CamState.stopping);
    _elapsedTimer?.cancel();

    try {
      final file = await _controller!.stopVideoRecording();
      if (!mounted) return;

      setState(() {
        _state = CamState.detecting;
        _elapsed = Duration.zero;
        _recordStart = null;
      });

      // Go to review screen
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => ReviewScreen(videoPath: file.path)),
      );

      // After returning: always restart hand detection
      if (mounted) {
        setState(() => _state = CamState.detecting);
        _showInstructionBriefly();
        _beginHandDetection();
      }
    } catch (e) {
      print('=== Camera: stopVideoRecording error: $e');
      if (mounted) {
        setState(() { _state = CamState.detecting; _elapsed = Duration.zero; });
        _beginHandDetection();
      }
    }
  }

  // ── Torch ─────────────────────────────────────────────────────────────────

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    try {
      await _controller?.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
    _stopStream();
    _controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_state == CamState.init || _controller == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color(0xFFE8620A))),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        SizedBox.expand(child: CameraPreview(_controller!)),

        // ── Countdown ────────────────────────────────────────────────────
        if (_isCounting && _countdown > 0)
          Center(child: Text('$_countdown',
              style: const TextStyle(color: Colors.white, fontSize: 120,
                  fontWeight: FontWeight.bold,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 20)]))),

        // ── Stopping spinner ─────────────────────────────────────────────
        if (_isStopping)
          Container(color: Colors.black45,
            child: const Center(child: CircularProgressIndicator(color: Colors.white))),

        // ── Instruction overlay ───────────────────────────────────────────
        if (_showInstruction && _isDetecting)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.back_hand_outlined, color: Colors.white70, size: 34),
                SizedBox(height: 10),
                Text('Show both hands to auto-start',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
                SizedBox(height: 4),
                Text('or tap  ▶  to start manually',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ]),
            ),
          ),

        // ── Recording timer pill ──────────────────────────────────────────
        if (_isRecording)
          Positioned(top: 16, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.85),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.fiber_manual_record, color: Colors.white, size: 11),
                const SizedBox(width: 6),
                Text(_fmt(_elapsed),
                    style: const TextStyle(color: Colors.white, fontSize: 18,
                        fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              ]),
            ),
          ),

        // ── Hand status badge (detecting, no instruction) ─────────────────
        if (_isDetecting && !_showInstruction)
          Positioned(top: 16, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white24),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.back_hand_outlined, color: Colors.white, size: 16),
                SizedBox(width: 6),
                Text('Show both hands to record',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
              ]),
            ),
          ),

        // ── Right-side control panel ──────────────────────────────────────
        Positioned(right: 12, top: 0, bottom: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                _Btn(icon: Icons.home_rounded, label: 'Home',
                    onTap: () => Navigator.pop(context)),
                const SizedBox(height: 8),
                _Btn(icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                    label: 'Flash', active: _torchOn, activeColor: Colors.yellow,
                    onTap: _toggleTorch),
                const SizedBox(height: 8),
                // Show ▶ Start when detecting, ■ Stop when recording
                if (_canManualStart)
                  _Btn(icon: Icons.play_arrow_rounded, label: 'Start',
                      activeColor: const Color(0xFFE8620A), size: 56,
                      onTap: _manualStart),
                if (_canStop)
                  _Btn(icon: Icons.stop_rounded, label: 'Stop',
                      active: true, activeColor: Colors.redAccent, size: 56,
                      onTap: _stopRecording),
                if (_isCounting || _isStopping)
                  _Btn(icon: Icons.hourglass_top_rounded, label: '...',
                      active: false, size: 56, onTap: null),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;
  final double size;

  const _Btn({
    required this.icon, required this.label,
    this.onTap, this.active = false,
    this.activeColor = Colors.white, this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = active ? activeColor : Colors.white;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.35,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: size, height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.12),
              border: Border.all(color: color.withOpacity(0.7), width: 1.5),
            ),
            child: Icon(icon, color: color, size: size * 0.44),
          ),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(color: color.withOpacity(0.8), fontSize: 10)),
        ]),
      ),
    );
  }
}