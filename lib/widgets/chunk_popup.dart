import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../services/chunk_upload_queue.dart';

/// Issue 2: Chunk popup — thumbnail preview with seek scrubber.
/// No inline video playback (not reliable in bottom sheet).
/// Shows thumbnail + scrub bar + forward/back 4s labels.
/// Retry + Delete buttons below.
class ChunkPopup extends StatefulWidget {
  final ChunkState        cs;
  final ChunkUploadQueue  queue;
  const ChunkPopup({super.key, required this.cs, required this.queue});
  @override
  State<ChunkPopup> createState() => _ChunkPopupState();
}

class _ChunkPopupState extends State<ChunkPopup> {
  static const _green = Color(0xFF00C853);
  static const _red   = Colors.redAccent;
  static const _grey  = Color(0xFF888888);

  Uint8List? _thumb;
  bool       _loading = true;
  double     _scrubPos = 0.0; // 0.0–1.0, visual only

  @override
  void initState() {
    super.initState();
    _loadThumb();
  }

  Future<void> _loadThumb() async {
    final file = File(widget.cs.chunk.bestFilePath);
    if (!await file.exists()) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      // Try a few seek positions for a better thumbnail
      final t = await VideoThumbnail.thumbnailData(
        video:    file.path,
        imageFormat:   ImageFormat.JPEG,
        maxWidth: 480,
        quality:  80,
        timeMs:   (widget.cs.chunk.durationSecs * 500).toInt(), // ~middle
      );
      if (mounted) setState(() { _thumb = t; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Seek scrubber — visual only (no actual video player)
  /// Simulates position within the chunk's duration
  int get _scrubSecs =>
      (_scrubPos * widget.cs.chunk.durationSecs).round();

  String _fmtSecs(int s) {
    final m = (s ~/ 60).toString().padLeft(2,'0');
    final r = (s %  60).toString().padLeft(2,'0');
    return '$m:$r';
  }

  void _seekForward() {
    final dur  = widget.cs.chunk.durationSecs;
    if (dur <= 0) return;
    setState(() {
      _scrubPos = ((_scrubSecs + 4) / dur).clamp(0.0, 1.0);
    });
    // Reload thumbnail at new position
    _loadThumbAt(_scrubSecs);
  }

  void _seekBack() {
    final dur  = widget.cs.chunk.durationSecs;
    if (dur <= 0) return;
    setState(() {
      _scrubPos = ((_scrubSecs - 4) / dur).clamp(0.0, 1.0);
    });
    _loadThumbAt(_scrubSecs);
  }

  Future<void> _loadThumbAt(int secs) async {
    final file = File(widget.cs.chunk.bestFilePath);
    if (!await file.exists()) return;
    try {
      final t = await VideoThumbnail.thumbnailData(
        video:    file.path,
        imageFormat:   ImageFormat.JPEG,
        maxWidth: 480,
        quality:  80,
        timeMs:   secs * 1000,
      );
      if (mounted && t != null) setState(() => _thumb = t);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs       = widget.cs;
    final isFailed = cs.status == ChunkStatus.failed;
    final dur      = fmtDuration(cs.chunk.durationSecs);
    final durSecs  = cs.chunk.durationSecs;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Drag handle
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),

          // ── Thumbnail + seek controls ───────────────────────────────────
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Stack(fit: StackFit.expand, children: [

                // Background
                _loading
                    ? Container(color: Colors.grey[900],
                        child: const Center(child:
                            CircularProgressIndicator(color: _green)))
                    : _thumb != null
                        ? Image.memory(_thumb!, fit: BoxFit.cover)
                        : Container(color: const Color(0xFF1A1A1A),
                            child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.video_file_outlined,
                                      color: Colors.white54, size: 48),
                                  const SizedBox(height: 8),
                                  Text('Part ${cs.chunk.partNumber}  ·  $dur',
                                      style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13)),
                                ])),

                // Seek buttons overlay — left (back) and right (forward)
                Positioned(
                  left: 16, top: 0, bottom: 0,
                  child: Center(
                    child: _SeekBtn(
                      icon: Icons.replay_outlined,
                      label: '4s',
                      onTap: _seekBack,
                    ),
                  ),
                ),
                Positioned(
                  right: 16, top: 0, bottom: 0,
                  child: Center(
                    child: _SeekBtn(
                      icon: Icons.forward_outlined,
                      label: '4s',
                      onTap: _seekForward,
                    ),
                  ),
                ),

                // Current position label top-right
                if (durSecs > 0)
                  Positioned(
                    top: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8)),
                      child: Text(
                        '${_fmtSecs(_scrubSecs)} / ${_fmtSecs(durSecs)}',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11)),
                    ),
                  ),
              ]),
            ),
          ),

          // ── Scrub bar ─────────────────────────────────────────────────
          if (durSecs > 0) ...[
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                trackHeight: 3,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                activeTrackColor: _green,
                inactiveTrackColor: Colors.grey[300],
                thumbColor: _green,
                overlayColor: _green.withValues(alpha: 0.2),
              ),
              child: Slider(
                value: _scrubPos,
                onChanged: (v) => setState(() => _scrubPos = v),
                onChangeEnd: (v) => _loadThumbAt((v * durSecs).round()),
              ),
            ),
          ],

          // ── Filename + status ─────────────────────────────────────────
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
            Icon(isFailed ? Icons.error_outline : Icons.hourglass_empty,
                size: 13, color: isFailed ? _red : Colors.orange),
            const SizedBox(width: 4),
            Flexible(child: Text(cs.message,
                style: TextStyle(
                    color: isFailed ? _red : Colors.orange,
                    fontSize: 12),
                overflow: TextOverflow.ellipsis)),
          ]),
          const SizedBox(height: 16),

          // ── Action buttons ────────────────────────────────────────────
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
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
              onPressed: () async {
                Navigator.pop(context);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete chunk?'),
                    content: const Text(
                        'Removes from queue and deletes local file. '
                        'This cannot be undone.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete',
                              style: TextStyle(color: _red))),
                    ],
                  ),
                );
                if (ok == true) {
                  widget.queue.abandonChunk(cs.chunk.filePath);
                }
              },
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
}

class _SeekBtn extends StatelessWidget {
  final IconData     icon;
  final String       label;
  final VoidCallback onTap;
  const _SeekBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Colors.black54, shape: BoxShape.circle),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 22),
        Text(label, style: const TextStyle(
            color: Colors.white, fontSize: 9)),
      ]),
    ),
  );
}