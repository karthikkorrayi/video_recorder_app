import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/local_video_storage.dart';
import 'video_playback_screen.dart';

const _green   = Color(0xFF00C853);
const _red     = Color(0xFFE53935);
const _surface = Color(0xFFF5F5F5);
const _card    = Color(0xFFFFFFFF);
const _text    = Color(0xFF1A1A1A);
const _sub     = Color(0xFF888888);
const _border  = Color(0xFFE8E8E8);

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  final _storage = LocalVideoStorage();
  List<LocalSession> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final user = FirebaseAuth.instance.currentUser!;
    final s = await _storage.listSessionsForUser(user.email ?? user.uid);
    if (mounted) setState(() { _sessions = s; _loading = false; });
  }

  // Total across all sessions using actual .dur sidecars only
  String get _grandTotal {
    int t = 0;
    for (final s in _sessions) { final d = s.durationSeconds; if (d > 0) t += d; }
    if (t <= 0) return '0s';
    if (t < 60) return '${t}s';
    final m = t ~/ 60; final r = t % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }

  // ── Delete ─────────────────────────────────────────────────────────────────

  Future<void> _confirmDelete(LocalSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(Icons.delete_forever_rounded, color: _red, size: 36),
        title: const Text('Delete Recording?',
            style: TextStyle(color: _text, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('This will permanently delete:', style: TextStyle(color: _sub, fontSize: 13)),
          const SizedBox(height: 8),
          _deleteItem(Icons.video_file_rounded,
              '${session.blocks.length} video block${session.blocks.length == 1 ? '' : 's'}'),
          _deleteItem(Icons.timer_outlined, session.durationStr),
          _deleteItem(Icons.calendar_today_rounded, session.displayTitle),
          const SizedBox(height: 8),
          const Text('This action cannot be undone.',
              style: TextStyle(color: _red, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel',
                style: TextStyle(color: _sub, fontWeight: FontWeight.w600)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
            child: const Text('Delete', style: TextStyle(color: Colors.white,
                fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );

    if (confirmed == true) await _deleteSession(session);
  }

  Widget _deleteItem(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        Icon(icon, size: 14, color: _sub),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: _text, fontSize: 13)),
      ]),
    );
  }

  Future<void> _deleteSession(LocalSession session) async {
    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Deleting...'), duration: Duration(seconds: 1)));

    try {
      for (final blockFile in session.blocks) {
        // Delete .mp4
        try { await blockFile.delete(); } catch (_) {}
        // Delete .dur sidecar
        try {
          final dur = File(blockFile.path.replaceAll(RegExp(r'\.mp4$'), '.dur'));
          if (await dur.exists()) await dur.delete();
        } catch (_) {}
        // Delete .meta sidecar
        try {
          final meta = File(blockFile.path.replaceAll(RegExp(r'\.mp4$'), '.meta'));
          if (await meta.exists()) await meta.delete();
        } catch (_) {}
      }

      // Try to remove the parent folder if it's now empty
      try {
        if (session.blocks.isNotEmpty) {
          final parent = session.blocks.first.parent;
          final remaining = parent.listSync();
          if (remaining.isEmpty) await parent.delete();
        }
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recording deleted'),
            backgroundColor: _red,
            duration: Duration(seconds: 2),
          ));
        _load(); // refresh list
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e'), backgroundColor: _red));
      }
    }
  }

  // ── Preview ────────────────────────────────────────────────────────────────

  void _preview(LocalSession session) {
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => VideoPlaybackScreen(session: session)));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: _card,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('My Recordings',
              style: TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 17)),
          if (!_loading)
            Text('${_sessions.length} session${_sessions.length == 1 ? '' : 's'}'
                '  ·  $_grandTotal total',
                style: const TextStyle(color: _sub, fontSize: 11)),
        ]),
        iconTheme: const IconThemeData(color: _text),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: const PreferredSize(preferredSize: Size.fromHeight(1),
            child: Divider(height: 1, color: _border)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: _sub),
              onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : _sessions.isEmpty ? _empty()
          : RefreshIndicator(
              onRefresh: _load, color: _green,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                itemCount: _sessions.length,
                itemBuilder: (_, i) => _buildCard(_sessions[i]),
              ),
            ),
    );
  }

  Widget _buildCard(LocalSession s) {
    final timeStr = s.durationStr;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: s.isComplete ? _border : Colors.orange.shade300),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Title row ─────────────────────────────────────────────────
          Row(children: [
            Container(width: 38, height: 38,
              decoration: BoxDecoration(color: _green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: _green.withOpacity(0.3))),
              child: const Icon(Icons.video_file_rounded, color: _green, size: 19)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.displayTitle, style: const TextStyle(color: _text,
                  fontWeight: FontWeight.w700, fontSize: 13)),
              if (!s.isComplete)
                const Text('Incomplete', style: TextStyle(color: Colors.orange, fontSize: 11)),
            ])),
          ]),

          const SizedBox(height: 10),
          const Divider(height: 1, color: _border),
          const SizedBox(height: 10),

          // ── Metrics row ───────────────────────────────────────────────
          Row(children: [
            _metric(Icons.timer_outlined, timeStr == '—' ? 'Processing' : timeStr,
                'Total Time', _green),
            _divider(),
            _metric(Icons.video_collection_outlined,
                '${s.blocks.length}/${s.totalBlocks}', 'Blocks', const Color(0xFF0091EA)),
            _divider(),
            _metric(Icons.play_circle_outline, s.startTimeStr, 'Start', const Color(0xFF7B1FA2)),
            _divider(),
            _metric(Icons.stop_circle_outlined, s.endTimeStr, 'End', const Color(0xFFE53935)),
          ]),

          const SizedBox(height: 12),
          const Divider(height: 1, color: _border),
          const SizedBox(height: 10),

          // ── Action buttons: Preview | Delete | Upload (coming soon) ───
          Row(children: [

            // Preview
            Expanded(child: _ActionChip(
              icon: Icons.play_circle_rounded,
              label: 'Preview',
              color: _green,
              onTap: () => _preview(s),
            )),
            const SizedBox(width: 8),

            // Delete
            Expanded(child: _ActionChip(
              icon: Icons.delete_outline_rounded,
              label: 'Delete',
              color: _red,
              onTap: () => _confirmDelete(s),
            )),
            const SizedBox(width: 8),

            // Upload (coming soon)
            Expanded(child: _ActionChip(
              icon: Icons.cloud_upload_outlined,
              label: 'Upload',
              color: _sub,
              onTap: null, // placeholder
              disabled: true,
              tooltip: 'Coming soon',
            )),
          ]),
        ]),
      ),
    );
  }

  Widget _metric(IconData icon, String value, String label, Color color) {
    return Expanded(child: Column(children: [
      Icon(icon, color: color, size: 15),
      const SizedBox(height: 3),
      Text(value, style: TextStyle(color: color, fontSize: 11,
          fontWeight: FontWeight.w700)),
      const SizedBox(height: 1),
      Text(label, style: const TextStyle(color: _sub, fontSize: 9)),
    ]));
  }

  Widget _divider() => Container(width: 1, height: 32, color: _border);

  Widget _empty() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.videocam_off_rounded, color: Colors.grey.shade300, size: 72),
      const SizedBox(height: 16),
      const Text('No recordings yet',
          style: TextStyle(color: _sub, fontSize: 16, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      const Text('Start recording to see your sessions here',
          style: TextStyle(color: _sub, fontSize: 13)),
    ]),
  );
}

// ── Action chip button ────────────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  final bool disabled;
  final String? tooltip;

  const _ActionChip({
    required this.icon, required this.label, required this.color,
    this.onTap, this.disabled = false, this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final Widget btn = GestureDetector(
      onTap: disabled ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: disabled ? const Color(0xFFF5F5F5) : color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: disabled ? const Color(0xFFE0E0E0) : color.withOpacity(0.35)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 15,
              color: disabled ? const Color(0xFFBBBBBB) : color),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600,
              color: disabled ? const Color(0xFFBBBBBB) : color)),
        ]),
      ),
    );

    if (tooltip != null) {
      return Tooltip(message: tooltip!, child: btn);
    }
    return btn;
  }
}