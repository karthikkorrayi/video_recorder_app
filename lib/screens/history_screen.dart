import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/cloud_cache_service.dart';
import '../services/firestore_cache_service.dart';
import '../services/session_store.dart';
import '../services/onedrive_service.dart';
import '../widgets/chunk_popup.dart';
import '../widgets/network_banner.dart';

class HistoryScreen extends StatefulWidget {
  final DateFilter? initialFilter;
  const HistoryScreen({super.key, this.initialFilter});
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
  final _firestore = FirestoreCacheService();

  DateFilter _filter   = DateFilter.today;
  bool       _syncing  = false;
  bool       _isWifi   = true;
  bool       _hasNet   = true;
  StreamSubscription? _connSub;

  static const _meteredKey = 'upload_allow_metered';
  bool _allowMetered = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null) _filter = widget.initialFilter!;
    _checkNetwork();
    _listenNetwork();
    _loadMeteredPref();
    _cache.syncIfStale();
    // Trigger deletion sync on open so UI stays in sync with OneDrive
    _syncDeletionsForCurrentFilter();
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
    setState(() => _syncing = true);
    await OneDriveService.forceSync();
    await _cache.syncNow();
    // Sync deletions: remove Firestore sessions no longer on OneDrive
    await _syncDeletionsForCurrentFilter();
    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _syncDeletionsForCurrentFilter() async {
    if (!_hasNet) return;
    await _firestore.syncDeletionsFromOneDrive(dateFolders: _filterFolders());
  }

  // ── Attendance info — auto-updated on OneDrive ────────────────────────
  void _showAttendanceInfo() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),
          Container(width: 64, height: 64,
            decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(16)),
            child: const Icon(Icons.table_chart, color: _green, size: 36)),
          const SizedBox(height: 16),
          const Text('Attendance Excel — Auto Updated',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 8),
          Text('Updated automatically on every upload. Open on OneDrive:',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
                color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(10)),
            child: const Text(
              'OTN Recorder\nAttendance Reports\nOTN_Attendance.xlsx',
              textAlign: TextAlign.center,
              style: TextStyle(color: _green, fontWeight: FontWeight.w600, fontSize: 12))),
          const SizedBox(height: 8),
          Text('One sheet per date. All users. Includes start time + duration (with seconds).',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey[500], fontSize: 12)),
          const SizedBox(height: 20),
        ]),
      )),
    );
  }

    List<String> _filterFolders() {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime from, to;
    switch (_filter.type) {
      case FilterType.today:     from = to = today;
      case FilterType.yesterday: from = to = today.subtract(const Duration(days: 1));
      case FilterType.thisWeek:
        from = today.subtract(Duration(days: today.weekday - 1)); to = today;
      case FilterType.thisMonth:
        from = DateTime(now.year, now.month, 1); to = today;
      case FilterType.custom:
        from = _filter.from ?? today; to = _filter.to ?? today;
    }
    final out = <String>[]; var cur = from;
    while (!cur.isAfter(to)) {
      out.add('${cur.day.toString().padLeft(2,'0')}-'
          '${cur.month.toString().padLeft(2,'0')}-${cur.year}');
      cur = cur.add(const Duration(days: 1));
    }
    return out.take(30).toList();
  }

  @override
  void dispose() { _connSub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    appBar: AppBar(
      backgroundColor: Colors.white,
      foregroundColor: _text,
      elevation: 0,
      title: const Text('My Recordings', style: TextStyle(fontWeight: FontWeight.bold)),
      actions: [
        _syncing
            ? const Padding(padding: EdgeInsets.all(14),
                child: SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _green)))
            : IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () async {
                  setState(() => _syncing = true);
                  await _forceSync();
                }),
      ],
    ),
    body: NetworkBannerWrapper(
      child: RefreshIndicator(
        color: _green,
        onRefresh: _forceSync,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _sectionHeader(Icons.cloud_upload_outlined, 'Pending Uploads', _cache.lastSyncLabel),
            const SizedBox(height: 8),
            _buildUploadPanel(),
            const SizedBox(height: 20),
            _sectionHeader(Icons.cloud_done_outlined, 'Uploaded Sessions', _cache.lastSyncLabel),
            const SizedBox(height: 8),
            _buildFilterRow(),
            const SizedBox(height: 10),
            _buildFirestoreSessions(),
          ],
        ),
      ),
    ),
  );

  Widget _sectionHeader(IconData icon, String label, String syncLabel) =>
      Row(children: [
        Icon(icon, color: _green, size: 18), const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _text)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.cloud_done, color: _green, size: 12), const SizedBox(width: 4),
            Text(syncLabel, style: const TextStyle(color: _green, fontSize: 11)),
          ]),
        ),
      ]);

  // ── Compact filter row with popup calendar ────────────────────────────────
  Widget _buildFilterRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: [
      ...[DateFilter.today, DateFilter.yesterday, DateFilter.thisWeek, DateFilter.thisMonth]
          .map((f) => _FilterChip(
              label: f.label, selected: _filter.type == f.type,
              onTap: () { setState(() => _filter = f); _syncDeletionsForCurrentFilter(); })),
      Padding(
        padding: const EdgeInsets.only(left: 4),
        child: GestureDetector(
          onTap: _showCompactDatePicker,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: _filter.type == FilterType.custom ? _green : Colors.transparent,
                border: Border.all(color: _filter.type == FilterType.custom
                    ? _green : Colors.grey[300]!),
                borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.calendar_today, size: 14,
                  color: _filter.type == FilterType.custom ? Colors.white : Colors.grey[600]),
              if (_filter.type == FilterType.custom) ...[
                const SizedBox(width: 4),
                Text(_filter.label, style: const TextStyle(color: Colors.white, fontSize: 12)),
              ],
            ]),
          ),
        )),
    ]),
  );

  // ── Compact popup date picker (NOT fullscreen, allows multi-month) ─────────
  Future<void> _showCompactDatePicker() async {
    DateTime? from;
    DateTime? to;
    // Start with currently selected range if custom
    if (_filter.type == FilterType.custom) {
      from = _filter.from;
      to   = _filter.to;
    }

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => _CompactDateRangePicker(
        initialFrom: from,
        initialTo:   to,
        onApply: (f, t) {
          setState(() => _filter = DateFilter(FilterType.custom, from: f, to: t));
          _syncDeletionsForCurrentFilter();
        },
      ),
    );
  }

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
                        : _noWifiCard()),
              ]),
            ),
            Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _allowMetered ? _orange.withValues(alpha: 0.06) : Colors.grey[50],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _allowMetered
                        ? _orange.withValues(alpha: 0.3) : _border)),
                child: Row(children: [
                  Icon(Icons.signal_cellular_alt,
                      color: _allowMetered ? _orange : _grey, size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Allow cellular uploads', style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13,
                        color: _allowMetered ? _orange : _text)),
                    Text('Upload on mobile data when Wi-Fi unavailable',
                        style: TextStyle(fontSize: 10, color: Colors.grey[500])),
                  ])),
                  Switch(value: _allowMetered, onChanged: _saveMeteredPref,
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
                Expanded(child: _countTile(failed > 0 ? '$failed' : '✓',
                    failed > 0 ? 'Failed' : 'Synced',
                    failed > 0 ? _red : _green)),
              ]),
            ),
            if (globalHold) Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _red.withValues(alpha: 0.3))),
                child: const Row(children: [
                  Icon(Icons.pause_circle_outline, color: _red, size: 16), SizedBox(width: 8),
                  Expanded(child: Text('Upload paused — tap Retry All to continue',
                      style: TextStyle(color: _red, fontSize: 12, fontWeight: FontWeight.w600))),
                ]),
              ),
            ),
            if (grouped.isEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Row(children: [
                  const Icon(Icons.access_time, color: _grey, size: 18), const SizedBox(width: 8),
                  Text('No pending uploads', style: TextStyle(color: Colors.grey[500], fontSize: 13)),
                ]),
              )
            else ...[
              ...grouped.entries.map((e) => _buildSessionPanel(e.key, e.value)),
              const SizedBox(height: 8),
            ],
            if (failed > 0) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SizedBox(width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _queue.retryFailed,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry All Failed'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: _red, side: const BorderSide(color: _red)),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _buildSessionPanel(String sessionId, List<ChunkState> chunks) {
    final sid6      = sessionId.length >= 6 ? sessionId.substring(0, 6).toUpperCase() : sessionId;
    final uploading = chunks.where((c) => c.status == ChunkStatus.uploading).length;
    final failed    = chunks.where((c) => c.status == ChunkStatus.failed).length;
    final totalSecs = chunks.fold<int>(0, (s, c) => s + c.chunk.durationSecs);
    final hc        = failed > 0 ? _red : uploading > 0 ? _blue : _green;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      decoration: BoxDecoration(
          color: hc.withValues(alpha: 0.04), borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hc.withValues(alpha: 0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
              child: Text('Session $sid6',
                  style: TextStyle(color: hc, fontWeight: FontWeight.bold, fontSize: 11))),
            const SizedBox(width: 8),
            Text('${chunks.length} chunk${chunks.length == 1 ? '' : 's'}  ·  ${fmtDuration(totalSecs)}',
                style: TextStyle(color: Colors.grey[600], fontSize: 11)),
            const Spacer(),
            if (failed > 0)
              Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: _red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('$failed failed',
                    style: const TextStyle(color: _red, fontSize: 10, fontWeight: FontWeight.w600)))
            else if (uploading > 0)
              const Text('Uploading...', style: TextStyle(color: _blue, fontSize: 10)),
          ]),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Wrap(spacing: 5, runSpacing: 5, children: chunks.map(_buildRectBar).toList())),
      ]),
    );
  }

  Widget _buildRectBar(ChunkState cs) {
    final isUploading = cs.status == ChunkStatus.uploading;
    final isFailed    = cs.status == ChunkStatus.failed;
    final isOnHold    = cs.status == ChunkStatus.queued &&
        cs.message == 'On hold — waiting for failed chunk';
    final fill = isUploading ? _blue : isFailed ? _red : isOnHold ? _orange : const Color(0xFFBBBBBB);
    final pct  = isUploading ? cs.progress.clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      onTap: (cs.status == ChunkStatus.queued || cs.status == ChunkStatus.failed)
          ? () => _showChunkPopup(cs) : null,
      child: SizedBox(width: 48, height: 32,
        child: Stack(children: [
          Container(decoration: BoxDecoration(color: Colors.grey[200],
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: fill.withValues(alpha: 0.5)))),
          if (pct > 0) FractionallySizedBox(widthFactor: pct,
            child: Container(decoration: BoxDecoration(
                color: fill.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(7)))),
          Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('P${cs.chunk.partNumber}', style: TextStyle(fontSize: 9,
                fontWeight: FontWeight.bold, color: pct > 0.5 ? Colors.white : fill)),
            if (isUploading && cs.progress > 0)
              Text('${(cs.progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 7, color: pct > 0.5 ? Colors.white : _blue)),
            if (isOnHold) const Icon(Icons.pause, size: 8, color: _orange),
          ])),
        ]),
      ),
    );
  }

  void _showChunkPopup(ChunkState cs) {
    showModalBottomSheet(context: context, isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => ChunkPopup(cs: cs, queue: _queue));
  }

  // ── Firestore sessions (OneDrive-synced) ──────────────────────────────────
  // ── Uploaded sessions — sourced from Firestore (synced from OneDrive) ───────
  // Firestore is the cache of OneDrive state. _forceSync() keeps them in sync.
  // Using Firestore stream gives real-time updates without polling OneDrive every time.
  Widget _buildFirestoreSessions() {
    final col = FirestoreCacheService().sessionsCollection;
    if (col == null) return _buildEmptyCloud();

    final folders = _filterFolders();
    if (folders.isEmpty) return _buildEmptyCloud();

    // Deduplicate by sessionFolder to prevent duplicates from race conditions
    Stream<List<SessionMeta>> stream;
    if (folders.length == 1) {
      stream = col
          .where('dateFolder', isEqualTo: folders.first)
          .orderBy('sessionStartMs', descending: true)
          .snapshots()
          .map((s) => _dedup(s.docs
              .map((d) => SessionMeta.fromMap(d.id, d.data())).toList()));
    } else {
      stream = col
          .where('dateFolder', whereIn: folders)
          .orderBy('sessionStartMs', descending: true)
          .snapshots()
          .map((s) => _dedup(s.docs
              .map((d) => SessionMeta.fromMap(d.id, d.data())).toList()));
    }

    return StreamBuilder<List<SessionMeta>>(
      key: ValueKey(folders.join(',')),
      stream: stream,
      builder: (_, snap) {
        // Show loading only on initial connect, not on reconnect
        // (prevents "No sessions" flash when Firestore reconnects after offline)
        if (snap.connectionState == ConnectionState.waiting &&
            snap.data == null) {
          return const Center(child: Padding(padding: EdgeInsets.all(40),
              child: CircularProgressIndicator(color: _green)));
        }
        final sessions = snap.data ?? [];
        if (sessions.isEmpty) {
          // If we have an error (offline), show a reconnecting state rather than
          // "No sessions" — Firestore offline persistence may still have data
          if (snap.hasError || snap.connectionState == ConnectionState.waiting) {
            return _buildReconnecting();
          }
          return _buildEmptyCloud();
        }
        return Column(children: sessions.map(_buildFirestoreSessionCard).toList());
      },
    );
  }

  /// Deduplicate sessions by sessionFolder — keeps the most recently updated doc
  List<SessionMeta> _dedup(List<SessionMeta> sessions) {
    final seen = <String, SessionMeta>{};
    for (final s in sessions) {
      final key = s.sessionFolder.isNotEmpty ? s.sessionFolder : s.sessionId;
      if (!seen.containsKey(key)) seen[key] = s;
    }
    return seen.values.toList()
      ..sort((a, b) => b.sessionStartMs.compareTo(a.sessionStartMs));
  }

  Widget _buildFirestoreSessionCard(SessionMeta s) {
    final dur = fmtDuration(s.totalSecs);
    final sid = s.sessionId.length >= 6
        ? s.sessionId.substring(0, 6).toUpperCase() : s.sessionId;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(children: [
            Container(width: 28, height: 28,
              decoration: const BoxDecoration(color: Color(0xFFE8F5E9), shape: BoxShape.circle),
              child: const Icon(Icons.check, color: _green, size: 14)),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Session $sid',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              Text('${s.dateFolder}  ·  ${s.startTimeLabel}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 11, fontWeight: FontWeight.w500)),
              Text('${s.chunksUploaded} chunk${s.chunksUploaded == 1 ? '' : 's'}  ·  $dur',
                  style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('Synced ✓',
                  style: TextStyle(color: _green, fontSize: 10, fontWeight: FontWeight.w600))),
          ]),
        ),
        const Divider(height: 1),
        Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Wrap(spacing: 5, runSpacing: 5,
            children: List.generate(s.chunksUploaded, (i) {
              final partNum   = s.parts.length > i ? s.parts[i] : i + 1;
              final stored    = s.durationForPart(partNum);
              final chunkSecs = stored > 0 ? stored
                  : (s.chunksUploaded > 0 ? (s.totalSecs / s.chunksUploaded).round() : 0);
              return GestureDetector(
                onTap: () => _showFirestorePartDetail(partNum, fmtDuration(chunkSecs), s),
                child: Container(width: 48, height: 48,
                  decoration: BoxDecoration(color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _green.withValues(alpha: 0.3))),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.cloud_done, color: _green, size: 14),
                    const SizedBox(height: 2),
                    Text('$partNum', style: const TextStyle(
                        color: _green, fontWeight: FontWeight.bold, fontSize: 11)),
                    Text(fmtDuration(chunkSecs),
                        style: TextStyle(color: Colors.grey[600], fontSize: 9)),
                  ]),
                ),
              );
            }),
          ),
        ),
      ]),
    );
  }

  void _showFirestorePartDetail(int partNum, String dur, SessionMeta s) {
    showModalBottomSheet(context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(width: 40, height: 4, decoration: BoxDecoration(
            color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        const Icon(Icons.cloud_done, color: _green, size: 32), const SizedBox(height: 8),
        Text('Chunk $partNum', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        Text(s.sessionFolder, style: const TextStyle(fontSize: 12, color: _grey),
            textAlign: TextAlign.center),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _pill(Icons.timer_outlined, dur), const SizedBox(width: 12),
          _pill(Icons.cloud_done_outlined, 'Synced'),
        ]),
        const SizedBox(height: 20),
      ])),
    );
  }

  Widget _buildReconnecting() => Center(child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 40),
    child: Column(children: [
      const SizedBox(
        width: 32, height: 32,
        child: CircularProgressIndicator(strokeWidth: 2, color: _green)),
      const SizedBox(height: 16),
      Text('Reconnecting...', style: TextStyle(color: Colors.grey[500], fontSize: 14)),
      const SizedBox(height: 6),
      Text('Session data will appear shortly',
          style: TextStyle(color: Colors.grey[400], fontSize: 12)),
    ]),
  ));

  Widget _buildEmptyCloud() => Center(child: Padding(
    padding: const EdgeInsets.symmetric(vertical: 48),
    child: Column(children: [
      Icon(Icons.cloud_off, size: 64, color: Colors.grey[300]),
      const SizedBox(height: 16),
      Text('No synced sessions for ${_filter.label}',
          style: TextStyle(color: Colors.grey[500], fontSize: 15)),
      const SizedBox(height: 8),
      Text('Pull to refresh or change the filter',
          style: TextStyle(color: Colors.grey[400], fontSize: 13)),
    ]),
  ));

  Widget _noWifiCard() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
        color: _allowMetered
            ? _green.withValues(alpha: 0.06)
            : _orange.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _allowMetered
            ? _green.withValues(alpha: 0.4) : _orange.withValues(alpha: 0.4))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.signal_cellular_alt,
            color: _allowMetered ? _green : _orange, size: 16),
        const SizedBox(width: 6),
        Text('Mobile Data',
            style: TextStyle(
                color: _allowMetered ? _green : _orange,
                fontWeight: FontWeight.bold, fontSize: 13)),
      ]),
      const SizedBox(height: 4),
      Text(_allowMetered ? 'Uploads active' : 'Toggle below to enable',
          style: TextStyle(
              color: _allowMetered ? _green : _orange, fontSize: 10)),
    ]),
  );

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
              if (uploading) ...[
                const SizedBox(width: 6),
                SizedBox(width: 8, height: 8,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: _blue)),
              ],
            ]),
            const SizedBox(height: 6),
            Text('Upload Speed', style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            Text(speed, style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 14)),
          ]),
        );
      },
    );
  }

  Widget _statBox({required IconData icon, required String label,
      required String value, bool highlight = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: highlight ? _red.withValues(alpha: 0.08) : const Color(0xFFF8F8F8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: highlight ? _red.withValues(alpha: 0.3) : _border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: highlight ? _red : _grey, size: 18), const SizedBox(height: 6),
          Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
          Text(value, style: TextStyle(
              color: highlight ? _red : _text,
              fontWeight: FontWeight.bold, fontSize: 14)),
        ]),
      );

  Widget _countTile(String v, String l, Color c) => Column(children: [
    Text(v, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 22)),
    const SizedBox(height: 2),
    Text(l, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
  ]);

  Widget _pill(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _green, size: 14), const SizedBox(width: 4),
      Text(label, style: const TextStyle(color: _green, fontSize: 12, fontWeight: FontWeight.w600)),
    ]),
  );
}

// ── Compact date range picker popup ──────────────────────────────────────────
class _CompactDateRangePicker extends StatefulWidget {
  final DateTime? initialFrom;
  final DateTime? initialTo;
  final void Function(DateTime, DateTime) onApply;
  const _CompactDateRangePicker(
      {this.initialFrom, this.initialTo, required this.onApply});
  @override
  State<_CompactDateRangePicker> createState() => _CompactDateRangePickerState();
}

class _CompactDateRangePickerState extends State<_CompactDateRangePicker> {
  static const _green = Color(0xFF00C853);
  DateTime  _viewMonth = DateTime.now();
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _from      = widget.initialFrom;
    _to        = widget.initialTo;
    _viewMonth = DateTime(_from?.year ?? DateTime.now().year,
        _from?.month ?? DateTime.now().month);
  }

  void _prevMonth() => setState(() =>
      _viewMonth = DateTime(_viewMonth.year, _viewMonth.month - 1));
  void _nextMonth() => setState(() =>
      _viewMonth = DateTime(_viewMonth.year, _viewMonth.month + 1));

  void _tapDay(DateTime d) {
    setState(() {
      if (_from == null || (_from != null && _to != null)) {
        _from = d; _to = null;
      } else {
        if (d.isBefore(_from!)) { _to = _from; _from = d; }
        else { _to = d; }
      }
    });
  }

  bool _inRange(DateTime d) =>
      _from != null && _to != null &&
      !d.isBefore(_from!) && !d.isAfter(_to!);

  @override
  Widget build(BuildContext context) {
    final now        = DateTime.now();
    final firstDay   = DateTime(_viewMonth.year, _viewMonth.month, 1);
    final daysInMonth = DateTime(_viewMonth.year, _viewMonth.month + 1, 0).day;
    final startDow   = firstDay.weekday % 7; // 0=Sun
    final monthLabel = DateFormat('MMMM yyyy').format(_viewMonth);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Handle
          const SizedBox(height: 8),
          Container(width: 40, height: 4, decoration: BoxDecoration(
              color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),

          // Month navigation
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              IconButton(icon: const Icon(Icons.chevron_left), onPressed: _prevMonth),
              Expanded(child: Text(monthLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              IconButton(icon: const Icon(Icons.chevron_right),
                  onPressed: _viewMonth.isBefore(DateTime(now.year, now.month))
                      ? null : _nextMonth),
            ]),
          ),

          // Weekday header
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: ['Su','Mo','Tu','We','Th','Fr','Sa']
                .map((d) => Expanded(child: Center(
                  child: Text(d, style: TextStyle(fontSize: 12,
                      color: Colors.grey[500], fontWeight: FontWeight.w600)))))
                .toList()),
          ),
          const SizedBox(height: 4),

          // Calendar grid
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
            child: GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.1,
              children: [
                // Empty slots before first day
                ...List.generate(startDow, (_) => const SizedBox()),
                // Days
                ...List.generate(daysInMonth, (i) {
                  final day    = DateTime(_viewMonth.year, _viewMonth.month, i + 1);
                  final isFuture = day.isAfter(DateTime(now.year, now.month, now.day));
                  final isFrom = _from != null && day == _from;
                  final isTo   = _to != null && day == _to;
                  final inRange = _inRange(day);

                  return GestureDetector(
                    onTap: isFuture ? null : () => _tapDay(day),
                    child: Container(
                      margin: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: (isFrom || isTo) ? _green
                            : inRange ? _green.withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(child: Text('${i + 1}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: (isFrom || isTo) ? FontWeight.bold : FontWeight.normal,
                          color: (isFrom || isTo) ? Colors.white
                              : isFuture ? Colors.grey[300]
                              : Colors.black87,
                        ))),
                    ),
                  );
                }),
              ],
            ),
          ),

          // Selected range label
          if (_from != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _to != null
                    ? '${DateFormat('d MMM').format(_from!)} → ${DateFormat('d MMM yyyy').format(_to!)}'
                    : 'Select end date',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ),

          // Apply button
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: SizedBox(width: double.infinity,
              child: ElevatedButton(
                onPressed: (_from != null && _to != null)
                    ? () { Navigator.pop(context); widget.onApply(_from!, _to!); }
                    : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _green, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
          color: selected ? const Color(0xFF00C853) : Colors.transparent,
          border: Border.all(color: selected ? const Color(0xFF00C853) : Colors.grey[300]!),
          borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(
          color: selected ? Colors.white : Colors.grey[700],
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal, fontSize: 13)),
    ),
  );
}