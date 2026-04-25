import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/cloud_cache_service.dart';
import '../services/session_store.dart';
import '../services/onedrive_service.dart';
import '../widgets/chunk_popup.dart'; // provides ChunkUploadQueue, ChunkState, ChunkStatus, fmtDuration, PendingChunk, ChunkPopup
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

  final _queue = ChunkUploadQueue();
  final _cache = CloudCacheService();

  DateFilter _filter   = DateFilter.today;
  bool       _syncing  = false;
  bool       _isWifi   = true;
  bool       _hasNet   = true;
  StreamSubscription? _connSub;

  // Issue 3: persistent cellular toggle
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
    _setNet(r.first);
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
    if (mounted) setState(() => _syncing = false);
  }

  @override
  void dispose() { _connSub?.cancel(); super.dispose(); }

  // ── Filter helpers ────────────────────────────────────────────────────────
  List<Map<String, dynamic>> get _filteredFiles {
    final now = DateTime.now();
    return _cache.files.where((f) {
      final dt = _parseFolderDate(f['dateFolder'] as String? ?? '');
      if (dt == null) return false;
      final d = DateTime(dt.year, dt.month, dt.day);
      switch (_filter.type) {
        case FilterType.today:
          return d == DateTime(now.year, now.month, now.day);
        case FilterType.yesterday:
          return d == DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 1));
        case FilterType.thisWeek:
          final s = DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: now.weekday - 1));
          return !d.isBefore(s) && d.isBefore(DateTime(now.year, now.month, now.day + 1));
        case FilterType.thisMonth:
          return dt.year == now.year && dt.month == now.month;
        case FilterType.custom:
          if (_filter.from == null || _filter.to == null) return false;
          return !d.isBefore(_filter.from!) && !d.isAfter(_filter.to!);
      }
    }).toList();
  }

  Map<String, List<Map<String, dynamic>>> get _groupedSessions =>
      _cache.groupedSessions(_filteredFiles);

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _text,
        elevation: 0,
        title: const Text('My Recordings',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          _syncing
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _green)))
              : IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _forceSync),
        ],
      ),
      body: NetworkBannerWrapper(
        child: RefreshIndicator(
          color: _green,
          onRefresh: _forceSync,
          child: ListView(
            padding: const EdgeInsets.all(12),
            children: [
              // ── Pending Uploads ────────────────────────────────────────
              _sectionHeader(
                  Icons.cloud_upload_outlined,
                  'Pending Uploads',
                  _cache.lastSyncLabel),
              const SizedBox(height: 8),
              _buildUploadPanel(),
              const SizedBox(height: 20),

              // ── Uploaded Sessions ──────────────────────────────────────
              _sectionHeader(
                  Icons.cloud_done_outlined,
                  'Uploaded Sessions',
                  _cache.lastSyncLabel),
              const SizedBox(height: 8),
              _buildFilterRow(),
              const SizedBox(height: 10),

              StreamBuilder<CacheState>(
                stream: _cache.stream,
                builder: (_, __) {
                  final sessions = _groupedSessions;
                  if (sessions.isEmpty && _cache.isSyncing) {
                    return const Center(
                      child: Padding(padding: EdgeInsets.all(40),
                        child: Column(children: [
                          CircularProgressIndicator(color: _green),
                          SizedBox(height: 12),
                          Text('Syncing from OneDrive...',
                              style: TextStyle(color: Colors.grey, fontSize: 13)),
                        ])));
                  }
                  if (sessions.isEmpty) return _buildEmptyCloud();
                  // Issue 4: latest first (already sorted in groupedSessions)
                  return Column(
                    children: sessions.entries
                        .map((e) => _buildSessionCard(e.key, e.value))
                        .toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionHeader(IconData icon, String label, String syncLabel) =>
      Row(children: [
        Icon(icon, color: _green, size: 18),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 14, color: _text)),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.cloud_done, color: _green, size: 12),
            const SizedBox(width: 4),
            Text(syncLabel,
                style: const TextStyle(color: _green, fontSize: 11)),
          ]),
        ),
      ]);

  // ── Upload panel (per-session + cellular toggle) ───────────────────────────
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
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _border)),
          child: Column(children: [

            // Speed + Network/Cellular
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Row(children: [
                Expanded(child: _statBox(
                    icon: Icons.upload_outlined,
                    label: 'Speed',
                    value: uploading > 0 ? 'Active' : 'Idle')),
                const SizedBox(width: 10),
                Expanded(child: _isWifi
                    ? _statBox(icon: Icons.wifi, label: 'Network',
                        value: 'Wi-Fi')
                    : !_hasNet
                        ? _statBox(icon: Icons.wifi_off, label: 'Network',
                            value: 'No Network', highlight: true)
                        : _noWifiCard()),
              ]),
            ),

            // Issue 3: Cellular toggle row — permanent
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _allowMetered
                        ? _orange.withValues(alpha: 0.06)
                        : Colors.grey[50],
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _allowMetered
                            ? _orange.withValues(alpha: 0.3)
                            : _border)),
                child: Row(children: [
                  Icon(Icons.signal_cellular_alt,
                      color: _allowMetered ? _orange : _grey,
                      size: 16),
                  const SizedBox(width: 8),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Allow cellular uploads',
                          style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                              color: _allowMetered ? _orange : _text)),
                      Text('Upload on mobile data when Wi-Fi unavailable',
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey[500])),
                    ],
                  )),
                  Switch(
                    value: _allowMetered,
                    onChanged: _saveMeteredPref,
                    activeThumbColor: _orange,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ]),
              ),
            ),

            const Divider(height: 20, indent: 14, endIndent: 14),

            // Counts
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: Row(children: [
                Expanded(child: _countTile('$pending', 'Pending',
                    pending > 0 ? _orange : _grey)),
                Expanded(child: _countTile('$uploading', 'Uploading',
                    uploading > 0 ? _blue : _grey)),
                Expanded(child: _countTile(
                    failed > 0 ? '$failed' : '\u2713',
                    failed > 0 ? 'Failed' : 'Synced',
                    failed > 0 ? _red : _green)),
              ]),
            ),

            // Global hold banner
            if (globalHold)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: _red.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: _red.withValues(alpha: 0.3))),
                  child: const Row(children: [
                    Icon(Icons.pause_circle_outline,
                        color: _red, size: 16),
                    SizedBox(width: 8),
                    Expanded(child: Text(
                      'Upload paused — tap Retry All to continue',
                      style: TextStyle(
                          color: _red,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    )),
                  ]),
                ),
              ),

            // Per-session chunk panels
            if (grouped.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Row(children: [
                  const Icon(Icons.access_time, color: _grey, size: 18),
                  const SizedBox(width: 8),
                  Text('No pending uploads',
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 13)),
                ]),
              )
            else ...[
              ...grouped.entries.map(
                  (e) => _buildSessionPanel(e.key, e.value)),
              const SizedBox(height: 8),
            ],

            // Retry All
            if (failed > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: SizedBox(
                  width: double.infinity,
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

  Widget _buildSessionPanel(String sessionId, List<ChunkState> chunks) {
    final sid6      = sessionId.length >= 6
        ? sessionId.substring(0, 6).toUpperCase() : sessionId;
    final uploading = chunks.where((c) => c.status == ChunkStatus.uploading).length;
    final failed    = chunks.where((c) => c.status == ChunkStatus.failed).length;
    final totalSecs = chunks.fold<int>(0, (s, c) => s + c.chunk.durationSecs);

    final Color hc = failed > 0 ? _red
        : uploading > 0 ? _blue : _green;

    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      decoration: BoxDecoration(
          color: hc.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hc.withValues(alpha: 0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: Colors.black87,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('Session $sid6',
                  style: TextStyle(color: hc,
                      fontWeight: FontWeight.bold, fontSize: 11)),
            ),
            const SizedBox(width: 8),
            Text('${chunks.length} chunk${chunks.length == 1 ? '' : 's'}'
                '  ·  ${fmtDuration(totalSecs)}',
                style: TextStyle(color: Colors.grey[600], fontSize: 11)),
            const Spacer(),
            if (failed > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('$failed failed',
                    style: const TextStyle(
                        color: _red, fontSize: 10,
                        fontWeight: FontWeight.w600)),
              )
            else if (uploading > 0)
              const Text('Uploading...',
                  style: TextStyle(color: _blue, fontSize: 10)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Wrap(spacing: 5, runSpacing: 5,
              children: chunks.map(_buildRectBar).toList()),
        ),
      ]),
    );
  }

  // Issue 4: 48×32 rectangle bars — compact
  Widget _buildRectBar(ChunkState cs) {
    final isUploading = cs.status == ChunkStatus.uploading;
    final isFailed    = cs.status == ChunkStatus.failed;
    final isOnHold    = cs.status == ChunkStatus.queued &&
        cs.message == 'On hold — waiting for failed chunk';

    final Color fill = isUploading ? _blue
        : isFailed ? _red
        : isOnHold ? _orange
        : const Color(0xFFBBBBBB);
    final double pct = isUploading
        ? cs.progress.clamp(0.0, 1.0) : 0.0;

    return GestureDetector(
      onTap: (cs.status == ChunkStatus.queued ||
              cs.status == ChunkStatus.failed)
          ? () => _showChunkPopup(cs)
          : null,
      child: SizedBox(
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
          Center(child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('P${cs.chunk.partNumber}',
                  style: TextStyle(
                      fontSize: 9, fontWeight: FontWeight.bold,
                      color: pct > 0.5 ? Colors.white : fill)),
              if (isUploading && cs.progress > 0)
                Text('${(cs.progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 7,
                        color: pct > 0.5 ? Colors.white : _blue)),
              if (isOnHold)
                Icon(Icons.pause, size: 8, color: _orange),
            ],
          )),
        ]),
      ),
    );
  }

  void _showChunkPopup(ChunkState cs) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => ChunkPopup(cs: cs, queue: _queue),
    );
  }

  Widget _noWifiCard() => GestureDetector(
    onTap: () => _queue.showMeteredConnectionDialog(context),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
          color: _orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _orange.withValues(alpha: 0.5))),
      child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.wifi_off, color: _orange, size: 16),
          SizedBox(width: 6),
          Text('No Wi-Fi',
              style: TextStyle(color: _orange,
                  fontWeight: FontWeight.bold, fontSize: 13)),
        ]),
        SizedBox(height: 4),
        Text('Tap to configure',
            style: TextStyle(color: _orange, fontSize: 10)),
      ]),
    ),
  );

  Widget _statBox({required IconData icon, required String label,
      required String value, bool highlight = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
            color: highlight ? _red.withValues(alpha: 0.08) : const Color(0xFFF8F8F8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: highlight ? _red.withValues(alpha: 0.3) : _border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: highlight ? _red : _grey, size: 18),
          const SizedBox(height: 6),
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

  // ── Filter row ────────────────────────────────────────────────────────────
  Widget _buildFilterRow() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(children: [
      ...[DateFilter.today, DateFilter.yesterday,
          DateFilter.thisWeek, DateFilter.thisMonth]
          .map((f) => _FilterChip(
              label: f.label,
              selected: _filter.type == f.type,
              onTap: () => setState(() => _filter = f))),
      Padding(padding: const EdgeInsets.only(left: 4),
        child: GestureDetector(
          onTap: _pickCustomRange,
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: _filter.type == FilterType.custom
                    ? _green : Colors.transparent,
                border: Border.all(
                    color: _filter.type == FilterType.custom
                        ? _green : Colors.grey[300]!),
                borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.calendar_today, size: 14,
                  color: _filter.type == FilterType.custom
                      ? Colors.white : Colors.grey[600]),
              if (_filter.type == FilterType.custom) ...[
                const SizedBox(width: 4),
                Text(_filter.label,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 12)),
              ],
            ]),
          ),
        )),
    ]),
  );

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, 1),
      lastDate: DateTime(now.year, now.month + 1, 0),
      builder: (ctx, child) => Theme(
          data: Theme.of(ctx).copyWith(
              colorScheme: const ColorScheme.light(primary: _green)),
          child: child!),
    );
    if (picked != null && mounted) {
      setState(() => _filter = DateFilter(FilterType.custom,
          from: picked.start, to: picked.end));
    }
  }

  // ── Issue 4: Compact session card — smaller chunk boxes ───────────────────
  Widget _buildSessionCard(
      String sessionKey, List<Map<String, dynamic>> parts) {
    parts.sort((a, b) =>
        (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''));

    final sid        = sessionKey.length >= 6
        ? sessionKey.substring(0, 6).toUpperCase() : sessionKey;
    final dateFolder = parts.isNotEmpty
        ? (parts.first['dateFolder'] as String? ?? '') : '';
    final totalBytes = parts.fold<int>(
        0, (s, p) => s + ((p['size'] as int?) ?? 0));
    final totalMb    = (totalBytes / 1024 / 1024).toStringAsFixed(0);
    final totalSecs  = parts.fold(0,
        (s, p) => s + CloudCacheService.parseFileSecs(
            p['name'] as String? ?? ''));
    final dur = fmtDuration(totalSecs);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Header row — compact
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(children: [
            // Small green check circle
            Container(
              width: 28, height: 28,
              decoration: const BoxDecoration(
                  color: Color(0xFFE8F5E9),
                  shape: BoxShape.circle),
              child: const Icon(Icons.check, color: _green, size: 14),
            ),
            const SizedBox(width: 10),
            Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              Text('Session $sid',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
              // Issue 4: compact subtitle with all info inline
              Text(
                '$dateFolder  ·  ${parts.length} chunk${parts.length == 1 ? '' : 's'}'
                '  ·  $dur  ·  $totalMb MB',
                style: TextStyle(
                    color: Colors.grey[500], fontSize: 11)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(8)),
              child: const Text('Synced \u2713',
                  style: TextStyle(
                      color: _green, fontSize: 10,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        ),

        const Divider(height: 1),

        // Issue 4: smaller 48×48 chunk boxes, tight spacing
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Wrap(spacing: 5, runSpacing: 5,
            children: List.generate(parts.length, (i) {
              final p       = parts[i];
              final name    = p['name'] as String? ?? '';
              final sizeMb  = ((p['size'] as int? ?? 0) / 1024 / 1024)
                  .toStringAsFixed(0);
              final partSecs = CloudCacheService.parseFileSecs(name);
              final pdur     = fmtDuration(partSecs);

              return GestureDetector(
                onTap: () => _showPartDetail(i + 1, name, sizeMb, pdur),
                child: Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _green.withValues(alpha: 0.3))),
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                    const Icon(Icons.cloud_done,
                        color: _green, size: 14),
                    const SizedBox(height: 2),
                    Text('${i + 1}',
                        style: const TextStyle(
                            color: _green,
                            fontWeight: FontWeight.bold,
                            fontSize: 11)),
                    Text(pdur,
                        style: TextStyle(
                            color: Colors.grey[600], fontSize: 9)),
                  ]),
                ),
              );
            }),
          ),
        ),
      ]),
    );
  }

  void _showPartDetail(int n, String fileName, String sizeMb, String dur) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),
          const Icon(Icons.cloud_done, color: _green, size: 32),
          const SizedBox(height: 8),
          Text('Chunk $n',
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(fileName,
                style: const TextStyle(fontSize: 12, color: _grey),
                textAlign: TextAlign.center)),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _pill(Icons.timer_outlined, dur),
            const SizedBox(width: 12),
            _pill(Icons.storage_outlined, '$sizeMb MB'),
            const SizedBox(width: 12),
            _pill(Icons.cloud_done_outlined, 'Synced'),
          ]),
          const SizedBox(height: 20),
        ]),
      ),
    );
  }

  Widget _pill(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _green, size: 14),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(
          color: _green, fontSize: 12, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _buildEmptyCloud() => Center(
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(children: [
        Icon(Icons.cloud_off, size: 64, color: Colors.grey[300]),
        const SizedBox(height: 16),
        Text('No synced sessions for ${_filter.label}',
            style: TextStyle(color: Colors.grey[500], fontSize: 15)),
        const SizedBox(height: 8),
        Text('Pull to refresh or change the filter',
            style: TextStyle(color: Colors.grey[400], fontSize: 13)),
      ]),
    ),
  );

  DateTime? _parseFolderDate(String folder) {
    final parts = folder.split('-');
    if (parts.length != 3) return null;
    try {
      return DateTime(int.parse(parts[2]),
          int.parse(parts[1]), int.parse(parts[0]));
    } catch (_) { return null; }
  }
}

class _FilterChip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
          color: selected ? const Color(0xFF00C853) : Colors.transparent,
          border: Border.all(
              color: selected
                  ? const Color(0xFF00C853) : Colors.grey[300]!),
          borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(
          color: selected ? Colors.white : Colors.grey[700],
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          fontSize: 13)),
    ),
  );
}