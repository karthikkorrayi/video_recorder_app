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
            Text('${_sessions.length} video${_sessions.length == 1 ? '' : 's'}',
                style: const TextStyle(color: _textSub, fontSize: 12)),
        ]),
        iconTheme: const IconThemeData(color: _text),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Divider(height: 1, color: _border)),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded, color: _textSub), onPressed: _load),
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
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: _cardColor, borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: s.isComplete ? _border : Colors.orange.shade300),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 46, height: 46,
          decoration: BoxDecoration(
            color: _green.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _green.withOpacity(0.3)),
          ),
          child: const Icon(Icons.video_file_rounded, color: _green, size: 22),
        ),
        title: Text(s.displayTitle,
            style: const TextStyle(color: _text, fontWeight: FontWeight.w600, fontSize: 14)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            // Actual duration (from sidecar or estimate)
            Text(s.durationStr,
                style: const TextStyle(color: _green, fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: _green.withOpacity(0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(s.blockSummary,
                  style: const TextStyle(color: _green, fontSize: 11,
                      fontWeight: FontWeight.w500)),
            ),
            if (!s.isComplete) ...[
              const SizedBox(width: 8),
              const Text('incomplete',
                  style: TextStyle(color: Colors.orange, fontSize: 11)),
            ],
          ]),
        ),
        trailing: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: _green.withOpacity(0.1),
            shape: BoxShape.circle,
            border: Border.all(color: _green.withOpacity(0.4)),
          ),
          child: const Icon(Icons.play_arrow_rounded, color: _green, size: 20),
        ),
        onTap: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => VideoPlaybackScreen(session: s))),
      ),
    );
  }

  Widget _empty() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.videocam_off_rounded, color: Colors.grey.shade300, size: 72),
      const SizedBox(height: 16),
      const Text('No recordings yet',
          style: TextStyle(color: _textSub, fontSize: 16,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      const Text('Start recording to see your videos here',
          style: TextStyle(color: _textSub, fontSize: 13)),
    ]),
  );
}