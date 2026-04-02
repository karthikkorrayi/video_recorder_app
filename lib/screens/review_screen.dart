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
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Keep nav bar hidden (same as camera screen)
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

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
    controller.addListener(_onUpdate);
    controller.play();
    setState(() => _isPlaying = true);
    _scheduleHideControls();
  }

  void _onUpdate() {
    if (!mounted) return;
    final c = _player;
    if (c == null) return;
    final pos = c.value.position;
    final playing = c.value.isPlaying;
    if (pos != _position || playing != _isPlaying) {
      setState(() { _position = pos; _isPlaying = playing; });
    }
    // Loop at end
    if (!playing && pos >= _duration - const Duration(milliseconds: 300) && _duration > Duration.zero) {
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

  void _togglePlay() {
    final c = _player;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      setState(() => _isPlaying = false);
    } else {
      c.play();
      setState(() => _isPlaying = true);
      _scheduleHideControls();
    }
  }

  void _seekTo(double fraction) {
    _player?.seekTo(Duration(
      milliseconds: (fraction * _duration.inMilliseconds).toInt(),
    ));
  }

  String _fmt(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2,'0')}:'
      '${d.inSeconds.remainder(60).toString().padLeft(2,'0')}';

  Future<void> _recapture() async {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    Navigator.pop(context, 'recapture');
  }

  Future<void> _saveAndReturn() async {
    setState(() => _saving = true);
    _player?.pause();

    // Fire background processing — returns immediately
    VideoProcessor().startBackgroundProcessing(
      rawVideoPath: widget.videoPath,
      sessionTime: DateTime.now(),
    );

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) {
      // Restore portrait for dashboard/history screens
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  @override
  void dispose() {
    _player?.removeListener(_onUpdate);
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _player;
    final totalMs = _duration.inMilliseconds;
    final posMs   = _position.inMilliseconds;
    final fraction = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      // No AppBar — full immersive landscape view
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(children: [
          if (_playerReady && c != null)
            Center(
              child: AspectRatio(
                aspectRatio: c.value.aspectRatio,
                child: VideoPlayer(c),
              ),
            )
          else
            const Center(child: CircularProgressIndicator(color: _orange)),
          if (_saving)
            Container(
              color: Colors.black.withOpacity(0.72),
              child: const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: _orange, strokeWidth: 2.5),
                  SizedBox(height: 14),
                  Text('Queuing for processing...',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
                ]),
              ),
            ),
          if (_showControls && !_saving)
            AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Stack(children: [

                Positioned(
                  top: 0, left: 0, right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.black.withOpacity(0.75), Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    child: Row(children: [
                      // Recapture
                      GestureDetector(
                        onTap: _recapture,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: Colors.white30),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.replay_rounded, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text('Recapture',
                              style: TextStyle(color: Colors.white, fontSize: 13,
                                fontWeight: FontWeight.w500)),
                          ]),
                        ),
                      ),
                      const Spacer(),
                      const Text('Review',
                        style: TextStyle(color: Colors.white, fontSize: 15,
                          fontWeight: FontWeight.w600)),
                      const Spacer(),
                      // Save
                      GestureDetector(
                        onTap: _saveAndReturn,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: _orange,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: const Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.check_rounded, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text('Save',
                              style: TextStyle(color: Colors.white, fontSize: 13,
                                fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),

                // Centre play/pause
                Center(
                  child: GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      width: 60, height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.5),
                        border: Border.all(color: Colors.white30),
                      ),
                      child: Icon(
                        _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                        color: Colors.white, size: 32,
                      ),
                    ),
                  ),
                ),

                // Bottom bar — seek + time + controls
                Positioned(
                  bottom: 0, left: 0, right: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
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
                      // Time + skip controls
                      Row(children: [
                        Text(_fmt(_position),
                          style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        const Spacer(),
                        // Skip back 5s
                        GestureDetector(
                          onTap: () => _player?.seekTo(Duration(
                            milliseconds: (posMs - 5000).clamp(0, totalMs))),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.replay_5_rounded,
                              color: Colors.white70, size: 24))),
                        const SizedBox(width: 8),
                        // Play/pause
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Icon(
                            _isPlaying
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_filled_rounded,
                            color: Colors.white, size: 38)),
                        const SizedBox(width: 8),
                        // Skip forward 5s
                        GestureDetector(
                          onTap: () => _player?.seekTo(Duration(
                            milliseconds: (posMs + 5000).clamp(0, totalMs))),
                          child: const Padding(
                            padding: EdgeInsets.all(6),
                            child: Icon(Icons.forward_5_rounded,
                              color: Colors.white70, size: 24))),
                        const Spacer(),
                        Text(_fmt(_duration),
                          style: const TextStyle(color: Colors.white60, fontSize: 12)),
                      ]),
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