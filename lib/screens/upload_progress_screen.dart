import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/session_store.dart';
import '../services/chunk_upload_queue.dart';

// NOTE: UploadProgressScreen is kept for backward compatibility with any
// navigation that pushes it. Internally it now shows the ChunkUploadQueue
// state rather than the old UploadManager/UploadState API which no longer
// exists. If you do not use this screen, you can delete it safely.
//
// The primary upload UI is now in history_screen.dart (Pending Uploads panel).

class UploadProgressScreen extends StatefulWidget {
  // session parameter kept for API compat — not used internally anymore
  final SessionModel? session;
  const UploadProgressScreen({super.key, this.session});
  @override
  State<UploadProgressScreen> createState() => _UploadProgressScreenState();
}

class _UploadProgressScreenState extends State<UploadProgressScreen> {
  static const _green  = Color(0xFF00C853);
  static const _red    = Colors.redAccent;
  static const _orange = Colors.orange;
  static const _blue   = Colors.blue;
  static const _border = Color(0xFFE8E8E8);
  static const _text   = Color(0xFF1A1A1A);
  static const _grey   = Color(0xFF888888);

  final _queue = ChunkUploadQueue();
  bool _hasNetwork = true;
  StreamSubscription? _connSub;

  @override
  void initState() {
    super.initState();
    _checkNetwork();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final has = results.isNotEmpty &&
          results.any((r) => r != ConnectivityResult.none);
      if (mounted) setState(() => _hasNetwork = has);
    });
  }

  Future<void> _checkNetwork() async {
    final r = await Connectivity().checkConnectivity();
    if (mounted) {
      setState(() => _hasNetwork =
          r.isNotEmpty && r.any((r) => r != ConnectivityResult.none));
    }
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _text,
        elevation: 0,
        title: const Text('Upload Progress',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'View in History',
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/history');
            },
          ),
        ],
      ),
      body: StreamBuilder<List<ChunkState>>(
        stream: _queue.stream,
        builder: (_, snap) {
          final chunks    = snap.data ?? _queue.current;
          final pending   = _queue.pendingCount;
          final uploading = _queue.uploadingCount;
          final failed    = _queue.failedCount;
          final grouped   = _queue.groupedBySesion;

          if (chunks.isEmpty) {
            return Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_done, color: _green, size: 64),
                const SizedBox(height: 16),
                const Text('All uploads complete',
                    style: TextStyle(fontSize: 16,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Go Back'),
                ),
              ],
            ));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Network warning
              if (!_hasNetwork)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                      color: _red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _red.withValues(alpha: 0.3))),
                  child: const Row(children: [
                    Icon(Icons.wifi_off, color: _red, size: 16),
                    SizedBox(width: 8),
                    Text('No network — uploads paused',
                        style: TextStyle(color: _red,
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ]),
                ),

              // Summary row
              Row(children: [
                _countCard('$pending', 'Pending', _orange),
                const SizedBox(width: 8),
                _countCard('$uploading', 'Uploading', _blue),
                const SizedBox(width: 8),
                _countCard(failed > 0 ? '$failed' : '✓',
                    failed > 0 ? 'Failed' : 'Synced',
                    failed > 0 ? _red : _green),
              ]),
              const SizedBox(height: 16),

              // Hold banner
              if (_queue.isGlobalHold)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                      color: _red.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _red.withValues(alpha: 0.3))),
                  child: const Row(children: [
                    Icon(Icons.pause_circle_outline, color: _red, size: 16),
                    SizedBox(width: 8),
                    Expanded(child: Text(
                      'Upload paused — tap Retry All to continue',
                      style: TextStyle(color: _red,
                          fontWeight: FontWeight.w600, fontSize: 12))),
                  ]),
                ),

              // Per-session panels
              ...grouped.entries.map((e) => _sessionPanel(e.key, e.value)),

              const SizedBox(height: 12),

              // Retry All
              if (failed > 0)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _queue.retryFailed,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry All Failed'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: _red,
                        side: const BorderSide(color: _red),
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _countCard(String value, String label, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Column(children: [
        Text(value, style: TextStyle(
            color: color, fontSize: 22, fontWeight: FontWeight.bold)),
        Text(label, style: TextStyle(
            color: Colors.grey[600], fontSize: 11)),
      ]),
    ),
  );

  Widget _sessionPanel(String sessionId, List<ChunkState> chunks) {
    final sid6      = sessionId.length >= 6
        ? sessionId.substring(0, 6).toUpperCase() : sessionId;
    final uploading = chunks.where((c) => c.status == ChunkStatus.uploading).length;
    final failed    = chunks.where((c) => c.status == ChunkStatus.failed).length;
    final totalSecs = chunks.fold<int>(0, (s, c) => s + c.chunk.durationSecs);

    final Color hc = failed > 0 ? _red
        : uploading > 0 ? _blue : _green;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border)),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('Session $sid6',
                  style: TextStyle(color: hc,
                      fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            const SizedBox(width: 8),
            Text('${chunks.length} chunks  ·  ${fmtDuration(totalSecs)}',
                style: TextStyle(color: Colors.grey[600], fontSize: 11)),
            const Spacer(),
            if (failed > 0)
              Text('$failed failed',
                  style: const TextStyle(color: _red, fontSize: 10,
                      fontWeight: FontWeight.w600))
            else if (uploading > 0)
              const Text('Uploading...',
                  style: TextStyle(color: _blue, fontSize: 10)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          child: Wrap(spacing: 5, runSpacing: 5,
              children: chunks.map(_rectBar).toList()),
        ),
      ]),
    );
  }

  Widget _rectBar(ChunkState cs) {
    final isUp  = cs.status == ChunkStatus.uploading;
    final isFail = cs.status == ChunkStatus.failed;
    final Color fill = isUp ? _blue : isFail ? _red : _grey;
    final double pct  = isUp ? cs.progress.clamp(0.0, 1.0) : 0.0;

    return SizedBox(
      width: 48, height: 32,
      child: Stack(children: [
        Container(
          decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: fill.withValues(alpha: 0.5))),
        ),
        if (pct > 0)
          FractionallySizedBox(
            widthFactor: pct,
            child: Container(
              decoration: BoxDecoration(
                  color: fill.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(7)),
            ),
          ),
        Center(child: Text('P${cs.chunk.partNumber}',
            style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold,
                color: pct > 0.5 ? Colors.white : fill))),
      ]),
    );
  }
}