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

  // Quarter-turns needed to rotate the raw CameraPreview widget to match landscape
  // Android camera sensors are portrait-oriented (90° rotated physically).
  // CameraPreview on Android does NOT auto-rotate in landscape — we must do it.
  int _previewQuarterTurns = 0;

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

    // ── Camera preview rotation fix ────────────────────────────────────────
    //
    // On Android, the camera sensor is physically mounted portrait (90°).
    // CameraPreview renders raw sensor output without correcting for device rotation.
    // When the device is in landscape, the preview appears rotated 90° sideways.
    //
    // Fix: wrap CameraPreview in RotatedBox with quarterTurns calculated from
    // the camera's sensorOrientation value.
    //
    // sensorOrientation = 90  (typical back camera, most Android devices)
    // Device in landscapeLeft → we need to rotate preview by -1 quarterTurns (CCW)
    //
    // Formula: quarterTurns = sensorOrientation / 90
    // But we negate for back camera in landscape:
    //   sensor=90  → quarterTurns = -1  (3 turns CW = 1 turn CCW)
    //   sensor=270 → quarterTurns = 1
    //   sensor=0   → quarterTurns = 0
    //   sensor=180 → quarterTurns = 2
    //
    // This correctly orients the preview for landscape recording.

    final sensor = cam.sensorOrientation; // degrees: 0, 90, 180, 270
    switch (sensor) {
      case 90:
        _previewQuarterTurns = 3; // -1 CCW = 3 CW quarter-turns
        _mlRotation = InputImageRotation.rotation90deg;
        break;
      case 180:
        _previewQuarterTurns = 2;
        _mlRotation = InputImageRotation.rotation180deg;
        break;
      case 270:
        _previewQuarterTurns = 1;
        _mlRotation = InputImageRotation.rotation270deg;
        break;
      default: // 0
        _previewQuarterTurns = 0;
        _mlRotation = InputImageRotation.rotation0deg;
    }

    _ctrl = CameraController(
      cam,
      ResolutionPreset.veryHigh,  // 1080p on most devices
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.nv21,
    );
    await _ctrl!.initialize();
    try { await _ctrl!.setZoomLevel(await _ctrl!.getMinZoomLevel()); } catch (_) {}
    try { await _ctrl!.setExposureMode(ExposureMode.auto); } catch (_) {}
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

  // ── 5-second countdown with beep on every tick ────────────────────────────

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
      return const Scaffold(
        backgroundColor: Color(0xFF0D0D0D),
          body: Center(child: CircularProgressIndicator(color: _green)));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Row(children: [

        // ── LEFT: Camera preview (58%) ─────────────────────────────────────
        Expanded(
          flex: 58,
          child: Stack(children: [

            // ── THE FIX: RotatedBox corrects 90° sensor offset ─────────────
            // CameraPreview on Android outputs raw sensor frames which are
            // portrait-oriented. In landscape mode the device rotates 90° but
            // the preview stays portrait unless we explicitly rotate it.
            // RotatedBox(quarterTurns: 3) = 270° CW = 90° CCW which corrects
            // the typical back camera sensor offset of 90°.
            Positioned.fill(
              child: RotatedBox(
                quarterTurns: _previewQuarterTurns,
                child: CameraPreview(_ctrl!),
              ),
            ),

            // Info badge
            Positioned(top: 14, left: 14,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _badge('Standard · 1.0x · 1080p · 30fps', Colors.black.withOpacity(0.6)),
                const SizedBox(height: 6),
                if (_isRecording || _isSplitting)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: _red.withOpacity(0.9),
                        borderRadius: BorderRadius.circular(20)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.fiber_manual_record, color: Colors.white, size: 9),
                      const SizedBox(width: 4),
                      Text(_fmt(_elapsed), style: const TextStyle(color: Colors.white,
                          fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    ]),
                  ),
              ])),

            // Countdown
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
                _badge('Recording starts soon...', Colors.black.withOpacity(0.6)),
              ])),

            // Splitting
            if (_isSplitting)
              Container(color: Colors.black.withOpacity(0.45),
                child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: _green, strokeWidth: 2.5),
                  const SizedBox(height: 12),
                  _badge('Saving block & starting next...', Colors.black.withOpacity(0.6)),
                ]))),

            // Warning banner bottom
            if (_isWarning && !_isSplitting)
              Positioned(bottom: 16, left: 16, right: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(color: _red.withOpacity(0.9),
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    Text('Block ends in $_remainingLabel — get ready!',
                        style: const TextStyle(color: Colors.white, fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                )),
          ]),
        ),

        // ── RIGHT: Control panel (42%) ─────────────────────────────────────
        Expanded(
          flex: 42,
          child: Container(
            color: _surface,
            // Use SafeArea only on top/bottom for landscape notches
            child: SafeArea(
              left: false, right: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [

                  // ── Header ───────────────────────────────────────────────
                  Container(
                    color: _white,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        const Text('RECORDING', style: TextStyle(fontSize: 10,
                            fontWeight: FontWeight.w800, color: _sub, letterSpacing: 1.5)),
                        const Spacer(),
                        if (_blockNumber > 0 || _isRecording)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                                color: _green.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: _green.withOpacity(0.4))),
                            child: Text('Block ${_blockNumber + 1}',
                                style: const TextStyle(color: _green, fontSize: 10,
                                    fontWeight: FontWeight.w700)),
                          ),
                      ]),
                      const SizedBox(height: 6),
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(
                          _isRecording || _isSplitting ? _fmt(_elapsed) : '--:--',
                          style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold,
                              color: _isWarning ? _red : _text, letterSpacing: 1),
                        ),
                        const SizedBox(width: 8),
                        if (_isRecording)
                          Padding(padding: const EdgeInsets.only(bottom: 5),
                            child: Row(children: [
                              Container(width: 7, height: 7,
                                  decoration: const BoxDecoration(
                                      color: _red, shape: BoxShape.circle)),
                              const SizedBox(width: 5),
                              const Text('REC', style: TextStyle(color: _red,
                                  fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
                            ])),
                      ]),
                      if (_isRecording || _isSplitting) ...[
                        const SizedBox(height: 8),
                        ClipRRect(borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _blockProgress, minHeight: 5,
                            backgroundColor: _border,
                            valueColor: AlwaysStoppedAnimation<Color>(
                                _isWarning ? _red : _green))),
                        const SizedBox(height: 4),
                        Row(children: [
                          Text('Block time',
                              style: TextStyle(color: _sub, fontSize: 10)),
                          const Spacer(),
                          Text('$_remainingLabel left',
                              style: TextStyle(
                                color: _isWarning ? _red : _sub, fontSize: 10,
                                fontWeight: _isWarning ? FontWeight.w700 : FontWeight.normal,
                              )),
                        ]),
                      ],
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
                            const SizedBox(width: 5),
                            Text('Starting in $_countdown...',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                                    color: _countdown <= 2 ? _red : _green)),
                          ]),
                        ),
                      ],
                    ]),
                  ),

                  const Divider(height: 1, color: _border),

                  // ── Controls ─────────────────────────────────────────────
                  Expanded(child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(children: [

                      // Home + Flash
                      Expanded(child: Row(children: [
                        Expanded(child: _PanelBtn(
                          icon: Icons.home_rounded, label: 'Home',
                          onTap: () {
                            SystemChrome.setPreferredOrientations(
                                [DeviceOrientation.portraitUp]);
                            SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
                            Navigator.pop(context);
                          },
                        )),
                        const SizedBox(width: 10),
                        Expanded(child: _PanelBtn(
                          icon: _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                          label: _torchOn ? 'Flash ON' : 'Flash',
                          active: _torchOn,
                          activeColor: const Color(0xFFFFB300),
                          onTap: _toggleTorch,
                        )),
                      ])),
                      const SizedBox(height: 10),

                      // Hand detect
                      Expanded(child: _PanelBtn(
                        icon: _autoDetect
                            ? Icons.back_hand_rounded
                            : Icons.back_hand_outlined,
                        label: _autoDetect ? 'Hand Detect: ON' : 'Hand Detect: OFF',
                        active: _autoDetect,
                        activeColor: _green,
                        fullWidth: true,
                        onTap: (!_isRecording && !_isCounting) ? _toggleAutoDetect : null,
                      )),
                      const SizedBox(height: 10),

                      // Info card
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(color: _white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _border)),
                        child: Row(children: [
                          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('1080p · 30fps', style: TextStyle(fontSize: 11,
                                fontWeight: FontWeight.w700, color: _text)),
                            Text('Standard 1.0x',
                                style: TextStyle(fontSize: 10, color: _sub)),
                          ]),
                          const Spacer(),
                          Container(width: 1, height: 26, color: _border),
                          const SizedBox(width: 12),
                          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                            const Text('Auto-split', style: TextStyle(fontSize: 11,
                                fontWeight: FontWeight.w700, color: _text)),
                            Text('Every 20 min',
                                style: TextStyle(fontSize: 10, color: _sub)),
                          ]),
                        ]),
                      ),
                    ]),
                  )),

                  // ── Action button ────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                    child: _buildActionBtn(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _badge(String text, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(color: Colors.white,
          fontSize: 11, fontWeight: FontWeight.w500)),
    );
  }

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

// ── Panel button ──────────────────────────────────────────────────────────────

class _PanelBtn extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback? onTap;
  final bool active; final Color activeColor; final bool fullWidth;
  const _PanelBtn({required this.icon, required this.label, this.onTap,
      this.active = false, this.activeColor = Colors.black87, this.fullWidth = false});

  @override
  Widget build(BuildContext context) {
    final fg = active ? activeColor : const Color(0xFF555555);
    final bg = active ? activeColor.withOpacity(0.08) : Colors.white;
    final bd = active ? activeColor.withOpacity(0.4) : const Color(0xFFE8E8E8);
    return GestureDetector(
      onTap: onTap,
      child: Opacity(opacity: onTap == null ? 0.4 : 1.0,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: bd)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: fg, size: 18),
            const SizedBox(width: 7),
            Text(label, style: TextStyle(color: fg, fontSize: 12,
                fontWeight: FontWeight.w600)),
          ]),
        )),
    );
  }
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final IconData icon; final String label; final Color color; final VoidCallback? onTap;
  const _ActionBtn({required this.icon, required this.label,
      required this.color, this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(opacity: onTap == null ? 0.6 : 1.0,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 15),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(14)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(color: Colors.white,
                fontSize: 14, fontWeight: FontWeight.w700)),
          ]),
        )),
    );
  }
}