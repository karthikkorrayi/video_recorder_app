import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';
import '../services/session_store.dart';
import '../models/session_model.dart';
import 'upload_progress_screen.dart';

const _green  = Color(0xFF00C853);
const _red    = Color(0xFFE53935);
const _surface= Color(0xFFF4F6F8);
const _card   = Color(0xFFFFFFFF);
const _text   = Color(0xFF1A1A1A);
const _sub    = Color(0xFF888888);
const _border = Color(0xFFE8E8E8);

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
  final _store = SessionStore();
  late TabController _tabs;
  List<SessionModel> _local  = [];
  List<SessionModel> _synced = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
  }

  @override
  void dispose() { _tabs.dispose(); super.dispose(); }

  Future<void> _load() async {
    final all = await _store.getAll();
    if (mounted) setState(() {
      _local  = all.where((s) => s.status != 'synced').toList();
      _synced = all.where((s) => s.status == 'synced').toList();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      appBar: AppBar(
        backgroundColor: _card,
        elevation: 0,
        foregroundColor: _text,
        title: const Text('My Recordings',
            style: TextStyle(color: _text, fontWeight: FontWeight.w700, fontSize: 18)),
        actions: [IconButton(icon: const Icon(Icons.refresh, color: _sub), onPressed: _load)],
        bottom: TabBar(
          controller: _tabs,
          labelColor: _green,
          unselectedLabelColor: _sub,
          indicatorColor: _green,
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          tabs: [
            Tab(text: 'Local  (${_local.length})'),
            Tab(text: 'Synced  (${_synced.length})'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : TabBarView(controller: _tabs, children: [
              _LocalTab(sessions: _local, onRefresh: _load),
              _SyncedTab(sessions: _synced),
            ]),
    );
  }
}

// ── LOCAL TAB ─────────────────────────────────────────────────────────────────
class _LocalTab extends StatelessWidget {
  final List<SessionModel> sessions;
  final VoidCallback onRefresh;
  const _LocalTab({required this.sessions, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.video_library_outlined, size: 52, color: _sub),
        SizedBox(height: 12),
        Text('No local recordings', style: TextStyle(color: _sub, fontSize: 15)),
        SizedBox(height: 4),
        Text('Record a video to see it here', style: TextStyle(color: _sub, fontSize: 12)),
      ]));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sessions.length,
      itemBuilder: (ctx, i) => _LocalCard(session: sessions[i], onRefresh: onRefresh),
    );
  }
}

class _LocalCard extends StatelessWidget {
  final SessionModel session;
  final VoidCallback onRefresh;
  const _LocalCard({required this.session, required this.onRefresh});

  String get _date => DateFormat('dd MMM yyyy, hh:mm a').format(session.createdAt);
  String get _dur {
    final m = session.durationSeconds ~/ 60;
    final s = session.durationSeconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }

  Color get _statusColor {
    switch (session.status) {
      case 'partial':   return Colors.orange;
      case 'uploading': return Colors.blue;
      default:          return _red;
    }
  }
  String get _statusLabel {
    switch (session.status) {
      case 'partial':   return '${session.uploadedBlocks.length}/${session.blockCount} uploaded';
      case 'uploading': return 'Uploading...';
      default:          return 'Not uploaded';
    }
  }

  @override
  Widget build(BuildContext context) {
    final canUpload = session.status == 'pending' || session.status == 'partial';
    final hasLocal  = session.localChunkPaths.isNotEmpty &&
        File(session.localChunkPaths.first).existsSync();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04),
            blurRadius: 8, offset: const Offset(0, 2))]),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_date, style: const TextStyle(
                color: _text, fontSize: 13, fontWeight: FontWeight.w600))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: _statusColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _statusColor.withOpacity(0.4))),
              child: Text(_statusLabel, style: TextStyle(
                  color: _statusColor, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _Meta(Icons.timer_outlined, _dur),
            const SizedBox(width: 14),
            _Meta(Icons.video_file_outlined,
                '${session.blockCount} block${session.blockCount != 1 ? 's' : ''}'),
          ]),
          if (session.isPartial) ...[
            const SizedBox(height: 8),
            ClipRRect(borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: session.uploadedBlocks.length / session.blockCount,
                minHeight: 4, backgroundColor: _border,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.orange))),
          ],
          const SizedBox(height: 12),
          Row(children: [
            // Preview button
            if (hasLocal) Expanded(child: OutlinedButton.icon(
              onPressed: () => _openPreview(context),
              icon: const Icon(Icons.play_circle_outline, size: 16),
              label: const Text('Preview'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _text, side: const BorderSide(color: _border),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            )),
            if (hasLocal && canUpload) const SizedBox(width: 8),
            // Upload button
            if (canUpload) Expanded(child: ElevatedButton.icon(
              onPressed: () async {
                await Navigator.push(context, MaterialPageRoute(
                  builder: (_) => UploadProgressScreen(session: session)));
                onRefresh();
              },
              icon: const Icon(Icons.cloud_upload, size: 16),
              label: Text(session.isPartial ? 'Resume' : 'Upload'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _green, foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            )),
            // Delete button — only for local pending sessions
            if (canUpload) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _confirmDelete(context),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _red.withValues(alpha: 0.3))),
                  child: const Icon(Icons.delete_outline, color: _red, size: 20),
                ),
              ),
            ],
          ]),
        ]),
      ),
    );
  }

  void _openPreview(BuildContext ctx) => Navigator.push(ctx, MaterialPageRoute(
    builder: (_) => _VideoPreviewScreen(
      chunkPaths: session.localChunkPaths,
      title: DateFormat('dd MMM yyyy').format(session.createdAt))));

  Future<void> _confirmDelete(BuildContext ctx) async {
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Delete local recording?'),
        content: const Text(
            'This will permanently delete the local video files. '
            'This cannot be undone. Upload first if you want to keep it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete', style: TextStyle(color: _red))),
        ],
      ),
    );
    if (confirmed != true) return;

    // Delete all local chunk files
    for (final path in session.localChunkPaths) {
      try { await File(path).delete(); } catch (_) {}
    }
    // Remove from session store
    await SessionStore().delete(session.id);
    onRefresh();
  }
}

// ── SYNCED TAB ────────────────────────────────────────────────────────────────
class _SyncedTab extends StatelessWidget {
  final List<SessionModel> sessions;
  const _SyncedTab({required this.sessions});

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.cloud_done_outlined, size: 52, color: _sub),
        SizedBox(height: 12),
        Text('No synced videos yet', style: TextStyle(color: _sub, fontSize: 15)),
        SizedBox(height: 4),
        Text('Upload a recording to see it here', style: TextStyle(color: _sub, fontSize: 12)),
      ]));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sessions.length,
      itemBuilder: (ctx, i) => _SyncedCard(session: sessions[i]),
    );
  }
}

class _SyncedCard extends StatelessWidget {
  final SessionModel session;
  const _SyncedCard({required this.session});

  String get _date => DateFormat('dd MMM yyyy, hh:mm a').format(session.createdAt);
  String get _dur {
    final m = session.durationSeconds ~/ 60;
    final s = session.durationSeconds % 60;
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _green.withOpacity(0.3)),
        boxShadow: [BoxShadow(color: _green.withOpacity(0.05),
            blurRadius: 8, offset: const Offset(0, 2))]),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(_date, style: const TextStyle(
                color: _text, fontSize: 13, fontWeight: FontWeight.w600))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: _green.withOpacity(0.1), borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _green.withOpacity(0.3))),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.cloud_done, size: 12, color: _green),
                SizedBox(width: 4),
                Text('Synced to OneDrive', style: TextStyle(color: _green,
                    fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _Meta(Icons.timer_outlined, _dur),
            const SizedBox(width: 14),
            _Meta(Icons.cloud_done_outlined,
                '${session.blockCount} block${session.blockCount != 1 ? 's' : ''}'),
          ]),
          const SizedBox(height: 12),
          Container(width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: _green.withOpacity(0.05), borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _green.withOpacity(0.15))),
            child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.cloud_done, size: 14, color: _green),
              SizedBox(width: 6),
              Text('Uploaded — local copy removed',
                  style: TextStyle(color: _green, fontSize: 12, fontWeight: FontWeight.w500)),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── VIDEO PREVIEW SCREEN ──────────────────────────────────────────────────────
class _VideoPreviewScreen extends StatefulWidget {
  final List<String> chunkPaths;
  final String title;
  const _VideoPreviewScreen({required this.chunkPaths, required this.title});
  @override
  State<_VideoPreviewScreen> createState() => _VideoPreviewScreenState();
}

class _VideoPreviewScreenState extends State<_VideoPreviewScreen> {
  VideoPlayerController? _vpc;
  int _chunk    = 0;
  bool _isInit  = false;
  bool _playing = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    // IMPORTANT: keep portrait, don't force landscape
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _load(0);
  }

  @override
  void dispose() {
    _vpc?.removeListener(_update);
    _vpc?.dispose();
    // restore normal orientations on exit
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    super.dispose();
  }

  Future<void> _load(int idx) async {
    if (idx >= widget.chunkPaths.length) return;
    setState(() { _isInit = false; _playing = false; });
    _vpc?.removeListener(_update);
    await _vpc?.dispose();

    final f = File(widget.chunkPaths[idx]);
    if (!await f.exists()) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Video file not found')));
      return;
    }

    _vpc = VideoPlayerController.file(f);
    await _vpc!.initialize();
    _vpc!.addListener(_update);
    if (mounted) setState(() { _isInit = true; _chunk = idx; _dur = _vpc!.value.duration; });
  }

  void _update() {
    if (!mounted || _vpc == null) return;
    final v = _vpc!.value;
    setState(() { _pos = v.position; _dur = v.duration; _playing = v.isPlaying; });
    if (v.position >= v.duration && v.duration > Duration.zero) {
      if (_chunk < widget.chunkPaths.length - 1) {
        _load(_chunk + 1).then((_) => _vpc?.play());
      }
    }
  }

  void _togglePlay() { _playing ? _vpc?.pause() : _vpc?.play(); }
  void _seek(Duration d) {
    final newSecs = (_pos + d).inSeconds.clamp(0, _dur.inSeconds);
    _vpc?.seekTo(Duration(seconds: newSecs));
  }
  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2,'0')}:${(d.inSeconds%60).toString().padLeft(2,'0')}';

  @override
  Widget build(BuildContext context) {
    final multi = widget.chunkPaths.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black, foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 15)),
        actions: [if (multi) Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Center(child: Text('Block ${_chunk+1}/${widget.chunkPaths.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 12))))],
      ),
      body: Column(children: [
        Expanded(child: _isInit && _vpc != null
          ? GestureDetector(onTap: _togglePlay,
              child: Center(child: AspectRatio(
                aspectRatio: _vpc!.value.aspectRatio,
                child: Stack(alignment: Alignment.center, children: [
                  VideoPlayer(_vpc!),
                  AnimatedOpacity(opacity: _playing ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 200),
                    child: Container(width: 64, height: 64,
                      decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                      child: const Icon(Icons.play_arrow, color: Colors.white, size: 36))),
                ]))))
          : const Center(child: CircularProgressIndicator(color: _green))),

        if (_isInit) ...[
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: VideoProgressIndicator(_vpc!, allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: _green, bufferedColor: Colors.white24,
                backgroundColor: Colors.white12))),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Text(_fmt(_pos), style: const TextStyle(color: Colors.white54, fontSize: 11)),
              const Spacer(),
              Text(_fmt(_dur), style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ])),
        ],

        Container(color: const Color(0xFF111111),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            if (multi) _Btn(Icons.skip_previous_rounded, 'Prev',
                _chunk > 0 ? () => _load(_chunk - 1) : null),
            _Btn(Icons.replay_10_rounded, '-10s', () => _seek(const Duration(seconds: -10))),
            GestureDetector(onTap: _isInit ? _togglePlay : null,
              child: Container(width: 60, height: 60,
                decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
                child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                    color: Colors.white, size: 30))),
            _Btn(Icons.forward_10_rounded, '+10s', () => _seek(const Duration(seconds: 10))),
            if (multi) _Btn(Icons.skip_next_rounded, 'Next',
                _chunk < widget.chunkPaths.length - 1 ? () => _load(_chunk + 1) : null),
          ])),

        if (multi) SizedBox(height: 48,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            itemCount: widget.chunkPaths.length,
            itemBuilder: (ctx, i) => GestureDetector(onTap: () => _load(i),
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: i == _chunk ? _green : Colors.white12,
                  borderRadius: BorderRadius.circular(20)),
                child: Text('Block ${i+1}', style: TextStyle(
                  color: i == _chunk ? Colors.white : Colors.white54,
                  fontSize: 12, fontWeight: FontWeight.w600)))))),

        const SizedBox(height: 8),
      ]),
    );
  }
}

class _Btn extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback? onTap;
  const _Btn(this.icon, this.label, this.onTap);
  @override
  Widget build(BuildContext ctx) => GestureDetector(onTap: onTap,
    child: Opacity(opacity: onTap == null ? 0.3 : 1.0,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: Colors.white, size: 28),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ])));
}

class _Meta extends StatelessWidget {
  final IconData icon; final String text;
  const _Meta(this.icon, this.text);
  @override
  Widget build(BuildContext ctx) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, size: 13, color: _sub),
    const SizedBox(width: 4),
    Text(text, style: const TextStyle(color: _sub, fontSize: 12)),
  ]);
}