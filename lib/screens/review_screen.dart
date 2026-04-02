import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/video_processor.dart';

const _green  = Color(0xFF00C853);
const _greenD = Color(0xFF00A045);

class ReviewScreen extends StatefulWidget {
  final String videoPath;
  const ReviewScreen({super.key, required this.videoPath});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  VideoPlayerController? _player;
  bool _playerReady = false;
  bool _isPlaying   = false;
  bool _showCtrls   = true;
  bool _saving      = false;
  Duration _pos     = Duration.zero;
  Duration _dur     = Duration.zero;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _initPlayer();
  }

  Future<void> _initPlayer() async {
    final c = VideoPlayerController.file(File(widget.videoPath));
    _player = c;
    await c.initialize();
    if (!mounted) return;
    setState(() {
      _playerReady = true;
      _dur = c.value.duration;
    });
    c.addListener(_onUpdate);
    c.play();
    setState(() => _isPlaying = true);
    _scheduleHide();
  }

  void _onUpdate() {
    if (!mounted) return;
    final c = _player;
    if (c == null) return;
    final pos = c.value.position;
    final pl  = c.value.isPlaying;
    if (pos != _pos || pl != _isPlaying) {
      setState(() { _pos = pos; _isPlaying = pl; });
    }
    // Loop
    if (!pl && pos >= _dur - const Duration(milliseconds: 300) && _dur > Duration.zero) {
      c.seekTo(Duration.zero); c.play();
    }
  }

  void _scheduleHide() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) setState(() => _showCtrls = false);
    });
  }

  void _tapToggle() {
    setState(() => _showCtrls = !_showCtrls);
    if (_showCtrls) _scheduleHide();
  }

  void _togglePlay() {
    final c = _player;
    if (c == null) return;
    if (c.value.isPlaying) { c.pause(); setState(() => _isPlaying = false); }
    else { c.play(); setState(() => _isPlaying = true); _scheduleHide(); }
  }

  void _seekTo(double f) => _player?.seekTo(
      Duration(milliseconds: (f * _dur.inMilliseconds).toInt()));

  String _fmt(Duration d) =>
      '${d.inMinutes.remainder(60).toString().padLeft(2,'0')}:'
      '${d.inSeconds.remainder(60).toString().padLeft(2,'0')}';

  Future<void> _recapture() async {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    Navigator.pop(context, 'recapture');
  }

  Future<void> _saveAndReturn() async {
    setState(() => _saving = true);
    _player?.pause();

    VideoProcessor().startBackgroundProcessing(
      rawVideoPath: widget.videoPath,
      sessionTime: DateTime.now(),
    );

    await Future.delayed(const Duration(milliseconds: 400));
    if (mounted) {
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
    final totalMs = _dur.inMilliseconds;
    final posMs   = _pos.inMilliseconds;
    final frac    = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _tapToggle,
        child: Stack(children: [

          // ── Video ──────────────────────────────────────────────────────
          if (_playerReady && _player != null)
            Center(child: AspectRatio(
              aspectRatio: _player!.value.aspectRatio,
              child: VideoPlayer(_player!),
            ))
          else
            const Center(child: CircularProgressIndicator(color: _green)),

          // ── Saving overlay ─────────────────────────────────────────────
          if (_saving)
            Container(
              color: Colors.black.withOpacity(0.75),
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(color: _green, strokeWidth: 2.5),
                const SizedBox(height: 14),
                const Text('Queuing for processing...',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
              ])),
            ),

          // ── Controls ────────────────────────────────────────────────────
          if (_showCtrls && !_saving)
            AnimatedOpacity(
              opacity: 1.0,
              duration: const Duration(milliseconds: 200),
              child: Stack(children: [

                // Top bar — Recapture | Review | Save
                Positioned(top: 0, left: 0, right: 0,
                  child: Container(
                    decoration: BoxDecoration(gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.75), Colors.transparent],
                    )),
                    padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                    child: Row(children: [
                      // Recapture — green outline
                      GestureDetector(
                        onTap: _recapture,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: _green.withOpacity(0.7)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                            Icon(Icons.replay_rounded, color: _green, size: 16),
                            SizedBox(width: 6),
                            Text('Recapture', style: TextStyle(color: _green,
                                fontSize: 13, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                      const Spacer(),
                      const Text('Review', style: TextStyle(color: Colors.white,
                          fontSize: 15, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      // Save — solid green
                      GestureDetector(
                        onTap: _saveAndReturn,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 8),
                          decoration: BoxDecoration(
                            color: _green,
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: const [
                            Icon(Icons.check_rounded, color: Colors.white, size: 16),
                            SizedBox(width: 6),
                            Text('Save', style: TextStyle(color: Colors.white,
                                fontSize: 13, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),

                // Centre play/pause
                Center(child: GestureDetector(
                  onTap: _togglePlay,
                  child: Container(
                    width: 62, height: 62,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withOpacity(0.5),
                      border: Border.all(color: _green.withOpacity(0.6)),
                    ),
                    child: Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: _green, size: 34),
                  ),
                )),

                // Bottom seek bar + controls
                Positioned(bottom: 0, left: 0, right: 0,
                  child: Container(
                    decoration: BoxDecoration(gradient: LinearGradient(
                      begin: Alignment.bottomCenter, end: Alignment.topCenter,
                      colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                    )),
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      // Seek bar — green
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 7),
                          overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 16),
                          activeTrackColor: _green,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: _green,
                          overlayColor: _green.withOpacity(0.2),
                        ),
                        child: Slider(
                          value: frac,
                          onChanged: _seekTo,
                          onChangeStart: (_) => _player?.pause(),
                          onChangeEnd:   (_) { if (_isPlaying) _player?.play(); },
                        ),
                      ),
                      // Time + skip controls
                      Row(children: [
                        Text(_fmt(_pos), style: const TextStyle(
                            color: Colors.white60, fontSize: 12)),
                        const Spacer(),
                        // -5s
                        GestureDetector(
                          onTap: () => _player?.seekTo(Duration(
                              milliseconds: (posMs - 5000).clamp(0, totalMs))),
                          child: const Padding(padding: EdgeInsets.all(6),
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
                            color: _green, size: 40)),
                        const SizedBox(width: 8),
                        // +5s
                        GestureDetector(
                          onTap: () => _player?.seekTo(Duration(
                              milliseconds: (posMs + 5000).clamp(0, totalMs))),
                          child: const Padding(padding: EdgeInsets.all(6),
                            child: Icon(Icons.forward_5_rounded,
                                color: Colors.white70, size: 24))),
                        const Spacer(),
                        Text(_fmt(_dur), style: const TextStyle(
                            color: Colors.white60, fontSize: 12)),
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