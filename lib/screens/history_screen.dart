import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/cloud_cache_service.dart';
import '../services/firestore_cache_service.dart';
import '../widgets/network_banner.dart';
import '../widgets/chunk_popup.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _green  = Color(0xFF00C853);
  static const _red    = Colors.redAccent;
  static const _orange = Colors.orange;
  static const _blue   = Colors.blue;
  static const _bg     = Color(0xFFF5F5F5);
  static const _border = Color(0xFFE8E8E8);
  static const _text   = Color(0xFF1A1A1A);
  static const _grey   = Color(0xFF888888);

  final _queue     = ChunkUploadQueue();
  final _cache     = CloudCacheService();

  bool _syncing    = false;
  bool _refreshing = false; // full-screen loading overlay
  bool _isWifi     = true;
  bool _hasNet     = true;
  StreamSubscription? _connSub;
  // Key to force Firestore stream rebuild on refresh
  int  _streamKey  = 0;

  static const _meteredKey = 'upload_allow_metered';
  bool _allowMetered = false;

  @override
  void initState() {
    super.initState();
    _checkNetwork();
    _listenNetwork();
    _loadMeteredPref();
    _cache.syncIfStale();
  }

  Future<void> _loadMeteredPref() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _allowMetered = prefs.getBool(_meteredKey) ?? false);
  }

  Future<void> _saveMeteredPref(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_meteredKey, v);
    setState(() => _allowMetered = v);
    _queue.setMeteredAllowed(v);
  }

  void _checkNetwork() async {
    final r = await Connectivity().checkConnectivity();
    if (r.isNotEmpty) _setNet(r.first);
  }

  void _listenNetwork() {
    _connSub = Connectivity().onConnectivityChanged.listen((r) {
      if (r.isNotEmpty) _setNet(r.first);
    });
  }

  void _setNet(ConnectivityResult r) {
    if (!mounted) return;
    setState(() {
      _hasNet = r != ConnectivityResult.none;
      _isWifi = r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet;
    });
  }

  Future<void> _forceSync() async {
    if (!_hasNet) return;
    setState(() { _syncing = true; _refreshing = true; });
    try {
      // Full re-scan: re-reads all sessions from OneDrive → updates Firestore
      await FirestoreCacheService().forceRefreshFromOneDrive();
      // Mark sync timestamp so "Just now" label updates
      await _cache.syncNow();
      // Force fresh Firestore snapshot
      if (mounted) setState(() { _streamKey++; });
    } finally {
      if (mounted) setState(() { _syncing = false; _refreshing = false; });
    }
  }

  @override
  void dispose() { _connSub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_refreshing,
    child: Stack(children: [
      Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          foregroundColor: _text,
          elevation: 0,
          title: const Text('My Recordings',
              style: TextStyle(fontWeight: FontWeight.bold)),
          actions: [
            _syncing
                ? const Padding(padding: EdgeInsets.all(14),
                    child: SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: _green)))
                : IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () async {
                      setState(() => _syncing = true);
                      await _forceSync();
                    }),
          ],
        ),
        body: NetworkBannerWrapper(
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _sectionHeader(Icons.cloud_upload_outlined,
                  'Pending Uploads', _cache.lastSyncLabel),
              const SizedBox(height: 8),
              _buildUploadPanel(),
              const SizedBox(height: 20),
              _sectionHeader(Icons.cloud_done_outlined,
                  'Uploaded Sessions', _cache.lastSyncLabel),
              const SizedBox(height: 10),
              _buildFirestoreSessions(),
            ],
          ),
        ),
      ),
    // Full-screen sync overlay — blocks all navigation while refreshing
    if (_refreshing) Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 260,
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [BoxShadow(
                  color: _green.withValues(alpha: 0.15),
                  blurRadius: 24, spreadRadius: 2)],
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // OTN brand icon
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Center(child: Text('OTN',
                      style: TextStyle(color: _green,
                          fontWeight: FontWeight.bold, fontSize: 14))),
                ),
                const SizedBox(height: 20),
                const Text('Syncing Sessions',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 17,
                        letterSpacing: 0.2,
                        color: Color(0xFF111111))),
                const SizedBox(height: 6),
                const Text('Retrieving your session data...',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: Color(0xFF888888),
                        fontSize: 12,
                        height: 1.5)),
                const SizedBox(height: 18),
                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: const LinearProgressIndicator(
                    color: _green,
                    backgroundColor: Color(0xFFE8F5E9),
                    minHeight: 5,
                  ),
                ),
              ]),
            ),
          ],
        )),
      ),
    ),
    ]),
  );

  Widget _sectionHeader(IconData icon, String label, String syncLabel) =>
      Row(children: [
        Icon(icon, color: _green, size: 18), const SizedBox(width: 8),
        Text(label, style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 14, color: _text)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.cloud_done, color: _green, size: 12),
            const SizedBox(width: 4),
            Text(syncLabel,
                style: const TextStyle(color: _green, fontSize: 11)),
          ]),
        ),
      ]);

  // ── Upload panel ──────────────────────────────────────────────────────────
  Widget _buildUploadPanel() {
    return StreamBuilder<List<ChunkState>>(
      stream: _queue.stream,
      builder: (_, snap) {
        final uploading  = _queue.uploadingCount;
        final failed     = _queue.failedCount;
        final pending    = _queue.pendingCount;
        final globalHold = _queue.isGlobalHold;
        final grouped    = _queue.groupedBySesion;

        return Container(
          decoration: BoxDecoration(
              color: Colors.white, borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _border)),
          child: Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Row(children: [
                Expanded(child: _speedBox()),
                const SizedBox(width: 10),
                Expanded(child: _isWifi
                    ? _statBox(icon: Icons.wifi, label: 'Network', value: 'Wi-Fi')
                    : !_hasNet
                        ? _statBox(icon: Icons.wifi_off, label: 'Network',
                            value: 'No Network', highlight: true)
                        : _mobileDataBox()),
              ]),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _allowMetered
                        ? _orange.withValues(alpha: 0.06) : Colors.grey[50],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _allowMetered
                        ? _orange.withValues(alpha: 0.3) : _border)),
                child: Row(children: [
                  Icon(Icons.signal_cellular_alt,
                      color: _allowMetered ? _orange : _grey, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text('Allow cellular uploads', style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13,
                        color: _allowMetered ? _orange : _text)),
                    Text('Upload on mobile data when Wi-Fi unavailable',
                        style: TextStyle(fontSize: 10,
                            color: Colors.grey[500])),
                  ])),
                  Switch(
                    value: _allowMetered, onChanged: _saveMeteredPref,
                    activeThumbColor: _orange,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ]),
              ),
            ),
            const Divider(height: 20, indent: 14, endIndent: 14),
            Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: Row(children: [
                Expanded(child: _countTile('$pending', 'Pending',
                    pending > 0 ? _orange : _grey)),
                Expanded(child: _countTile('$uploading', 'Uploading',
                    uploading > 0 ? _blue : _grey)),
                Expanded(child: _countTile(
                    failed > 0 ? '$failed' : '✓',
                    failed > 0 ? 'Failed' : 'Synced',
                    failed > 0 ? _red : _green)),
              ]),
            ),
            if (globalHold) Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _red.withValues(alpha: 0.3))),
                child: const Row(children: [
                  Icon(Icons.pause_circle_outline, color: _red, size: 16),
                  SizedBox(width: 8),
                  Expanded(child: Text(
                      'Upload paused — tap Retry All to continue',
                      style: TextStyle(color: _red, fontSize: 12,
                          fontWeight: FontWeight.w600))),
                ]),
              ),
            ),
            if (grouped.isEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Row(children: [
                  const Icon(Icons.access_time, color: _grey, size: 18),
                  const SizedBox(width: 8),
                  Text('No pending uploads',
                      style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                ]),
              )
            else ...[
              ...grouped.entries.map((e) =>
                  _buildSessionPanel(e.key, e.value)),
              const SizedBox(height: 8),
            ],
            if (failed > 0) Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SizedBox(width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _queue.retryFailed,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry All Failed'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _red,
                      side: const BorderSide(color: _red)),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _speedBox() {
    return StreamBuilder<List<ChunkState>>(
      stream: _queue.stream,
      builder: (_, __) {
        final speed     = _queue.uploadSpeedLabel;
        final uploading = _queue.isUploading;
        final color     = uploading ? _blue : _grey;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
              color: uploading
                  ? _blue.withValues(alpha: 0.06)
                  : const Color(0xFFF8F8F8),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: uploading
                  ? _blue.withValues(alpha: 0.3) : _border)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.speed_outlined, color: color, size: 18),
              if (uploading) ...[const SizedBox(width: 6),
                SizedBox(width: 8, height: 8,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: _blue))],
            ]),
            const SizedBox(height: 6),
            Text('Upload Speed',
                style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            Text(speed, style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 14)),
          ]),
        );
      },
    );
  }

  Widget _mobileDataBox() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
        color: _allowMetered
            ? _green.withValues(alpha: 0.06)
            : _orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _allowMetered
            ? _green.withValues(alpha: 0.4)
            : _orange.withValues(alpha: 0.4))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.signal_cellular_alt,
            color: _allowMetered ? _green : _orange, size: 16),
        const SizedBox(width: 6),
        Text('Mobile Data', style: TextStyle(
            color: _allowMetered ? _green : _orange,
            fontWeight: FontWeight.bold, fontSize: 13)),
      ]),
      const SizedBox(height: 4),
      Text(_allowMetered ? 'Uploads active' : 'Toggle below to enable',
          style: TextStyle(
              color: _allowMetered ? _green : _orange, fontSize: 10)),
    ]),
  );

  Widget _buildSessionPanel(String sessionId, List<ChunkState> chunks) {
    final sid6      = sessionId.length >= 6
        ? sessionId.substring(0, 6).toUpperCase() : sessionId;
    final uploading = chunks.where(
        (c) => c.status == ChunkStatus.uploading).length;
    final failed    = chunks.where(
        (c) => c.status == ChunkStatus.failed).length;
    final totalSecs = chunks.fold<int>(
        0, (s, c) => s + c.chunk.durationSecs);
    final hc = failed > 0 ? _red : uploading > 0 ? _blue : _green;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      decoration: BoxDecoration(
          color: hc.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hc.withValues(alpha: 0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('Session $sid6', style: TextStyle(
                  color: hc, fontWeight: FontWeight.bold, fontSize: 11))),
            const SizedBox(width: 8),
            Text('${chunks.length} chunk${chunks.length == 1 ? '' : 's'}'
                '  ·  ${fmtDuration(totalSecs)}',
                style: TextStyle(color: Colors.grey[600], fontSize: 11)),
            const Spacer(),
            if (failed > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('$failed failed', style: const TextStyle(
                    color: _red, fontSize: 10, fontWeight: FontWeight.w600)))
            else if (uploading > 0)
              const Text('Uploading...',
                  style: TextStyle(color: _blue, fontSize: 10)),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Wrap(spacing: 5, runSpacing: 5,
              children: chunks.map(_buildRectBar).toList())),
      ]),
    );
  }

  Widget _buildRectBar(ChunkState cs) {
    final isDone      = cs.status == ChunkStatus.done;
    final isUploading = cs.status == ChunkStatus.uploading;
    final isFailed    = cs.status == ChunkStatus.failed;
    final isOnHold    = cs.status == ChunkStatus.queued &&
        cs.message == 'On hold — waiting for failed chunk';

    // Colour logic
    final Color fill = isDone      ? _green
        : isUploading              ? _blue
        : isFailed                 ? _red
        : isOnHold                 ? _orange
        : const Color(0xFFBBBBBB);

    // Fill fraction: done = 100%, uploading = live progress, others = 0
    final double pct = isDone      ? 1.0
        : isUploading              ? cs.progress.clamp(0.0, 1.0)
        : 0.0;

    final canTap = cs.chunk.hasAnyFile;

    return GestureDetector(
      onTap: canTap ? () => _showChunkPopup(cs) : null,
      child: SizedBox(width: 52, height: 38,
      child: Stack(children: [
        // ── Background ───────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: isDone ? _green.withValues(alpha: 0.1) : Colors.grey[100],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: fill.withValues(alpha: isDone ? 1.0 : 0.45),
              width: isDone ? 1.5 : 1.0,
            ),
          ),
        ),
        // ── Blue/fill progress bar (uploading only) ───────────────────
        if (!isDone && pct > 0)
          FractionallySizedBox(
            widthFactor: pct,
            child: Container(
              decoration: BoxDecoration(
                color: fill.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        // ── Label ────────────────────────────────────────────────────────
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isDone) ...[
                // Solid green tile: tick on top, part number below
                const Icon(Icons.check_circle, size: 13, color: _green),
                const SizedBox(height: 1),
                Text('P${cs.chunk.partNumber}',
                    style: const TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        color: _green)),
              ] else ...[
                Text('P${cs.chunk.partNumber}',
                    style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: pct > 0.5 ? Colors.white : fill)),
                if (isUploading && pct > 0)
                  Text('${(pct * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                          fontSize: 7,
                          color: pct > 0.5 ? Colors.white : _blue)),
                if (isOnHold)
                  const Icon(Icons.pause, size: 8, color: _orange),
              ],
            ],
          ),
        ),
      ]),
      ),
    );
  }

  void _showChunkPopup(ChunkState cs) {
    showModalBottomSheet(
      context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => ChunkPopup(cs: cs, queue: _queue));
  }

  // ── Uploaded Sessions — ALL sessions, no date filter ─────────────────────
  Widget _buildFirestoreSessions() {
    final col = FirestoreCacheService().sessionsCollection;
    if (col == null) return _buildReconnecting();

    // Show only today + yesterday — keeps list clean and focused
    // Full history is accessible via dashboard date filter
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterdayStart = today.subtract(const Duration(days: 1));
    final fromMs  = yesterdayStart.millisecondsSinceEpoch;
    final todayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59)
        .millisecondsSinceEpoch;

    // Only 'synced' sessions — 'uploading' stay in Pending Uploads
    // until ALL chunks of that session are confirmed on cloud storage
    // No .where('status') — that requires a composite index which doesn't exist.
    // Filter in Dart instead (fast for small date-range result sets).
    final stream = col
        .where('sessionStartMs', isGreaterThanOrEqualTo: fromMs)
        .where('sessionStartMs', isLessThanOrEqualTo: todayEnd)
        .orderBy('sessionStartMs', descending: true)
        .snapshots()
        .map((snap) {
          final synced = snap.docs
              .where((d) => (d.data()['status'] as String?) == 'synced')
              .map((d) => SessionMeta.fromMap(d.id, d.data()))
              .toList();
          return _dedup(synced);
        });

    return StreamBuilder<List<SessionMeta>>(
      // _streamKey forces a fresh Firestore query on each manual refresh
      // This fixes the issue where sessions appear erased after pull-to-refresh
      key: ValueKey(_streamKey),
      stream: stream,
      builder: (_, snap) {
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return _buildReconnecting();
        }
        if (snap.hasError) {
          debugPrint('=== Session stream error: \${snap.error}');
          return _buildStreamError();
        }
        final sessions = snap.data ?? [];
        if (sessions.isEmpty && !_refreshing) return _buildEmptyCloud();
        if (sessions.isEmpty) return _buildReconnecting();
        return Column(children: sessions.map(_buildSessionCard).toList());
      },
    );
  }

  List<SessionMeta> _dedup(List<SessionMeta> sessions) {
    final seen = <String, SessionMeta>{};
    for (final s in sessions) {
      final key = s.sessionFolder.isNotEmpty ? s.sessionFolder : s.sessionId;
      if (!seen.containsKey(key)) seen[key] = s;
    }
    return seen.values.toList()
      ..sort((a, b) => b.sessionStartMs.compareTo(a.sessionStartMs));
  }

  Widget _buildSessionCard(SessionMeta s) {
    final dur = fmtDuration(s.totalSecs);
    final sid = s.sessionId.length >= 6
        ? s.sessionId.substring(0, 6).toUpperCase() : s.sessionId;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(children: [
          Container(width: 28, height: 28,
            decoration: const BoxDecoration(
                color: Color(0xFFE8F5E9), shape: BoxShape.circle),
            child: const Icon(Icons.check, color: _green, size: 14)),
          const SizedBox(width: 10),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Session $sid', style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14)),
            Text('${s.dateFolder}  ·  ${s.startTimeLabel}',
                style: TextStyle(color: Colors.grey[600], fontSize: 11,
                    fontWeight: FontWeight.w500)),
            Text('${s.chunksUploaded} chunk${s.chunksUploaded == 1 ? '' : 's'}'
                '  ·  $dur',
                style: TextStyle(color: Colors.grey[500], fontSize: 11)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(8)),
            child: const Text('Synced ✓', style: TextStyle(
                color: _green, fontSize: 10,
                fontWeight: FontWeight.w600))),
        ]),
      ),
    );
  }

  Widget _buildStreamError() => Center(child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 32),
    child: Column(children: [
      Icon(Icons.sync_problem, size: 48, color: Colors.orange[400]),
      const SizedBox(height: 12),
      const Text('Could not load sessions',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: 6),
      const Text('Tap refresh to try again',
          style: TextStyle(color: Color(0xFF888888), fontSize: 13)),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        onPressed: () => setState(() => _streamKey++),
        icon: const Icon(Icons.refresh, size: 16),
        label: const Text('Retry'),
        style: OutlinedButton.styleFrom(
          foregroundColor: _green,
          side: const BorderSide(color: _green)),
      ),
    ]),
  ));

  Widget _buildReconnecting() => Center(child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(children: [
      const SizedBox(width: 32, height: 32,
        child: CircularProgressIndicator(strokeWidth: 2, color: _green)),
      const SizedBox(height: 16),
      Text('Loading sessions...',
          style: TextStyle(color: Colors.grey[500], fontSize: 14)),
    ]),
  ));

  Widget _buildEmptyCloud() => Center(child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(children: [
      Icon(Icons.cloud_off, size: 64, color: Colors.grey[300]),
      const SizedBox(height: 16),
      Text("No sessions for today or yesterday",
          style: TextStyle(color: Colors.grey[500], fontSize: 15)),
      const SizedBox(height: 8),
      Text('Use dashboard date filter to see older sessions',
          style: TextStyle(color: Colors.grey[400], fontSize: 13)),
    ]),
  ));

  Widget _statBox({required IconData icon, required String label,
      required String value, bool highlight = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: highlight ? _red.withValues(alpha: 0.08)
                : const Color(0xFFF8F8F8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: highlight
                ? _red.withValues(alpha: 0.3) : _border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: highlight ? _red : _grey, size: 18),
          const SizedBox(height: 6),
          Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
          Text(value, style: TextStyle(
              color: highlight ? _red : _text,
              fontWeight: FontWeight.bold, fontSize: 14)),
        ]),
      );

  Widget _countTile(String v, String l, Color c) =>
      Column(children: [
        Text(v, style: TextStyle(
            color: c, fontWeight: FontWeight.bold, fontSize: 22)),
        const SizedBox(height: 2),
        Text(l, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
      ]);
}