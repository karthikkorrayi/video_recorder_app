import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/video_processor.dart';

class ReviewScreen extends StatefulWidget {
  final String videoPath;
  const ReviewScreen({super.key, required this.videoPath});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  VideoPlayerController? _player;
  bool _playerReady = false;
  bool _isPlaying = false;
  bool _showControls = true;
  bool _saving = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  static const _orange = Color(0xFFE8620A);

  @override
  void initState() {
    super.initState();
    // Allow portrait during review
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final controller = VideoPlayerController.file(File(widget.videoPath));
    _player = controller;
    await controller.initialize();
    if (!mounted) return;
    setState(() {
      _playerReady = true;
      _duration = controller.value.duration;
    });
    controller.addListener(_onPlayerUpdate);
    controller.play();
    _isPlaying = true;
    setState(() {});
    _scheduleHideControls();
  }

  void _onPlayerUpdate() {
    if (!mounted) return;
    final c = _player;
    if (c == null) return;
    final pos = c.value.position;
    final playing = c.value.isPlaying;
    if (pos != _position || playing != _isPlaying) {
      setState(() { _position = pos; _isPlaying = playing; });
    }
    // Loop
    if (!c.value.isPlaying && pos >= _duration - const Duration(milliseconds: 300)) {
      c.seekTo(Duration.zero);
      c.play();
    }
  }

  void _scheduleHideControls() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHideControls();
  }

  void _togglePlayPause() {
    final c = _player;
    if (c == null) return;
    if (c.value.isPlaying) { c.pause(); setState(() => _isPlaying = false); }
    else { c.play(); setState(() => _isPlaying = true); _scheduleHideControls(); }
  }

  void _seekTo(double fraction) {
    final c = _player;
    if (c == null) return;
    c.seekTo(Duration(milliseconds: (fraction * _duration.inMilliseconds).toInt()));
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _saveAndReturn() async {
    setState(() => _saving = true);
    _player?.pause();

    // Start background processing — returns immediately
    VideoProcessor().startBackgroundProcessing(
      rawVideoPath: widget.videoPath,
      sessionTime: DateTime.now(),
    );

    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      // Restore portrait for the rest of the app
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_onPlayerUpdate);
    _player?.dispose();
    // Restore landscape for camera — will be set by CameraScreen
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _player;
    final totalMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds;
    final fraction = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(children: [
          // ── Video ────────────────────────────────────────────────────────
          if (_playerReady && c != null)
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: _orange)),

          // ── Saving overlay ───────────────────────────────────────────────
          if (_saving)
            Container(
              color: Colors.black.withOpacity(0.75),
              child: const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: _orange),
                  SizedBox(height: 16),
                  Text('Starting processing...', style: TextStyle(color: Colors.white70, fontSize: 14)),
                ]),
              ),
            ),

          // ── Controls overlay ─────────────────────────────────────────────
          if (_showControls && !_saving)
            AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 250),
              child: Stack(children: [
                // Top bar
                Positioned(top: 0, left: 0, right: 0,
                  child: Container(
                    padding: EdgeInsets.only(
                      top: MediaQuery.of(context).padding.top + 8,
                      left: 16, right: 16, bottom: 20,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.black.withOpacity(0.75), Colors.transparent],
                      ),
                    ),
                    child: Row(children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(context, 'recapture'),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white30),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.replay_rounded, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text('Recapture', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                          ]),
                        ),
                      ),
                      const Spacer(),
                      const Text('Review', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      GestureDetector(
                        onTap: _saveAndReturn,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: _orange,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.check_rounded, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text('Save', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),

                // Centre play/pause
                Center(
                  child: GestureDetector(
                    onTap: _togglePlayPause,
                    child: Container(
                      width: 64, height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.55),
                        border: Border.all(color: Colors.white30),
                      ),
                      child: Icon(
                        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white, size: 36,
                      ),
                    ),
                  ),
                ),

                // Bottom bar: seek + time
                Positioned(bottom: 0, left: 0, right: 0,
                  child: Container(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.of(context).padding.bottom + 16,
                      left: 16, right: 16, top: 20,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter, end: Alignment.topCenter,
                        colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                      ),
                    ),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Seek bar
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                          activeTrackColor: _orange,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: _orange,
                          overlayColor: _orange.withOpacity(0.2),
                        ),
                        child: Slider(
                          value: fraction,
                          onChanged: _seekTo,
                          onChangeStart: (_) => _player?.pause(),
                          onChangeEnd: (_) { if (_isPlaying) _player?.play(); },
                        ),
                      ),
                      // Time labels + duration
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(children: [
                          Text(_fmt(_position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          const Spacer(),
                          // Skip back 5s
                          GestureDetector(
                            onTap: () => _player?.seekTo(
                              Duration(milliseconds: (posMs - 5000).clamp(0, totalMs))),
                            child: const Icon(Icons.replay_5_rounded, color: Colors.white70, size: 22)),
                          const SizedBox(width: 16),
                          GestureDetector(
                            onTap: _togglePlayPause,
                            child: Icon(
                              _isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                              color: Colors.white, size: 36),
                          ),
                          const SizedBox(width: 16),
                          // Skip forward 5s
                          GestureDetector(
                            onTap: () => _player?.seekTo(
                              Duration(milliseconds: (posMs + 5000).clamp(0, totalMs))),
                            child: const Icon(Icons.forward_5_rounded, color: Colors.white70, size: 22)),
                          const Spacer(),
                          Text(_fmt(_duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}