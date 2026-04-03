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
  static const _red   = Color(0xFFE53935);
  static const _panel = Color(0xFFFFFFFF);
  static const _bg    = Color(0xFFF4F4F4);

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

    // Fix 1: Use 1080p resolution + lock to standard 1.0x zoom
    _ctrl = CameraController(
      cams[0],
      ResolutionPreset.veryHigh,  // 1080p on most devices
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _ctrl!.initialize();

    // Lock to standard 1.0x zoom (no digital zoom)
    try {
      final minZoom = await _ctrl!.getMinZoomLevel();
      await _ctrl!.setZoomLevel(minZoom); // 1.0x = minimum = optical
    } catch (_) {}

    // Lock exposure and focus for stability
    try {
      await _ctrl!.setExposureMode(ExposureMode.auto);
      await _ctrl!.setFocusMode(FocusMode.auto);
    } catch (_) {}

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
      final endTime = DateTime.now();
      if (!mounted) return;
      setState(() { _state = _S.detecting; _elapsed = Duration.zero; });
      await Navigator.push(context,
        MaterialPageRoute(builder: (_) => ReviewScreen(
          videoPath: file.path,
          recordingStart: _recStart ?? endTime.subtract(const Duration(minutes: 1)),
          recordingEnd: endTime,
        )));
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
      body: Row(children: [

        // ── LEFT: Camera preview (takes 60% of width) ──────────────────
        Expanded(
          flex: 60,
          child: Stack(children: [
            // Full camera preview
            Positioned.fill(child: CameraPreview(_ctrl!)),

            // Stopping overlay
            if (_isStopping)
              Container(color: Colors.black54,
                child: const Center(child: CircularProgressIndicator(color: _green))),

            // Countdown overlay
            if (_isCounting && _countdown > 0)
              Center(child: Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.65),
                  border: Border.all(color: _green, width: 2.5),
                ),
                child: Center(child: Text('$_countdown',
                    style: const TextStyle(color: Colors.white, fontSize: 56,
                        fontWeight: FontWeight.bold))),
              )),

            // Top-left: zoom label + resolution
            Positioned(top: 12, left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Standard · 1.0x · 1080p · 30fps',
                    style: TextStyle(color: Colors.white, fontSize: 10,
                        fontWeight: FontWeight.w500)),
              )),

            // Top-left: recording timer
            if (_isRecording)
              Positioned(top: 40, left: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _red.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.fiber_manual_record, color: Colors.white, size: 9),
                    const SizedBox(width: 4),
                    Text(_fmt(_elapsed), style: const TextStyle(color: Colors.white,
                        fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  ]),
                )),
          ]),
        ),

        // ── RIGHT: Controls panel (40% of width) ──────────────────────
        Expanded(
          flex: 40,
          child: Container(
            color: _bg,
            child: Column(children: [

              // ── Top section: stats ──────────────────────────────────
              Container(
                padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                decoration: BoxDecoration(
                  color: _panel,
                  border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                ),
                child: Row(children: [
                  // Total recorded
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Text('TOTAL', style: TextStyle(fontSize: 10,
                          fontWeight: FontWeight.w700, color: Color(0xFF888888),
                          letterSpacing: 1)),
                      const SizedBox(width: 4),
                      Icon(Icons.keyboard_arrow_down_rounded,
                          size: 14, color: Colors.grey.shade500),
                    ]),
                    const SizedBox(height: 4),
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(_isRecording
                          ? '${_elapsed.inSeconds}'
                          : '0',
                        style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A1A))),
                      const SizedBox(width: 2),
                      const Text('s', style: TextStyle(fontSize: 13, color: Color(0xFF888888))),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Container(width: 7, height: 7,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRecording ? _red : Colors.grey.shade400,
                        )),
                      const SizedBox(width: 5),
                      Text(_fmt(_elapsed),
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A1A))),
                    ]),
                  ])),

                  // Divider
                  Container(width: 1, height: 52, color: Colors.grey.shade200),
                  const SizedBox(width: 8),

                  // Right mini controls
                  Column(children: [
                    Row(children: [
                      _MiniBtn(icon: Icons.home_rounded, label: 'HOME',
                          onTap: () => Navigator.pop(context)),
                      const SizedBox(width: 6),
                      _MiniBtn(
                        icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                        label: 'FLASH',
                        active: _torchOn, activeColor: const Color(0xFFFFD600),
                        onTap: _toggleTorch,
                      ),
                    ]),
                    const SizedBox(height: 6),
                    // PENDING / auto-detect row
                    GestureDetector(
                      onTap: (!_isRecording && !_isCounting) ? _toggleAutoDetect : null,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: _autoDetect ? _green.withOpacity(0.1) : Colors.grey.shade100,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: _autoDetect ? _green : Colors.grey.shade300),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.back_hand_outlined,
                              size: 12,
                              color: _autoDetect ? _green : Colors.grey.shade500),
                          const SizedBox(width: 4),
                          Text(_autoDetect ? 'HAND ON' : 'PENDING',
                              style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
                                  letterSpacing: 0.5,
                                  color: _autoDetect ? _green : Colors.grey.shade500)),
                          const SizedBox(width: 4),
                          Icon(Icons.keyboard_arrow_right_rounded, size: 12,
                              color: _autoDetect ? _green : Colors.grey.shade500),
                        ]),
                      ),
                    ),
                  ]),
                ]),
              ),

              // ── Middle: video preview label ─────────────────────────
              Expanded(
                child: Container(
                  alignment: Alignment.center,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    // Resolution info
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(children: [
                        Text('1080p · 30fps',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                                color: Colors.grey.shade700)),
                        const SizedBox(height: 2),
                        Text('Standard 1.0x',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                      ]),
                    ),

                    // Auto-detect status
                    if (_autoDetect && _isDetecting)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _green.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('Show both hands to auto-start',
                            style: TextStyle(fontSize: 10, color: _green.withOpacity(0.8))),
                      ),
                  ]),
                ),
              ),

              // ── Bottom: Start New Recording button ──────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                child: Column(children: [

                  // Main action button — full width
                  SizedBox(
                    width: double.infinity,
                    child: _isDetecting
                        ? ElevatedButton.icon(
                            onPressed: _manualStart,
                            icon: const Icon(Icons.play_arrow_rounded,
                                color: Colors.white, size: 22),
                            label: const Text('Start New Recording',
                                style: TextStyle(color: Colors.white,
                                    fontSize: 13, fontWeight: FontWeight.w700)),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _green,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14)),
                              elevation: 0,
                            ),
                          )
                        : _isRecording
                            ? ElevatedButton.icon(
                                onPressed: _stopRecording,
                                icon: const Icon(Icons.stop_rounded,
                                    color: Colors.white, size: 22),
                                label: const Text('Stop Recording',
                                    style: TextStyle(color: Colors.white,
                                        fontSize: 13, fontWeight: FontWeight.w700)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _red,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                  elevation: 0,
                                ),
                              )
                            : ElevatedButton(
                                onPressed: null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.grey.shade300,
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14)),
                                  elevation: 0,
                                ),
                                child: Text(_isCounting ? 'Starting in $_countdown...' : 'Please wait...',
                                    style: TextStyle(color: Colors.grey.shade600,
                                        fontSize: 13, fontWeight: FontWeight.w700)),
                              ),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── Mini button widget ────────────────────────────────────────────────────────

class _MiniBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool active;
  final Color activeColor;

  const _MiniBtn({
    required this.icon, required this.label,
    this.onTap, this.active = false, this.activeColor = Colors.black,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 52, height: 44,
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.1) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: active ? activeColor : Colors.grey.shade300),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 18,
              color: active ? activeColor : Colors.grey.shade600),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: active ? activeColor : Colors.grey.shade500)),
        ]),
      ),
    );
  }
}