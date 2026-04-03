import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/local_video_storage.dart';
import 'video_playback_screen.dart';

const _green   = Color(0xFF00C853);
const _surface = Color(0xFFF4F4F4);
const _cardColor    = Color(0xFFFFFFFF);
const _text    = Color(0xFF1A1A1A);
const _textSub = Color(0xFF666666);
const _border  = Color(0xFFE0E0E0);

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
    int total = 0;
    for (final s in _sessions) {
      final d = s.durationSeconds; // reads .dur sidecar — never inflated
      if (d > 0) total += d;
    }
    if (total <= 0) return '0s';
    if (total < 60) return '${total}s';
    final m = total ~/ 60; final r = total % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: _cardColor,
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('My Recordings',
              style: TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 17)),
          if (!_loading)
            Text('${_sessions.length} session${_sessions.length == 1 ? '' : 's'}'
                ' · $_grandTotal total',
                style: const TextStyle(color: _textSub, fontSize: 11)),
        ]),
        iconTheme: const IconThemeData(color: _text),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: const PreferredSize(
            preferredSize: Size.fromHeight(1),
            child: Divider(height: 1, color: _border)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: _textSub),
              onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : _sessions.isEmpty ? _empty()
          : RefreshIndicator(
              onRefresh: _load, 
              color: _green,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: _sessions.length,
                itemBuilder: (_, i) => _card(_sessions[i]),
              ),
            ),
    );
  }

  Widget _card(LocalSession s) {
    // durationStr reads the actual .dur sidecar written by FFprobe
    // Shows '—' if sidecar not found (video still processing)
    final timeStr = s.durationStr;

    return GestureDetector(
      onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => VideoPlaybackScreen(session: s))),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: _cardColor, borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: s.isComplete ? _border : Colors.orange.shade300),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
              blurRadius: 8, offset: const Offset(0, 2))],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Row 1: Date title + play button ─────────────────────────
            Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: _green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _green.withOpacity(0.3)),
                ),
                child: const Icon(Icons.video_file_rounded, color: _green, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.displayTitle,
                    style: const TextStyle(color: _text,
                        fontWeight: FontWeight.w700, fontSize: 14)),
                const SizedBox(height: 2),
                if (!s.isComplete)
                  const Text('Incomplete recording',
                      style: TextStyle(color: Colors.orange, fontSize: 11)),
              ])),
              Container(
                width: 34, height: 34,
                decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 20),
              ),
            ]),

            const SizedBox(height: 14),
            const Divider(height: 1, color: _border),
            const SizedBox(height: 12),

            // ── Row 2: 4-metric grid ─────────────────────────────────────
            // All values come from actual recorded data — no estimates.
            Row(children: [
              // Total Time — from .dur sidecar (actual FFprobe duration)
              _metric(
                icon: Icons.timer_outlined,
                label: 'Total Time',
                value: timeStr,
                color: _green,
                note: timeStr == '—' ? 'processing' : null,
              ),
              _divider(),

              // Blocks — how many saved / total expected
              _metric(
                icon: Icons.video_collection_outlined,
                label: 'Blocks',
                value: '${s.blocks.length} / ${s.totalBlocks}',
                color: const Color(0xFF0091EA),
              ),
              _divider(),

              // Start time — from .meta sidecar or filename
              _metric(
                icon: Icons.play_circle_outline,
                label: 'Start',
                value: s.startTimeStr,
                color: const Color(0xFF7B1FA2),
              ),
              _divider(),

              // End time — from .meta sidecar or estimated
              _metric(
                icon: Icons.stop_circle_outlined,
                label: 'End',
                value: s.endTimeStr,
                color: const Color(0xFFE53935),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _metric({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    String? note,
  }) {
    return Expanded(child: Column(children: [
      Icon(icon, color: color, size: 15),
      const SizedBox(height: 4),
      Text(value,
          style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      const SizedBox(height: 1),
      Text(note ?? label,
          style: TextStyle(
              color: note != null ? Colors.orange : _textSub,
              fontSize: 9.5)),
    ]));
  }

  Widget _divider() =>
      Container(width: 1, height: 36, color: _border);

  Widget _empty() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.videocam_off_rounded, color: Colors.grey.shade300, size: 72),
      const SizedBox(height: 16),
      const Text('No recordings yet',
          style: TextStyle(color: _textSub, fontSize: 16,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      const Text('Start recording to see your sessions here',
          style: TextStyle(color: _textSub, fontSize: 13)),
    ]),
  );
}