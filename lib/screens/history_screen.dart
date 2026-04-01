import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/local_video_storage.dart';
import 'video_playback_screen.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0F),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('My Recordings',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 17)),
          if (!_loading)
            Text('${_sessions.length} video${_sessions.length == 1 ? '' : 's'}',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ]),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: Colors.white54), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF4F8EF7)))
          : _sessions.isEmpty ? _empty()
          : RefreshIndicator(
              onRefresh: _load,
              color: const Color(0xFF4F8EF7),
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: _sessions.length,
                itemBuilder: (_, i) => _card(_sessions[i]),
              ),
            ),
    );
  }

  Widget _card(LocalSession s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF141420),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: s.isComplete ? Colors.transparent : Colors.orange.withOpacity(0.3)),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 44, height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFF4F8EF7).withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.video_file_rounded, color: Color(0xFF4F8EF7), size: 22),
        ),
        title: Text(s.displayTitle,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            // Actual duration (from sidecar or estimate)
            Text(s.durationStr,
                style: const TextStyle(color: Color(0xFF4F8EF7), fontSize: 13, fontWeight: FontWeight.w500)),
            const SizedBox(width: 10),
            // Block info
            Text(s.blockSummary,
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            if (!s.isComplete) ...[
              const SizedBox(width: 8),
              const Text('incomplete', style: TextStyle(color: Colors.orange, fontSize: 11)),
            ],
          ]),
        ),
        trailing: const Icon(Icons.play_circle_outline_rounded, color: Color(0xFF4F8EF7), size: 28),
        onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => VideoPlaybackScreen(session: s)),
        ),
      ),
    );
  }

  Widget _empty() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: const [
      Icon(Icons.videocam_off_rounded, color: Colors.white12, size: 64),
      SizedBox(height: 16),
      Text('No recordings yet', style: TextStyle(color: Colors.white38, fontSize: 16)),
      SizedBox(height: 6),
      Text('Start recording to see your videos here',
          style: TextStyle(color: Colors.white24, fontSize: 13)),
    ]),
  );
}