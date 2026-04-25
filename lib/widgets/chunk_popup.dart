import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../services/chunk_upload_queue.dart';
// Re-export so screens only need to import chunk_popup.dart
export '../services/chunk_upload_queue.dart';

/// Chunk preview popup.
/// Issue 5: auto-plays video when file exists.
/// Issue 1: delete/cancel buttons are full-screen modal dialogs (not nested sheets).
class ChunkPopup extends StatefulWidget {
  final ChunkState       cs;
  final ChunkUploadQueue queue;
  const ChunkPopup({super.key, required this.cs, required this.queue});

  @override
  State<ChunkPopup> createState() => _ChunkPopupState();
}

class _ChunkPopupState extends State<ChunkPopup> {
  static const _green = Color(0xFF00C853);
  static const _red   = Colors.redAccent;

  VideoPlayerController? _vpc;
  Uint8List?             _thumb;
  bool   _videoReady   = false;
  bool   _videoError   = false;
  bool   _loadingThumb = true;
  double _scrubPos     = 0.0;
  Timer? _progressTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final path = widget.cs.chunk.bestFilePath;
    final file = File(path);
    if (!await file.exists()) {
      if (mounted) setState(() { _loadingThumb = false; _videoError = true; });
      return;
    }

    // Load thumbnail immediately
    try {
      final t = await VideoThumbnail.thumbnailData(
        video: path, maxWidth: 480, quality: 80,
      );
      if (mounted) setState(() { _thumb = t; _loadingThumb = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingThumb = false);
    }

    // Issue 5: init video player + auto-play
    try {
      _vpc = VideoPlayerController.file(file);
      await _vpc!.initialize();
      if (!mounted) return;
      setState(() => _videoReady = true);
      // Auto-play immediately
      await _vpc!.play();
      // Update scrub bar while playing
      _progressTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (!mounted || _vpc == null) return;
        final dur = _vpc!.value.duration.inMilliseconds;
        final pos = _vpc!.value.position.inMilliseconds;
        if (dur > 0 && mounted) {
          setState(() => _scrubPos = (pos / dur).clamp(0.0, 1.0));
        }
        // Loop back to start when done
        if (!_vpc!.value.isPlaying && pos >= dur - 200 && dur > 0) {
          _vpc!.seekTo(Duration.zero);
          _vpc!.play();
        }
      });
    } catch (_) {
      if (mounted) setState(() => _videoError = true);
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _vpc?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    if (_vpc == null || !_videoReady) return;
    setState(() {
      _vpc!.value.isPlaying ? _vpc!.pause() : _vpc!.play();
    });
  }

  void _seek(int deltaSecs) {
    if (_vpc == null || !_videoReady) return;
    final pos = _vpc!.value.position;
    final dur = _vpc!.value.duration;
    final target = pos + Duration(seconds: deltaSecs);
    final clamped = target < Duration.zero
        ? Duration.zero
        : target > dur ? dur : target;
    _vpc!.seekTo(clamped);
  }

  String _fmtDur(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final cs       = widget.cs;
    final isFailed = cs.status == ChunkStatus.failed;
    final dur      = fmtDuration(cs.chunk.durationSecs);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Drag handle
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),

          // ── Video player / thumbnail ──────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(fit: StackFit.expand, children: [

                // Video or fallback
                if (_videoReady)
                  VideoPlayer(_vpc!)
                else if (_loadingThumb)
                  Container(color: Colors.grey[900],
                      child: const Center(child:
                          CircularProgressIndicator(color: _green)))
                else if (_thumb != null)
                  Image.memory(_thumb!, fit: BoxFit.cover)
                else
                  Container(color: const Color(0xFF1A1A1A),
                      child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.video_file_outlined,
                                color: Colors.white54, size: 48),
                            const SizedBox(height: 8),
                            Text('P${cs.chunk.partNumber}  ·  $dur',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 13)),
                          ])),

                // Position label top-right
                if (_videoReady)
                  Positioned(top: 8, right: 8,
                    child: ValueListenableBuilder(
                      valueListenable: _vpc!,
                      builder: (_, val, __) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black54,
                            borderRadius: BorderRadius.circular(8)),
                        child: Text(
                          '${_fmtDur(val.position)} / ${_fmtDur(val.duration)}',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 11)),
                      ),
                    ),
                  ),

                // Controls overlay
                Center(child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _CtrlBtn(
                        icon: Icons.replay_outlined,
                        label: '4s',
                        onTap: () => _seek(-4)),
                    const SizedBox(width: 20),
                    GestureDetector(
                      onTap: _togglePlay,
                      child: Container(
                        width: 52, height: 52,
                        decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle),
                        child: _videoReady
                            ? ValueListenableBuilder(
                                valueListenable: _vpc!,
                                builder: (_, val, __) => Icon(
                                    val.isPlaying
                                        ? Icons.pause_rounded
                                        : Icons.play_arrow_rounded,
                                    color: Colors.white, size: 28))
                            : const Icon(Icons.play_arrow_rounded,
                                color: Colors.white54, size: 28),
                      ),
                    ),
                    const SizedBox(width: 20),
                    _CtrlBtn(
                        icon: Icons.forward_outlined,
                        label: '4s',
                        onTap: () => _seek(4)),
                  ],
                )),

                // Progress bar at bottom
                if (_videoReady)
                  Positioned(bottom: 0, left: 0, right: 0,
                    child: ValueListenableBuilder(
                      valueListenable: _vpc!,
                      builder: (_, val, __) {
                        final dur = val.duration.inMilliseconds;
                        final pos = val.position.inMilliseconds;
                        return LinearProgressIndicator(
                          value: dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0,
                          backgroundColor: Colors.white24,
                          valueColor:
                              const AlwaysStoppedAnimation(_green),
                          minHeight: 3,
                        );
                      },
                    ),
                  ),

                if (_videoError)
                  Center(child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.broken_image_outlined,
                            color: Colors.white38, size: 36),
                        const SizedBox(height: 6),
                        const Text('Preview unavailable',
                            style: TextStyle(
                                color: Colors.white38, fontSize: 12)),
                      ])),
              ]),
            ),
          ),

          // Scrub slider
          if (_videoReady) ...[
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 3,
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: _green,
                inactiveTrackColor: Colors.grey[300],
                thumbColor: _green,
              ),
              child: Slider(
                value: _scrubPos,
                onChanged: (v) {
                  setState(() => _scrubPos = v);
                  if (_vpc != null) {
                    final ms =
                        (v * _vpc!.value.duration.inMilliseconds).round();
                    _vpc!.seekTo(Duration(milliseconds: ms));
                  }
                },
              ),
            ),
          ] else
            const SizedBox(height: 8),

          // Filename + status
          Text(cs.chunk.cloudFileName,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.timer_outlined, size: 13, color: Colors.grey[500]),
            const SizedBox(width: 4),
            Text(dur, style: TextStyle(
                color: Colors.grey[600], fontSize: 12)),
            const SizedBox(width: 12),
            Icon(isFailed
                    ? Icons.error_outline : Icons.hourglass_empty,
                size: 13,
                color: isFailed ? _red : Colors.orange),
            const SizedBox(width: 4),
            Flexible(child: Text(cs.message,
                style: TextStyle(
                    color: isFailed ? _red : Colors.orange,
                    fontSize: 12),
                overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 16),

          // ── Issue 1: Action buttons — no nested bottom sheets ─────────
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context); // close popup first
                widget.queue.retryChunk(cs.chunk);
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry Upload'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: _green,
                  side: const BorderSide(color: _green),
                  padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
            const SizedBox(width: 12),
            Expanded(child: OutlinedButton.icon(
              // Issue 1: show delete confirm as a DIALOG (not another sheet)
              // so Cancel / Delete buttons are fully responsive
              onPressed: () => _confirmDelete(context, cs),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: _red,
                  side: const BorderSide(color: _red),
                  padding: const EdgeInsets.symmetric(vertical: 12)),
            )),
          ]),
        ]),
      ),
    );
  }

  // Issue 1: delete confirm shown as full Dialog, not nested ModalBottomSheet
  // This fixes the unresponsive Cancel/Delete buttons.
  void _confirmDelete(BuildContext parentCtx, ChunkState cs) {
    // Pause video before showing dialog
    _vpc?.pause();

    showDialog<bool>(
      context: parentCtx,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete chunk?',
            style: TextStyle(fontWeight: FontWeight.bold)),
        content: const Text(
            'Removes from upload queue and deletes the local file. '
            'This cannot be undone.'),
        actions: [
          // Issue 1: TextButton uses Navigator.pop(dialogCtx) only —
          // does NOT close the bottom sheet, just the dialog
          TextButton(
            onPressed: () {
              Navigator.pop(dialogCtx, false); // close dialog only
              _vpc?.play(); // resume video
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(dialogCtx, true); // close dialog
              Navigator.pop(parentCtx);       // close bottom sheet
              widget.queue.abandonChunk(cs.chunk.filePath);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _CtrlBtn extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  const _CtrlBtn(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
          color: Colors.black54, shape: BoxShape.circle),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 22),
        Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 9)),
      ]),
    ),
  );
}