import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/video_processor.dart';
import '../services/processing_manager.dart';

class ReviewScreen extends StatefulWidget {
  final String videoPath;
  const ReviewScreen({super.key, required this.videoPath});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late VideoPlayerController _player;
  bool _playerReady = false;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) setState(() => _playerReady = true);
        _player.setLooping(true);
        _player.play();
      });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _saveAndReturn() async {
    setState(() => _starting = true);

    // Start background processing — returns immediately
    final processor = VideoProcessor();
    processor.startBackgroundProcessing(
      rawVideoPath: widget.videoPath,
      sessionTime: DateTime.now(),
    );

    // Brief visual feedback then pop back to dashboard
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      // Pop all the way to dashboard (first route)
      Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // Video preview
        if (_playerReady)
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.contain, // keep original landscape ratio
              child: SizedBox(
                width: _player.value.size.width,
                height: _player.value.size.height,
                child: VideoPlayer(_player),
              ),
            ),
          )
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),

        // Top bar
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 8,
              left: 16, right: 16, bottom: 16,
            ),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.black.withOpacity(0.7), Colors.transparent],
              ),
            ),
            child: const Text('Review',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          ),
        ),

        // Bottom buttons
        if (!_starting)
          Positioned(
            bottom: 48, left: 0, right: 0,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _btn(
                icon: Icons.replay_rounded,
                label: 'Recapture',
                color: Colors.grey[850]!,
                onTap: () => Navigator.pop(context, 'recapture'),
              ),
              _btn(
                icon: Icons.check_rounded,
                label: 'Save',
                color: const Color(0xFFE8620A),
                onTap: _saveAndReturn,
              ),
            ]),
          ),

        // Starting indicator
        if (_starting)
          Positioned(
            bottom: 48, left: 0, right: 0,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(
                width: 28, height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFFE8620A)),
              ),
              const SizedBox(height: 10),
              const Text('Starting processing...',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
            ]),
          ),
      ]),
    );
  }

  Widget _btn({required IconData icon, required String label,
      required Color color, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
        decoration: BoxDecoration(
          color: color, borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(
            color: color.withOpacity(0.45), blurRadius: 14, offset: const Offset(0, 5))],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}