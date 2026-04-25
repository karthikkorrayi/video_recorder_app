import 'package:flutter/material.dart';
import '../services/chunk_upload_queue.dart';

/// Issue 2: Shows current session upload status + "+N more sessions" badge.
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

  String _dateLabel(DateTime? dt) {
    if (dt == null) return '';
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d     = DateTime(dt.year, dt.month, dt.day);
    if (d == today) return 'Today';
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return '${dt.day.toString().padLeft(2,'0')}-${dt.month.toString().padLeft(2,'0')}-${dt.year}';
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
        final allChunks = snap.data ?? queue.current;

        // Current session chunks only
        final sessionChunks = allChunks
            .where((c) => c.chunk.sessionId == sid)
            .toList()
          ..sort((a, b) => a.chunk.partNumber.compareTo(b.chunk.partNumber));

        // Other sessions count
        final otherSessions = queue.groupedBySesion.keys
            .where((s) => s != sid)
            .length;

        final uploading = queue.uploadingCount;
        final pending   = queue.pendingCount;
        final failed    = queue.failedCount;

        // Status pill
        final Color pillColor;
        final String pillLabel;
        if (failed > 0) {
          pillColor = _red;
          pillLabel = '$failed failed';
        } else if (uploading > 0) {
          pillColor = _blue;
          pillLabel = 'Uploading...';
        } else if (pending > 0) {
          pillColor = _orange;
          pillLabel = '$pending queued';
        } else {
          pillColor = _green;
          pillLabel = 'Synced ✓';
        }

        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(
                color: Colors.black.withValues(alpha: 0.10),
                blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [

            // ── Current session header ──────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text('Session $sid',
                      style: const TextStyle(color: _green,
                          fontWeight: FontWeight.bold, fontSize: 11)),
                ),
                const Spacer(),
                if (dateStr.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.grey[300]!)),
                    child: Text(dateStr,
                        style: TextStyle(color: Colors.grey[600], fontSize: 11)),
                  ),
              ]),
            ),

            // Duration + part + status
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(children: [
                const Icon(Icons.timer_outlined, size: 13, color: Colors.grey),
                const SizedBox(width: 4),
                Text(dur, style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                Text('Part $partNumber',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                      color: pillColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: pillColor.withValues(alpha: 0.40))),
                  child: Text(pillLabel,
                      style: TextStyle(color: pillColor, fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ]),
            ),

            // ── Current session chunk bars ──────────────────────────────
            if (sessionChunks.isNotEmpty) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                child: Row(children: [
                  ...sessionChunks.take(6).map((cs) => _miniBar(cs)),
                  if (sessionChunks.length > 6)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text('+${sessionChunks.length - 6}',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 10)),
                    ),
                ]),
              ),
            ],

            // ── Issue 2: "+N more sessions pending" badge ───────────────
            if (otherSessions > 0)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(children: [
                  Icon(Icons.layers_outlined, size: 13, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text('+$otherSessions more session${otherSessions == 1 ? '' : 's'} pending',
                      style: TextStyle(color: Colors.grey[500], fontSize: 11)),
                ]),
              ),
          ]),
        );
      },
    );
  }

  Widget _miniBar(ChunkState cs) {
    final isUp   = cs.status == ChunkStatus.uploading;
    final isFail = cs.status == ChunkStatus.failed;
    final Color fill = isUp ? _blue : isFail ? _red : Colors.grey[300]!;
    final double pct  = isUp ? cs.progress.clamp(0.0, 1.0) : 0.0;

    return Container(
      width: 28, height: 16,
      margin: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: fill.withValues(alpha: 0.5))),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: FractionallySizedBox(
          widthFactor: pct,
          alignment: Alignment.centerLeft,
          child: Container(color: fill.withValues(alpha: 0.8)),
        ),
      ),
    );
  }
}