import 'package:flutter/material.dart';
import '../services/chunk_upload_queue.dart';

/// Clean session card shown in the camera screen right panel.
/// Shows: Session ID (left) + date badge (right-aligned), duration,
/// part number, live upload status pill from ChunkUploadQueue.
///
/// Usage in camera_screen.dart right panel:
///   CameraSessionOverlay(
///     sessionId:    _sessionId,
///     sessionStart: _sessionStart,
///     elapsedSecs:  _displaySecs,
///     partNumber:   _partNumber,
///     queue:        _queue,
///   )
class CameraSessionOverlay extends StatelessWidget {
  final String?          sessionId;
  final DateTime?        sessionStart;
  final int              elapsedSecs;
  final int              partNumber;
  final ChunkUploadQueue queue;

  const CameraSessionOverlay({
    super.key,
    required this.sessionId,
    required this.sessionStart,
    required this.elapsedSecs,
    required this.partNumber,
    required this.queue,
  });

  static const _green  = Color(0xFF00C853);
  static const _red    = Color(0xFFE53935);
  static const _orange = Colors.orange;
  static const _blue   = Colors.blue;

  /// Returns a human-readable date label for the session start time.
  /// Shows 'Today', 'Yesterday', or 'DD-MM-YYYY'.
  String _dateLabel(DateTime? dt) {
    if (dt == null) return '';
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d     = DateTime(dt.year, dt.month, dt.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return '${dt.day.toString().padLeft(2, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (sessionId == null) return const SizedBox.shrink();

    final sid     = sessionId!.length >= 6
        ? sessionId!.substring(0, 6).toUpperCase()
        : sessionId!.toUpperCase();
    final dur     = fmtDuration(elapsedSecs);
    final dateStr = _dateLabel(sessionStart);

    return StreamBuilder<List<ChunkState>>(
      stream: queue.stream,
      builder: (_, snap) {
        final uploading = queue.uploadingCount;
        final pending   = queue.pendingCount;
        final failed    = queue.failedCount;

        // Live status pill color + label
        final Color pillColor;
        final String pillLabel;
        if (uploading > 0) {
          pillColor = _blue;
          pillLabel = 'Uploading $uploading';
        } else if (pending > 0) {
          pillColor = _orange;
          pillLabel = '$pending queued';
        } else if (failed > 0) {
          pillColor = _red;
          pillLabel = '$failed failed';
        } else {
          pillColor = _green;
          pillLabel = 'Synced \u2713';
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.10),
                  blurRadius: 8,
                  offset: const Offset(0, 2))
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [

              // ── Header row: session ID + date badge right-aligned ────────
              Row(children: [
                // Session ID pill (dark)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Session $sid',
                    style: const TextStyle(
                        color: _green,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
                  ),
                ),
                const Spacer(),
                // Date badge — right-aligned
                if (dateStr.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: Text(
                      dateStr,
                      style: TextStyle(
                          color: Colors.grey[600], fontSize: 11),
                    ),
                  ),
              ]),

              const SizedBox(height: 8),

              // ── Info row: duration + part + status pill ──────────────────
              Row(children: [
                // Duration
                Row(children: [
                  const Icon(Icons.timer_outlined,
                      size: 13, color: Colors.grey),
                  const SizedBox(width: 4),
                  Text(
                    dur,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ]),
                const SizedBox(width: 12),
                // Part indicator
                Text(
                  'Part $partNumber',
                  style: TextStyle(
                      color: Colors.grey[600], fontSize: 12),
                ),
                const Spacer(),
                // Status pill
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: pillColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: pillColor.withValues(alpha: 0.40)),
                  ),
                  child: Text(
                    pillLabel,
                    style: TextStyle(
                        color: pillColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }
}