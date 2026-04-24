import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../services/chunk_upload_queue.dart';
import '../services/cloud_cache_service.dart';
import '../services/session_store.dart';
import '../widgets/chunk_popup.dart';
import '../services/onedrive_service.dart';

class HistoryScreen extends StatefulWidget {
  final DateFilter? initialFilter;
  const HistoryScreen({super.key, this.initialFilter});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const _green  = Color(0xFF00C853);
  static const _blue   = Colors.blue;
  static const _orange = Colors.orange;
  static const _red    = Colors.redAccent;
  static const _bg     = Color(0xFFF5F5F5);
  static const _border = Color(0xFFE8E8E8);
  static const _text   = Color(0xFF1A1A1A);
  static const _grey   = Color(0xFF888888);

  final _queue = ChunkUploadQueue();
  final _cache = CloudCacheService();

  DateFilter _filter  = DateFilter.today;
  String     _network = 'Wi-Fi';
  bool       _isWifi  = true;
  bool       _syncing = false;
  StreamSubscription? _connSub;

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null) _filter = widget.initialFilter!;
    _checkNetwork();
    _listenNetwork();
    _cache.syncIfStale();
  }

  void _checkNetwork() async {
    final r = await Connectivity().checkConnectivity();
    _setNetwork(r.first);
  }

  void _listenNetwork() {
    _connSub = Connectivity().onConnectivityChanged.listen((r) {
      if (r.isNotEmpty) _setNetwork(r.first);
    });
  }

  void _setNetwork(ConnectivityResult r) {
    if (!mounted) return;
    setState(() {
      _isWifi  = r == ConnectivityResult.wifi || r == ConnectivityResult.ethernet;
      _network = _isWifi ? 'Wi-Fi'
               : r == ConnectivityResult.mobile ? 'Cellular'
               : r == ConnectivityResult.none   ? 'None'
               : 'Other';
    });
  }

  Future<void> _forceSync() async {
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
          return d == DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
        case FilterType.thisWeek:
          final s = DateTime(now.year, now.month, now.day).subtract(Duration(days: now.weekday - 1));
          return !d.isBefore(s) && d.isBefore(DateTime(now.year, now.month, now.day + 1));
        case FilterType.thisMonth:
          return dt.year == now.year && dt.month == now.month;
        case FilterType.custom:
          if (_filter.from == null || _filter.to == null) return false;
          return !d.isBefore(_filter.from!) && !d.isAfter(_filter.to!);
      }
    }).toList();
  }

  // Issue 3: use CloudCacheService.groupedSessions which sorts latest first
  Map<String, List<Map<String, dynamic>>> get _groupedSessions =>
      _cache.groupedSessions(_filteredFiles);

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.white, foregroundColor: _text, elevation: 0,
        title: const Text('My Recordings', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          _syncing
              ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: _green)))
              : IconButton(icon: const Icon(Icons.refresh), onPressed: _forceSync),
        ],
      ),
      body: RefreshIndicator(
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
            StreamBuilder<CacheState>(
              stream: _cache.stream,
              builder: (_, __) {
                final sessions = _groupedSessions;
                if (sessions.isEmpty && _cache.isSyncing) {
                  return const Center(child: Padding(padding: EdgeInsets.all(40),
                    child: Column(children: [
                      CircularProgressIndicator(color: _green),
                      SizedBox(height: 12),
                      Text('Syncing from OneDrive...', style: TextStyle(color: Colors.grey, fontSize: 13)),
                    ])));
                }
                if (sessions.isEmpty) return _buildEmptyCloud();
                return Column(children: sessions.entries.map((e) => _buildSessionCard(e.key, e.value)).toList());
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(IconData icon, String label, String syncLabel) => Row(children: [
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

  // ── Issue 4+5: Upload panel ───────────────────────────────────────────────

  Widget _buildUploadPanel() {
    return StreamBuilder<List<ChunkState>>(
      stream: _queue.stream,
      builder: (_, snap) {
        final uploading   = _queue.uploadingCount;
        final failed      = _queue.failedCount;
        final pending     = _queue.pendingCount;
        final globalHold  = _queue.isGlobalHold;
        final grouped     = _queue.groupedBySesion; // Map<sessionId, List<ChunkState>>
 
        return Container(
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE8E8E8))),
          child: Column(children: [
 
            // ── Speed + Network ──────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Row(children: [
                Expanded(child: _statBox(
                    icon: Icons.upload_outlined,
                    label: 'Speed',
                    value: uploading > 0 ? 'Active' : 'Idle')),
                const SizedBox(width: 10),
                Expanded(child: _isWifi
                    ? _statBox(icon: Icons.wifi, label: 'Network', value: 'Wi-Fi')
                    : _noWifiAlert()),
              ]),
            ),
 
            const Divider(height: 20, indent: 14, endIndent: 14),
 
            // ── Counts row ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: Row(children: [
                Expanded(child: _countTile('$pending', 'Pending',
                    pending > 0 ? Colors.orange : const Color(0xFF888888))),
                Expanded(child: _countTile('$uploading', 'Uploading',
                    uploading > 0 ? Colors.blue : const Color(0xFF888888))),
                Expanded(child: _countTile(
                    failed > 0 ? '$failed' : '\u2713',
                    failed > 0 ? 'Failed' : 'Synced',
                    failed > 0 ? Colors.redAccent : const Color(0xFF00C853))),
              ]),
            ),
 
            // ── Global hold banner ────────────────────────────────────────
            if (globalHold)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.red.withValues(alpha: 0.3))),
                  child: Row(children: [
                    const Icon(Icons.pause_circle_outline,
                        color: Colors.redAccent, size: 16),
                    const SizedBox(width: 8),
                    const Expanded(child: Text(
                      'Upload paused — tap Retry All to continue',
                      style: TextStyle(
                          color: Colors.redAccent,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    )),
                  ]),
                ),
              ),
 
            // ── Issue 3: Per-session chunk panels ─────────────────────────
            if (grouped.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Row(children: [
                  const Icon(Icons.access_time,
                      color: Color(0xFF888888), size: 18),
                  const SizedBox(width: 8),
                  Text('No pending uploads',
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 13)),
                ]),
              )
            else
              ...grouped.entries.map((entry) =>
                  _buildSessionPanel(entry.key, entry.value)),
 
            // ── Retry All button ──────────────────────────────────────────
            if (failed > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _queue.retryFailed,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retry All Failed'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                        side: const BorderSide(color: Colors.redAccent)),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }

  Widget _buildSessionPanel(String sessionId, List<ChunkState> chunks) {
    final sid6       = sessionId.length >= 6
        ? sessionId.substring(0, 6).toUpperCase()
        : sessionId.toUpperCase();
    final uploading  = chunks.where((c) => c.status == ChunkStatus.uploading).length;
    final failed     = chunks.where((c) => c.status == ChunkStatus.failed).length;
    final done       = chunks.where((c) => c.status == ChunkStatus.done).length;
    final totalSecs  = chunks.fold(0, (s, c) => s + c.chunk.durationSecs);
 
    final Color headerColor = failed > 0 ? Colors.redAccent
        : uploading > 0 ? Colors.blue
        : const Color(0xFF00C853);
 
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      decoration: BoxDecoration(
          color: headerColor.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: headerColor.withValues(alpha: 0.25))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
 
        // Session header
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6)),
              child: Text('Session $sid6',
                  style: TextStyle(
                      color: headerColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 11)),
            ),
            const SizedBox(width: 8),
            Text('${chunks.length} chunk${chunks.length == 1 ? '' : 's'}  ·  '
                '${fmtDuration(totalSecs)}',
                style: TextStyle(
                    color: Colors.grey[600], fontSize: 11)),
            const Spacer(),
            if (failed > 0)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8)),
                child: Text('$failed failed',
                    style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 10,
                        fontWeight: FontWeight.w600)),
              )
            else if (uploading > 0)
              Text('Uploading...',
                  style: const TextStyle(
                      color: Colors.blue, fontSize: 10)),
          ]),
        ),
 
        // Chunk rectangle bars
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          child: Wrap(
            spacing: 6, runSpacing: 6,
            children: chunks.map((cs) => _buildRectBar(cs)).toList(),
          ),
        ),
      ]),
    );
  }

  // Issue 4: No Wi-Fi alert card replaces Network box
  Widget _noWifiAlert() => GestureDetector(
    onTap: () => _queue.approveCellular(context),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: Colors.orange.withValues(alpha: 0.5))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.wifi_off, color: Colors.orange, size: 16),
          SizedBox(width: 6),
          Text('No Wi-Fi',
              style: TextStyle(
                  color: Colors.orange,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
        ]),
        const SizedBox(height: 4),
        const Text('Tap to use cellular',
            style: TextStyle(color: Colors.orange, fontSize: 10)),
      ]),
    ),
  );

  // Issue 5: Rectangle fill bars — each chunk = small rounded rect that fills left→right
  Widget _buildRectangleBars(List<ChunkState> chunks) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: chunks.map((cs) => _buildRectBar(cs)).toList(),
    );
  }

  Widget _buildRectBar(ChunkState cs) {
    final isUploading = cs.status == ChunkStatus.uploading;
    final isFailed    = cs.status == ChunkStatus.failed;
    final isQueued    = cs.status == ChunkStatus.queued;
    final isOnHold    = isQueued &&
        cs.message == 'On hold — waiting for failed chunk';
 
    final Color fillColor = isUploading ? Colors.blue
        : isFailed    ? Colors.redAccent
        : isOnHold    ? Colors.orange
        : isQueued    ? const Color(0xFFBBBBBB)
        : const Color(0xFF00C853);
 
    final double fillPct = isUploading
        ? cs.progress.clamp(0.0, 1.0)
        : isFailed || isQueued ? 0.0
        : 1.0;
 
    final bool canTap = isQueued || isFailed;
 
    return GestureDetector(
      onTap: canTap ? () => _showChunkPopup(cs) : null,
      child: SizedBox(
        width: 56, height: 36,
        child: Stack(children: [
          // Background
          Container(
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: fillColor.withValues(alpha: 0.5), width: 1.2),
            ),
          ),
          // Fill left→right
          if (fillPct > 0)
            FractionallySizedBox(
              widthFactor: fillPct,
              child: Container(
                decoration: BoxDecoration(
                  color: fillColor.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          // Label
          Center(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
              Text('P${cs.chunk.partNumber}',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: fillPct > 0.5
                          ? Colors.white
                          : fillColor)),
              if (isUploading && cs.progress > 0)
                Text('${(cs.progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                        fontSize: 8,
                        color: fillPct > 0.5
                            ? Colors.white
                            : Colors.blue)),
              if (isOnHold)
                const Icon(Icons.pause, size: 10,
                    color: Colors.orange),
            ]),
          ),
        ]),
      ),
    );
  }

  // Issue 6: Chunk popup with video preview thumbnail for queued chunks only
  void _showChunkPopup(ChunkState cs) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => ChunkPopup(cs: cs, queue: _queue),
    );
  }

  Widget _statBox({required IconData icon, required String label, required String value, bool highlight = false}) =>
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: highlight ? _orange.withValues(alpha: 0.08) : const Color(0xFFF8F8F8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: highlight ? _orange.withValues(alpha: 0.3) : _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: highlight ? _orange : _grey, size: 18),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
        Text(value, style: TextStyle(color: highlight ? _orange : _text, fontWeight: FontWeight.bold, fontSize: 14)),
      ]),
    );

  Widget _countTile(String v, String l, Color c) => Column(children: [
    Text(v, style: TextStyle(color: c, fontWeight: FontWeight.bold, fontSize: 22)),
    const SizedBox(height: 2),
    Text(l, style: TextStyle(color: Colors.grey[500], fontSize: 11)),
  ]);

  // ── Filter row ────────────────────────────────────────────────────────────

  Widget _buildFilterRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        ...[DateFilter.today, DateFilter.yesterday, DateFilter.thisWeek, DateFilter.thisMonth]
            .map((f) => _FilterChip(label: f.label, selected: _filter.type == f.type, onTap: () => setState(() => _filter = f))),
        Padding(padding: const EdgeInsets.only(left: 4), child: GestureDetector(
          onTap: _pickCustomRange,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _filter.type == FilterType.custom ? _green : Colors.transparent,
              border: Border.all(color: _filter.type == FilterType.custom ? _green : Colors.grey[300]!),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.calendar_today, size: 14, color: _filter.type == FilterType.custom ? Colors.white : Colors.grey[600]),
              if (_filter.type == FilterType.custom) ...[const SizedBox(width: 4), Text(_filter.label, style: const TextStyle(color: Colors.white, fontSize: 12))],
            ]),
          ),
        )),
      ]),
    );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, 1),
      lastDate: DateTime(now.year, now.month + 1, 0),
      builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(colorScheme: const ColorScheme.light(primary: _green)), child: child!),
    );
    if (picked != null && mounted) setState(() => _filter = DateFilter(FilterType.custom, from: picked.start, to: picked.end));
  }

  // ── Session card ──────────────────────────────────────────────────────────

  Widget _buildSessionCard(String sessionKey, List<Map<String, dynamic>> parts) {
    final sessionId  = sessionKey.length >= 6 ? sessionKey.substring(0, 6).toUpperCase() : sessionKey;
    final dateFolder = parts.isNotEmpty ? (parts.first['dateFolder'] as String? ?? '') : '';
    final totalBytes = parts.fold<int>(0, (s, p) => s + ((p['size'] as int?) ?? 0));
    final totalMb    = (totalBytes / 1024 / 1024).toStringAsFixed(0);

    // Issue 1: total duration in seconds, formatted with seconds when < 1min
    final totalSecs  = parts.fold(0, (s, p) => s + CloudCacheService.parseFileSecs(p['name'] as String? ?? ''));
    final durationStr = fmtDuration(totalSecs);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: _border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.cloud_done, color: _green, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Session $sessionId', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              Text('$dateFolder  ·  ${parts.length} chunk${parts.length == 1 ? '' : 's'}  ·  $durationStr  ·  $totalMb MB',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12)),
            ])),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(8)),
              child: const Text('Synced \u2713', style: TextStyle(color: _green, fontSize: 11, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),

        const Divider(height: 1),

        // Chunk boxes
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 8, runSpacing: 8,
            children: List.generate(parts.length, (i) {
              final p        = parts[i];
              final name     = p['name'] as String? ?? '';
              final sizeMb   = ((p['size'] as int? ?? 0) / 1024 / 1024).toStringAsFixed(0);
              final partSecs = CloudCacheService.parseFileSecs(name);
              final dur      = fmtDuration(partSecs);

              return GestureDetector(
                onTap: () => _showPartDetail(i + 1, name, sizeMb, dur),
                child: Container(
                  width: 64,
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _green.withValues(alpha: 0.3)),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.cloud_done, color: _green, size: 18),
                    const SizedBox(height: 4),
                    Text('${i + 1}', style: const TextStyle(color: _green, fontWeight: FontWeight.bold, fontSize: 12)),
                    Text(dur, style: TextStyle(color: Colors.grey[600], fontSize: 10)),
                    Text('$sizeMb MB', style: TextStyle(color: Colors.grey[500], fontSize: 9)),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        const Icon(Icons.cloud_done, color: _green, size: 32),
        const SizedBox(height: 8),
        Text('Chunk $n', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 4),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(fileName, style: const TextStyle(fontSize: 12, color: _grey), textAlign: TextAlign.center)),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          _pill(Icons.timer_outlined, dur),
          const SizedBox(width: 12),
          _pill(Icons.storage_outlined, '$sizeMb MB'),
          const SizedBox(width: 12),
          _pill(Icons.cloud_done_outlined, 'Synced'),
        ]),
        const SizedBox(height: 20),
      ])),
    );
  }

  Widget _pill(IconData icon, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _green, size: 14), const SizedBox(width: 4),
      Text(label, style: const TextStyle(color: _green, fontSize: 12, fontWeight: FontWeight.w600)),
    ]),
  );

  Widget _buildEmptyCloud() => Center(
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 48), child: Column(children: [
      Icon(Icons.cloud_off, size: 64, color: Colors.grey[300]),
      const SizedBox(height: 16),
      Text('No synced sessions for ${_filter.label}', style: TextStyle(color: Colors.grey[500], fontSize: 15)),
      const SizedBox(height: 8),
      Text('Pull to refresh or change the filter', style: TextStyle(color: Colors.grey[400], fontSize: 13)),
    ])),
  );

  DateTime? _parseFolderDate(String folder) {
    final parts = folder.split('-');
    if (parts.length != 3) return null;
    try { return DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0])); } catch (_) { return null; }
  }
}

// ── Issue 6: Chunk popup with video thumbnail ─────────────────────────────────

class _ChunkPopup extends StatefulWidget {
  final ChunkState cs;
  final ChunkUploadQueue queue;
  const _ChunkPopup({required this.cs, required this.queue});
  @override
  State<_ChunkPopup> createState() => _ChunkPopupState();
}

class _ChunkPopupState extends State<_ChunkPopup> {
  static const _green = Color(0xFF00C853);
  static const _red   = Colors.redAccent;

  Uint8List? _thumb;
  bool       _loadingThumb = true;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    final file = File(widget.cs.chunk.filePath);
    if (!await file.exists()) {
      if (mounted) setState(() => _loadingThumb = false);
      return;
    }
    try {
      final thumb = await VideoThumbnail.thumbnailData(
        video:   widget.cs.chunk.filePath,
        imageFormat:  ImageFormat.JPEG,
        maxWidth: 400,
        quality: 75,
      );
      if (mounted) setState(() { _thumb = thumb; _loadingThumb = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingThumb = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs        = widget.cs;
    final isFailed  = cs.status == ChunkStatus.failed;
    final dur       = fmtDuration(cs.chunk.durationSecs);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Drag handle
          Center(child: Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 12),

          // Video preview
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: SizedBox(
              width: double.infinity, height: 160,
              child: _loadingThumb
                  ? Container(color: Colors.grey[200], child: const Center(child: CircularProgressIndicator(color: _green)))
                  : _thumb != null
                      ? Stack(fit: StackFit.expand, children: [
                          Image.memory(_thumb!, fit: BoxFit.cover),
                          Center(child: Container(
                            width: 48, height: 48,
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), shape: BoxShape.circle),
                            child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                          )),
                        ])
                      : Container(
                          color: const Color(0xFF1A1A1A),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            const Icon(Icons.video_file_outlined, color: Colors.white54, size: 48),
                            const SizedBox(height: 8),
                            Text('P${cs.chunk.partNumber}  ·  $dur',
                                style: const TextStyle(color: Colors.white70, fontSize: 13)),
                          ]),
                        ),
            ),
          ),
          const SizedBox(height: 12),

          // Filename + duration
          Text(cs.chunk.cloudFileName,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.timer_outlined, size: 13, color: Colors.grey[500]),
            const SizedBox(width: 4),
            Text(dur, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            const SizedBox(width: 12),
            Icon(isFailed ? Icons.error_outline : Icons.hourglass_empty,
                size: 13, color: isFailed ? _red : Colors.orange),
            const SizedBox(width: 4),
            Text(cs.message, style: TextStyle(color: isFailed ? _red : Colors.orange, fontSize: 12)),
          ]),
          const SizedBox(height: 16),

          // Action buttons
          Row(children: [
            // Retry (always shown for queued/failed)
            Expanded(child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                widget.queue.retryChunk(cs.chunk);
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry Upload'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _green,
                side: const BorderSide(color: _green),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            )),
            const SizedBox(width: 12),
            // Delete
            Expanded(child: OutlinedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete chunk?'),
                    content: const Text('Removes from queue and deletes local cache file.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                      TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete', style: TextStyle(color: _red))),
                    ],
                  ),
                );
                if (ok == true) widget.queue.abandonChunk(cs.chunk.filePath);
              },
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _red,
                side: const BorderSide(color: _red),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            )),
          ]),
        ]),
      ),
    );
  }
}

// ── Filter chip ───────────────────────────────────────────────────────────────

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
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(color: selected ? Colors.white : Colors.grey[700], fontWeight: selected ? FontWeight.w600 : FontWeight.normal, fontSize: 13)),
    ),
  );
}