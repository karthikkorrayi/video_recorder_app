import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'review_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _isRecording = false;
  bool _torchOn = false;
  bool _handsDetected = false;
  int _countdown = 0;
  Duration _recordingDuration = Duration.zero;
  DateTime? _recordingStart;
  bool _cameraReady = false;

  // Hand detection state machine
  // idle → detecting → countdown → recording → idle
  bool _streamingActive = false;
  bool _processingFrame = false;
  bool _countdownRunning = false; // guard so countdown can't fire twice

  // 4-second instruction overlay
  bool _showInstruction = true;

  final _poseDetector = PoseDetector(options: PoseDetectorOptions());

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
    _controller = CameraController(
      cameras[0],
      ResolutionPreset.high,
      enableAudio: false,
    );
    await _controller!.initialize();
    if (!mounted) return;
    setState(() => _cameraReady = true);
    // Show instruction overlay for 4 seconds, then begin hand detection
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showInstruction = false);
    });
    Future.delayed(const Duration(seconds: 4), _beginHandDetection);
  }

  /// Starts the image stream for hand detection.
  /// Safe to call multiple times — guards against double-start.
  void _beginHandDetection() {
    if (!mounted || !_cameraReady) return;
    if (_isRecording || _countdownRunning) return;
    if (_streamingActive) return; // already running

    setState(() {
      _handsDetected = false;
      _countdown = 0;
    });

    _streamingActive = true;
    _controller!.startImageStream((image) async {
      if (_processingFrame || _isRecording || _countdownRunning) return;
      _processingFrame = true;
      try {
        final inputImage = _convertCameraImage(image);
        if (inputImage == null) return;
        final poses = await _poseDetector.processImage(inputImage);

        bool bothHands = false;
        if (poses.isNotEmpty) {
          final pose = poses.first;
          final lw = pose.landmarks[PoseLandmarkType.leftWrist];
          final rw = pose.landmarks[PoseLandmarkType.rightWrist];
          if (lw != null && rw != null) {
            bothHands = lw.likelihood > 0.55 && rw.likelihood > 0.55;
          }
        }

        if (mounted && !_countdownRunning && !_isRecording) {
          if (bothHands && !_handsDetected) {
            setState(() => _handsDetected = true);
            _startCountdown();
          } else if (!bothHands && _handsDetected) {
            setState(() => _handsDetected = false);
          }
        }
      } finally {
        _processingFrame = false;
      }
    });
  }

  /// Stops image stream cleanly. Safe to call even if not streaming.
  Future<void> _stopStream() async {
    if (!_streamingActive) return;
    _streamingActive = false;
    try {
      await _controller?.stopImageStream();
    } catch (_) {}
  }

  InputImage? _convertCameraImage(CameraImage image) {
    try {
      final buf = WriteBuffer();
      for (final plane in image.planes) buf.putUint8List(plane.bytes);
      return InputImage.fromBytes(
        bytes: buf.done().buffer.asUint8List(),
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _startCountdown() async {
    if (_countdownRunning || _isRecording) return;
    _countdownRunning = true;
    await _stopStream(); // stop ML frame processing

    for (int i = 3; i >= 1; i--) {
      if (!mounted) return;
      setState(() => _countdown = i);
      await Future.delayed(const Duration(seconds: 1));
    }
    if (!mounted) return;
    setState(() => _countdown = 0);
    _countdownRunning = false;
    await _startRecording();
  }

  /// Manual start — bypasses hand detection, goes straight to recording.
  Future<void> _manualStart() async {
    if (_isRecording || _countdownRunning) return;
    await _stopStream();
    await _startRecording();
  }

  Future<void> _startRecording() async {
    if (_isRecording) return;
    await _controller!.startVideoRecording();
    _recordingStart = DateTime.now();
    if (mounted) setState(() => _isRecording = true);
    _tickTimer();
  }

  void _tickTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted || !_isRecording) return;
      setState(() => _recordingDuration = DateTime.now().difference(_recordingStart!));
      _tickTimer();
    });
  }

  Future<void> _stopAndReview() async {
    if (!_isRecording) return;
    final file = await _controller!.stopVideoRecording();
    if (!mounted) return;

    setState(() {
      _isRecording = false;
      _recordingDuration = Duration.zero;
      _recordingStart = null;
    });

    // Navigate to review screen
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => ReviewScreen(videoPath: file.path)),
    );

    // IMPORTANT: restart hand detection after returning, whether recapture or back
    if (mounted) {
      setState(() {
        _handsDetected = false;
        _countdown = 0;
        _showInstruction = true;
      });
      // Brief instruction re-show then restart detection
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _showInstruction = false);
      });
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _beginHandDetection();
      });
    }
  }

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    await _controller?.setFlashMode(_torchOn ? FlashMode.torch : FlashMode.off);
    if (mounted) setState(() {});
  }

  String _fmtDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    // Always restore portrait before leaving camera
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WakelockPlus.disable();
    _stopStream();
    _controller?.dispose();
    _poseDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // Full-screen camera preview
        SizedBox.expand(child: CameraPreview(_controller!)),

        // ── Instruction overlay (4 sec on enter, 2 sec on recapture) ──
        if (_showInstruction && !_isRecording)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.75),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white24),
              ),
              child: const Text(
                'Show both hands to auto-start\nor tap  ▶  to start manually',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 15,
                    fontWeight: FontWeight.w500, height: 1.5),
              ),
            ),
          ),

        // ── Countdown ──
        if (_countdown > 0)
          Center(
            child: Text('$_countdown',
                style: const TextStyle(color: Colors.white, fontSize: 120,
                    fontWeight: FontWeight.bold,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 20)])),
          ),

        // ── Recording timer pill ──
        if (_isRecording)
          Positioned(
            top: 16, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.85),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.fiber_manual_record, color: Colors.white, size: 11),
                const SizedBox(width: 6),
                Text(_fmtDuration(_recordingDuration),
                    style: const TextStyle(color: Colors.white, fontSize: 18,
                        fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              ]),
            ),
          ),

        // ── Hand detection status (when not recording) ──
        if (!_isRecording && _countdown == 0 && !_showInstruction)
          Positioned(
            top: 16, left: 16,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: _handsDetected
                    ? Colors.green.withOpacity(0.85)
                    : Colors.black.withOpacity(0.6),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                    color: _handsDetected ? Colors.greenAccent : Colors.white24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_handsDetected ? Icons.back_hand : Icons.back_hand_outlined,
                    color: Colors.white, size: 16),
                const SizedBox(width: 6),
                Text(
                  _handsDetected ? 'Hands detected — starting...' : 'Show both hands to record',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ]),
            ),
          ),

        // ── Right-side control panel ──
        Positioned(
          right: 12, top: 0, bottom: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Home
                _Btn(icon: Icons.home_rounded, label: 'Home',
                    onTap: () => Navigator.pop(context)),
                const SizedBox(height: 8),
                // Flash
                _Btn(icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                    label: 'Flash', active: _torchOn, activeColor: Colors.yellow,
                    onTap: _toggleTorch),
                const SizedBox(height: 8),
                // Manual start (only when not recording / countdown)
                if (!_isRecording && _countdown == 0)
                  _Btn(
                    icon: Icons.play_arrow_rounded,
                    label: 'Start',
                    active: false,
                    activeColor: Colors.greenAccent,
                    size: 56,
                    onTap: _manualStart,
                  ),
                // Stop (only when recording)
                if (_isRecording)
                  _Btn(
                    icon: Icons.stop_rounded,
                    label: 'Stop',
                    active: true,
                    activeColor: Colors.redAccent,
                    size: 56,
                    onTap: _stopAndReview,
                  ),
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
    required this.icon,
    required this.label,
    this.onTap,
    this.active = false,
    this.activeColor = Colors.white,
    this.size = 48,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        Container(
          width: size, height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? activeColor.withOpacity(0.2) : Colors.white.withOpacity(0.15),
            border: Border.all(color: active ? activeColor : Colors.white54, width: 1.5),
          ),
          child: Icon(icon, color: active ? activeColor : Colors.white, size: size * 0.45),
        ),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10)),
      ]),
    );
  }
}