import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/video_processor.dart';

class ReviewScreen extends StatefulWidget {
  final String videoPath;
  const ReviewScreen({super.key, required this.videoPath});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late VideoPlayerController _player;
  final _processor = VideoProcessor();

  bool _saving = false;
  bool _done = false;
  bool _error = false;
  String _statusText = '';
  int _currentBlock = 0;
  int _totalBlocks = 0;

  @override
  void initState() {
    super.initState();
    _player = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) => setState(() {}))
      ..setLooping(true)
      ..play();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _saveLocally() async {
    setState(() { _saving = true; _statusText = 'Preparing...'; _error = false; });

    try {
      final sessionTime = DateTime.now();
      final paths = await _processor.processAndSaveLocally(
        rawVideoPath: widget.videoPath,
        sessionTime: sessionTime,
        onProgress: (current, total, message) {
          if (mounted) setState(() {
            _currentBlock = current;
            _totalBlocks = total;
            _statusText = message;
          });
        },
      );

      if (mounted) {
        setState(() {
          _saving = false;
          _done = true;
          _statusText = 'Saved ${paths.length} block${paths.length == 1 ? '' : 's'} ✓';
        });
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) Navigator.popUntil(context, (r) => r.isFirst);
      }
    } catch (e) {
      if (mounted) setState(() { _saving = false; _error = true; _statusText = 'Error: $e'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // Video preview
        if (_player.value.isInitialized)
          SizedBox.expand(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _player.value.size.width,
                height: _player.value.size.height,
                child: VideoPlayer(_player),
              ),
            ),
          )
        else
          const Center(child: CircularProgressIndicator(color: Colors.white)),

        // Progress panel
        if (_saving || _done || _error)
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 48),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [Colors.black.withOpacity(0.95), Colors.transparent],
                ),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  if (_done)
                    const Icon(Icons.check_circle_rounded, color: Colors.greenAccent, size: 20)
                  else if (_error)
                    const Icon(Icons.error_rounded, color: Colors.redAccent, size: 20)
                  else
                    const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.blueAccent)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_statusText,
                      style: TextStyle(
                        color: _done ? Colors.greenAccent : _error ? Colors.redAccent : Colors.white,
                        fontSize: 14, fontWeight: FontWeight.w500,
                      ))),
                  if (_totalBlocks > 0 && !_done && !_error)
                    Text('$_currentBlock/$_totalBlocks',
                        style: const TextStyle(color: Colors.white38, fontSize: 13)),
                ]),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _totalBlocks > 0
                        ? (_currentBlock / _totalBlocks).clamp(0.0, 1.0)
                        : (_done ? 1.0 : null),
                    minHeight: 5,
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _done ? Colors.greenAccent : _error ? Colors.redAccent : Colors.blueAccent,
                    ),
                  ),
                ),
                if (_totalBlocks > 2) ...[
                  const SizedBox(height: 12),
                  Wrap(spacing: 6,
                    children: List.generate(_totalBlocks - 1, (i) {
                      final n = i + 1;
                      return Container(width: 9, height: 9,
                        decoration: BoxDecoration(shape: BoxShape.circle,
                          color: _done || n < _currentBlock ? Colors.greenAccent
                              : n == _currentBlock ? Colors.blueAccent : Colors.white24));
                    }),
                  ),
                ],
              ]),
            ),
          ),

        // Recapture / Save buttons
        if (!_saving && !_done && !_error)
          Positioned(
            bottom: 44, left: 0, right: 0,
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              _btn(icon: Icons.replay_rounded, label: 'Recapture',
                  color: Colors.grey[850]!,
                  onTap: () => Navigator.pop(context, 'recapture')),
              _btn(icon: Icons.save_rounded, label: 'Save',
                  color: const Color(0xFF4F8EF7),
                  onTap: _saveLocally),
            ]),
          ),

        // Retry on error
        if (_error)
          Positioned(
            bottom: 44, left: 0, right: 0,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _btn(icon: Icons.refresh_rounded, label: 'Retry',
                  color: const Color(0xFF4F8EF7), onTap: _saveLocally),
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
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: color.withOpacity(0.4), blurRadius: 12, offset: const Offset(0, 4))]),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}