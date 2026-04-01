import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/local_video_storage.dart';

class VideoPlaybackScreen extends StatefulWidget {
  final LocalSession session;
  const VideoPlaybackScreen({super.key, required this.session});

  @override
  State<VideoPlaybackScreen> createState() => _VideoPlaybackScreenState();
}

class _VideoPlaybackScreenState extends State<VideoPlaybackScreen> {
  VideoPlayerController? _ctrl;
  int _blockIdx = 0;
  bool _showControls = true;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    // Videos are 9:16 portrait — play in portrait by default.
    // User can rotate device if desired.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _loadBlock(0);
  }

  @override
  void dispose() {
    // *** Critical fix: restore portrait (not landscape) on exit ***
    // The rest of the app (dashboard, history) is portrait.
    // CameraScreen sets its own landscape when opened.
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _loadBlock(int idx) async {
    if (idx < 0 || idx >= widget.session.blocks.length) return;
    setState(() => _loading = true);

    final prev = _ctrl;
    _ctrl = null;
    await prev?.dispose();

    final c = VideoPlayerController.file(widget.session.blocks[idx]);
    await c.initialize();
    c.addListener(_onUpdate);
    c.play();

    if (mounted) setState(() { _ctrl = c; _blockIdx = idx; _loading = false; });
  }

  void _onUpdate() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.position >= c.value.duration && !c.value.isPlaying) {
      if (_blockIdx + 1 < widget.session.blocks.length) {
        _loadBlock(_blockIdx + 1);
        return;
      }
    }
    if (mounted) setState(() {});
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showControls = false);
      });
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final ready = c?.value.isInitialized ?? false;
    final playing = c?.value.isPlaying ?? false;
    final pos = c?.value.position ?? Duration.zero;
    final dur = c?.value.duration ?? Duration.zero;
    final total = widget.session.blocks.length;

    return WillPopScope(
      // Ensure orientation is reset even on Android back gesture
      onWillPop: () async {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _toggleControls,
          child: Stack(children: [
            // Video
            if (ready)
              Center(child: AspectRatio(
                aspectRatio: c!.value.aspectRatio,
                child: VideoPlayer(c),
              ))
            else
              const Center(child: CircularProgressIndicator(color: Colors.white)),

            if (_loading)
              Container(color: Colors.black54,
                  child: const Center(child: CircularProgressIndicator(color: Colors.white))),

            if (_showControls) ...[
              // Top bar
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(
                  decoration: BoxDecoration(gradient: LinearGradient(
                    begin: Alignment.topCenter, end: Alignment.bottomCenter,
                    colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                  )),
                  padding: EdgeInsets.only(
                    top: MediaQuery.of(context).padding.top + 8,
                    left: 8, right: 16, bottom: 16),
                  child: Row(children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(child: Text(widget.session.displayTitle,
                        style: const TextStyle(color: Colors.white, fontSize: 15,
                            fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis)),
                    if (total > 1)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: Colors.white12,
                            borderRadius: BorderRadius.circular(20)),
                        child: Text('Block ${_blockIdx + 1}/$total',
                            style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      ),
                  ]),
                ),
              ),

              // Bottom controls
              Positioned(
                bottom: 0, left: 0, right: 0,
                child: Container(
                  decoration: BoxDecoration(gradient: LinearGradient(
                    begin: Alignment.bottomCenter, end: Alignment.topCenter,
                    colors: [Colors.black.withOpacity(0.85), Colors.transparent],
                  )),
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.of(context).padding.bottom + 16,
                    left: 16, right: 16, top: 16),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    // Block dots
                    if (total > 1)
                      Row(mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(total, (i) => AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: i == _blockIdx ? 18 : 8, height: 4,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: i == _blockIdx ? Colors.white
                                : i < _blockIdx ? Colors.white54 : Colors.white24,
                            borderRadius: BorderRadius.circular(2)),
                        ))),
                    const SizedBox(height: 6),

                    // Seek bar
                    if (ready)
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          trackHeight: 3,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: dur.inMilliseconds > 0
                              ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0) : 0,
                          onChanged: (v) => c?.seekTo(
                              Duration(milliseconds: (v * dur.inMilliseconds).toInt())),
                        ),
                      ),

                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Text('${_fmt(pos)} / ${_fmt(dur)}',
                          style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      Row(children: [
                        if (_blockIdx > 0)
                          IconButton(icon: const Icon(Icons.skip_previous_rounded,
                              color: Colors.white, size: 28),
                              onPressed: () => _loadBlock(_blockIdx - 1)),
                        IconButton(
                          icon: Icon(playing
                              ? Icons.pause_circle_filled_rounded
                              : Icons.play_circle_filled_rounded,
                              color: Colors.white, size: 48),
                          onPressed: () { playing ? c?.pause() : c?.play(); setState(() {}); },
                        ),
                        if (_blockIdx < total - 1)
                          IconButton(icon: const Icon(Icons.skip_next_rounded,
                              color: Colors.white, size: 28),
                              onPressed: () => _loadBlock(_blockIdx + 1)),
                      ]),
                      const SizedBox(width: 60),
                    ]),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}