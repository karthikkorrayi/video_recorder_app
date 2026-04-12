import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/session_store.dart';
import '../models/session_model.dart';
import 'upload_progress_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _store = SessionStore();
  List<SessionModel> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await _store.getAll();
    if (mounted) setState(() { _sessions = all; _loading = false; });
  }

  // ── Status helpers ───────────────────────────────────────────────────────
  Color _statusColor(String status) {
    switch (status) {
      case 'synced':    return const Color(0xFF00C853);
      case 'uploading': return Colors.blueAccent;
      case 'partial':   return Colors.orangeAccent;
      default:          return Colors.redAccent;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'synced':    return Icons.cloud_done;
      case 'uploading': return Icons.cloud_upload;
      case 'partial':   return Icons.cloud_sync;
      default:          return Icons.cloud_off;
    }
  }

  String _statusLabel(SessionModel s) {
    switch (s.status) {
      case 'synced':    return 'Synced';
      case 'uploading': return 'Uploading...';
      case 'partial':   return '${s.uploadedBlocks.length}/${s.blockCount} blocks';
      default:          return 'Pending';
    }
  }

  // ── Summary counts ───────────────────────────────────────────────────────
  Map<String, int> get _counts => {
    'pending':  _sessions.where((s) => s.status == 'pending').length,
    'partial':  _sessions.where((s) => s.status == 'partial').length,
    'uploading':_sessions.where((s) => s.status == 'uploading').length,
    'synced':   _sessions.where((s) => s.status == 'synced').length,
  };

  // ── Upload tap ───────────────────────────────────────────────────────────
  Future<void> _onUpload(SessionModel session) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => UploadProgressScreen(session: session)),
    );
    if (result == true) _load(); // Refresh list after successful upload
  }

  // ── Delete tap ───────────────────────────────────────────────────────────
  Future<void> _onDelete(SessionModel session) async {
    if (session.status == 'synced') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot delete — already synced to OneDrive'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Delete session?', style: TextStyle(color: Colors.white)),
        content: const Text('This will delete the local recording. It has not been uploaded.',
            style: TextStyle(color: Colors.white54)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );

    if (confirm == true) {
      await _store.delete(session.id);
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = _counts;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Session History',
            style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white54),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF00C853)))
          : Column(
              children: [
                // ── Summary pills ──────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      _Pill('Pending',   counts['pending']!,  Colors.redAccent),
                      const SizedBox(width: 8),
                      _Pill('Partial',   counts['partial']!,  Colors.orangeAccent),
                      const SizedBox(width: 8),
                      _Pill('Uploading', counts['uploading']!, Colors.blueAccent),
                      const SizedBox(width: 8),
                      _Pill('Synced',    counts['synced']!,   const Color(0xFF00C853)),
                    ]),
                  ),
                ),

                // ── Session list ───────────────────────────────────
                Expanded(
                  child: _sessions.isEmpty
                      ? const Center(
                          child: Text('No sessions recorded yet',
                              style: TextStyle(color: Colors.white38)))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: _sessions.length,
                          itemBuilder: (ctx, i) => _SessionCard(
                            session: _sessions[i],
                            statusColor: _statusColor(_sessions[i].status),
                            statusIcon:  _statusIcon(_sessions[i].status),
                            statusLabel: _statusLabel(_sessions[i]),
                            onUpload: _onUpload,
                            onDelete: _onDelete,
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

// ── Session card ─────────────────────────────────────────────────────────────
class _SessionCard extends StatelessWidget {
  final SessionModel session;
  final Color    statusColor;
  final IconData statusIcon;
  final String   statusLabel;
  final Future<void> Function(SessionModel) onUpload;
  final Future<void> Function(SessionModel) onDelete;

  const _SessionCard({
    required this.session,
    required this.statusColor,
    required this.statusIcon,
    required this.statusLabel,
    required this.onUpload,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final isSynced   = session.status == 'synced';
    final canUpload  = session.status == 'pending' || session.status == 'partial';
    final dateStr    = DateFormat('dd MMM yyyy, hh:mm a').format(session.createdAt);
    final durMin     = (session.durationSeconds / 60).toStringAsFixed(1);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSynced
              ? const Color(0xFF00C853).withOpacity(0.25)
              : Colors.white10,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Top row: date + status ─────────────────────────────
          Row(children: [
            Expanded(
              child: Text(dateStr,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: statusColor.withOpacity(0.4)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(statusIcon, size: 12, color: statusColor),
                const SizedBox(width: 5),
                Text(statusLabel,
                    style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),

          const SizedBox(height: 8),

          // ── Meta info ──────────────────────────────────────────
          Row(children: [
            _Meta(Icons.timer_outlined, '$durMin min'),
            const SizedBox(width: 16),
            _Meta(Icons.video_file_outlined, '${session.blockCount} block${session.blockCount != 1 ? 's' : ''}'),
            if (session.isPartial) ...[
              const SizedBox(width: 16),
              _Meta(Icons.upload, '${session.uploadedBlocks.length} uploaded',
                  color: Colors.orangeAccent),
            ],
          ]),

          // ── Block progress bar (for partial/synced) ────────────
          if (session.blockCount > 0 && !isSynced && session.uploadedBlocks.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: session.uploadedBlocks.length / session.blockCount,
                minHeight: 4,
                backgroundColor: Colors.white10,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.orangeAccent),
              ),
            ),
          ],

          const SizedBox(height: 12),

          // ── Action buttons ─────────────────────────────────────
          Row(children: [
            // Upload button
            if (canUpload)
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => onUpload(session),
                  icon: const Icon(Icons.cloud_upload, size: 16),
                  label: Text(session.isPartial ? 'Resume Upload' : 'Upload to OneDrive'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C853),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),

            // Synced indicator (no upload button)
            if (isSynced)
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00C853).withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF00C853).withOpacity(0.2)),
                  ),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.cloud_done, size: 14, color: Color(0xFF00C853)),
                    SizedBox(width: 6),
                    Text('Synced to OneDrive',
                        style: TextStyle(
                            color: Color(0xFF00C853),
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),

            const SizedBox(width: 8),

            // Delete button — disabled (greyed out) when synced
            Tooltip(
              message: isSynced ? 'Cannot delete — already uploaded to OneDrive' : 'Delete local recording',
              child: IconButton(
                onPressed: isSynced ? null : () => onDelete(session),
                icon: Icon(
                  Icons.delete_outline,
                  color: isSynced ? Colors.white12 : Colors.redAccent.withOpacity(0.6),
                ),
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String   text;
  final Color    color;
  const _Meta(this.icon, this.text, {this.color = const Color(0xFF888888)});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: color),
    const SizedBox(width: 4),
    Text(text, style: TextStyle(color: color, fontSize: 12)),
  ]);
}

class _Pill extends StatelessWidget {
  final String label;
  final int    count;
  final Color  color;
  const _Pill(this.label, this.count, this.color);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Text('$label: $count',
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
  );
}