import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/chunk_upload_queue.dart';
import '../services/cloud_cache_service.dart';
import '../services/session_store.dart';
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

  DateFilter _filter   = DateFilter.today;
  String     _network  = 'Wi-Fi';
  bool       _syncing  = false;

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
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.isNotEmpty) _setNetwork(results.first);
    });
  }

  void _setNetwork(ConnectivityResult r) {
    if (!mounted) return;
    setState(() {
      _network = r == ConnectivityResult.wifi     ? 'Wi-Fi'
               : r == ConnectivityResult.mobile   ? 'Cellular'
               : r == ConnectivityResult.ethernet ? 'Ethernet'
               : 'None';
    });
  }

  Future<void> _forceSync() async {
    setState(() => _syncing = true);
    await OneDriveService.forceSync();
    await _cache.syncNow();
    if (mounted) setState(() => _syncing = false);
  }

  @override
  void dispose() {
    _connSub?.cancel();
    super.dispose();
  }

  // ── Filter helpers ────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _filteredFiles {
    final files = _cache.files;
    final now   = DateTime.now();
    return files.where((f) {
      final folder = f['dateFolder'] as String? ?? '';
      final dt     = _parseFolderDate(folder);
      if (dt == null) return false;
      final d = DateTime(dt.year, dt.month, dt.day);
      switch (_filter.type) {
        case FilterType.today:
          return d == DateTime(now.year, now.month, now.day);
        case FilterType.yesterday:
          return d == DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 1));
        case FilterType.thisWeek:
          final start = DateTime(now.year, now.month, now.day)
              .subtract(Duration(days: now.weekday - 1));
          return !d.isBefore(start) &&
              d.isBefore(DateTime(now.year, now.month, now.day + 1));
        case FilterType.thisMonth:
          return dt.year == now.year && dt.month == now.month;
        case FilterType.custom:
          if (_filter.from == null || _filter.to == null) return false;
          return !d.isBefore(_filter.from!) && !d.isAfter(_filter.to!);
      }
    }).toList();
  }

  /// Group by sessionFolder, sorted recent first (by folder name desc)
  Map<String, List<Map<String, dynamic>>> get _groupedSessions {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final f in _filteredFiles) {
      final key = (f['sessionFolder'] as String?)?.isNotEmpty == true
          ? f['sessionFolder'] as String
          : (f['dateFolder'] as String? ?? 'Unknown');
      result.putIfAbsent(key, () => []).add(f);
    }
    // Sort: recent first (folder names are date-sortable)
    final sorted = result.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return Map.fromEntries(sorted);
  }

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
                  child: SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: _green)))
              : IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _forceSync,
                  tooltip: 'Sync with OneDrive',
                ),
        ],
      ),
      body: RefreshIndicator(
        color: _green,
        onRefresh: _forceSync,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // ── SECTION 1: Pending Uploads ─────────────────────────────
            _sectionHeader(
              icon: Icons.cloud_upload_outlined,
              label: 'Pending Uploads',
              syncLabel: _cache.lastSyncLabel,
            ),
            const SizedBox(height: 8),
            _buildUploadPanel(),
            const SizedBox(height: 20),

            // ── SECTION 2: Uploaded Sessions ───────────────────────────
            _sectionHeader(
              icon: Icons.cloud_done_outlined,
              label: 'Uploaded Sessions',
              syncLabel: _cache.lastSyncLabel,
            ),
            const SizedBox(height: 8),
            _buildFilterRow(),
            const SizedBox(height: 10),
            StreamBuilder<CacheState>(
              stream: _cache.stream,
              builder: (_, __) {
                final sessions = _groupedSessions;
                if (_cache.isSyncing && _cache.files.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(40),
                      child: CircularProgressIndicator(color: _green),
                    ),
                  );
                }
                if (sessions.isEmpty) return _buildEmptyCloud();
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
    );
  }

  // ── Section header ────────────────────────────────────────────────────────

  Widget _sectionHeader({
    required IconData icon,
    required String label,
    required String syncLabel,
  }) =>
      Row(children: [
        Icon(icon, color: _green, size: 18),
        const SizedBox(width: 8),
        Text(label,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 14, color: _text)),
        const Spacer(),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

  // ── SECTION 1: Upload panel ───────────────────────────────────────────────

  Widget _buildUploadPanel() {
    return StreamBuilder<List<ChunkState>>(
      stream: _queue.stream,
      builder: (_, snap) {
        final chunks    = snap.data ?? _queue.current;
        final pending   = _queue.pendingCount;
        final uploading = _queue.uploadingCount;
        final failed    = _queue.failedCount;

        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _border),
          ),
          child: Column(children: [
            // Speed + Network
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
              child: Row(children: [
                Expanded(child: _statBox(
                  icon: Icons.upload_outlined,
                  label: 'Speed',
                  value: uploading > 0 ? 'Active' : 'Idle',
                )),
                const SizedBox(width: 10),
                Expanded(child: _statBox(
                  icon: _network == 'Wi-Fi' ? Icons.wifi
                      : _network == 'Cellular'
                          ? Icons.signal_cellular_alt
                          : Icons.wifi_off,
                  label: 'Network',
                  value: _network,
                  highlight: _network == 'Cellular',
                )),
              ]),
            ),
            const Divider(height: 20, indent: 14, endIndent: 14),

            // Pending / Uploading / Synced counts
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              child: Row(children: [
                Expanded(child: _countTile(
                    '$pending', 'Pending',
                    pending > 0 ? _orange : _grey)),
                Expanded(child: _countTile(
                    '$uploading', 'Uploading',
                    uploading > 0 ? _blue : _grey)),
                Expanded(child: _countTile(
                    failed > 0 ? '$failed' : '✓',
                    failed > 0 ? 'Failed' : 'Synced',
                    failed > 0 ? _red : _green)),
              ]),
            ),

            // ── BLOCK BUBBLE GRID ────────────────────────────────────
            if (chunks.isNotEmpty) ...[
              const Divider(height: 20, indent: 14, endIndent: 14),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                child: _buildBubbleGrid(chunks),
              ),
            ],

            // No pending state
            if (chunks.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
                child: Row(children: [
                  const Icon(Icons.access_time, color: _grey, size: 18),
                  const SizedBox(width: 8),
                  Text('No pending uploads',
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 13)),
                ]),
              ),

            // Retry failed button
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
                      side: const BorderSide(color: _red),
                    ),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }

  /// Block bubble grid — numbered squares colored by status.
  /// Tap = popup with Delete / Retry options.
  Widget _buildBubbleGrid(List<ChunkState> chunks) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: chunks.map((cs) => _buildBubble(cs)).toList(),
    );
  }

  Widget _buildBubble(ChunkState cs) {
    final isUploading = cs.status == ChunkStatus.uploading;
    final isFailed    = cs.status == ChunkStatus.failed;
    final isQueued    = cs.status == ChunkStatus.queued;

    final Color bg = isUploading
        ? _blue.withValues(alpha: 0.12)
        : isFailed
            ? _red.withValues(alpha: 0.12)
            : Colors.grey[100]!;

    final Color border = isUploading
        ? _blue.withValues(alpha: 0.5)
        : isFailed
            ? _red.withValues(alpha: 0.5)
            : Colors.grey[300]!;

    return GestureDetector(
      onTap: () => _showChunkMenu(cs),
      child: Container(
        width: 72,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status icon / spinner
            SizedBox(
              width: 28, height: 28,
              child: isUploading
                  ? CircularProgressIndicator(
                      value: cs.progress > 0 ? cs.progress : null,
                      strokeWidth: 2.5,
                      color: _blue)
                  : isFailed
                      ? const Icon(Icons.error_outline,
                          color: _red, size: 24)
                      : isQueued
                          ? const Icon(Icons.hourglass_empty,
                              color: _grey, size: 24)
                          : const Icon(Icons.cloud_done,
                              color: _green, size: 24),
            ),
            const SizedBox(height: 4),
            // Part number
            Text('P${cs.chunk.partNumber}',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isUploading
                        ? _blue
                        : isFailed
                            ? _red
                            : _grey)),
            // Progress % when uploading
            if (isUploading && cs.progress > 0)
              Text('${(cs.progress * 100).toStringAsFixed(0)}%',
                  style:
                      const TextStyle(fontSize: 10, color: _blue)),
          ],
        ),
      ),
    );
  }

  /// Tap popup on a chunk bubble — shows Delete and Retry options.
  void _showChunkMenu(ChunkState cs) {
    final isFailed = cs.status == ChunkStatus.failed;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                cs.chunk.cloudFileName,
                style: const TextStyle(
                    fontSize: 12, color: _grey),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                cs.message,
                style: TextStyle(
                    fontSize: 13,
                    color: isFailed ? _red : _blue,
                    fontWeight: FontWeight.w500),
              ),
            ),
            const Divider(height: 24),
            if (isFailed)
              ListTile(
                leading: const Icon(Icons.refresh, color: _green),
                title: const Text('Retry Upload'),
                onTap: () {
                  Navigator.pop(context);
                  _queue.retryChunk(cs.chunk);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: _red),
              title: const Text('Delete from Queue',
                  style: TextStyle(color: _red)),
              onTap: () async {
                Navigator.pop(context);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete chunk?'),
                    content: const Text(
                        'This removes the chunk from the upload queue. '
                        'The local cache file will also be deleted.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete',
                              style: TextStyle(color: _red))),
                    ],
                  ),
                );
                if (confirm == true) {
                  _queue.abandonChunk(cs.chunk.filePath);
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _statBox({
    required IconData icon,
    required String label,
    required String value,
    bool highlight = false,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: highlight
              ? _orange.withValues(alpha: 0.08)
              : const Color(0xFFF8F8F8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: highlight
                  ? _orange.withValues(alpha: 0.3)
                  : _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: highlight ? _orange : _grey, size: 18),
            const SizedBox(height: 6),
            Text(label,
                style: TextStyle(color: Colors.grey[500], fontSize: 11)),
            Text(value,
                style: TextStyle(
                    color: highlight ? _orange : _text,
                    fontWeight: FontWeight.bold,
                    fontSize: 14)),
          ],
        ),
      );

  Widget _countTile(String value, String label, Color color) =>
      Column(children: [
        Text(value,
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 22)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(color: Colors.grey[500], fontSize: 11)),
      ]);

  // ── Filter row ────────────────────────────────────────────────────────────

  Widget _buildFilterRow() {
    final chips = [
      DateFilter.today,
      DateFilter.yesterday,
      DateFilter.thisWeek,
      DateFilter.thisMonth,
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          ...chips.map((f) => _FilterChip(
                label: f.label,
                selected: _filter.type == f.type,
                onTap: () => setState(() => _filter = f),
              )),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: GestureDetector(
              onTap: _pickCustomRange,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _filter.type == FilterType.custom
                      ? _green
                      : Colors.transparent,
                  border: Border.all(
                      color: _filter.type == FilterType.custom
                          ? _green
                          : Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.calendar_today,
                      size: 14,
                      color: _filter.type == FilterType.custom
                          ? Colors.white
                          : Colors.grey[600]),
                  if (_filter.type == FilterType.custom) ...[
                    const SizedBox(width: 4),
                    Text(_filter.label,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 12)),
                  ],
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, 1),
      lastDate: DateTime(now.year, now.month + 1, 0),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.light(primary: _green)),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _filter = DateFilter(FilterType.custom,
          from: picked.start, to: picked.end));
    }
  }

  // ── Session card (grouped — all parts under ONE card) ─────────────────────

  Widget _buildSessionCard(
      String sessionKey, List<Map<String, dynamic>> parts) {
    // Sort parts by name (part01, part02, part03...)
    parts.sort((a, b) =>
        (a['name'] as String? ?? '').compareTo(b['name'] as String? ?? ''));

    // Parse session ID — first 6 chars of folder name
    final sessionId = sessionKey.length >= 6
        ? sessionKey.substring(0, 6).toUpperCase()
        : sessionKey;

    final dateFolder = parts.isNotEmpty
        ? (parts.first['dateFolder'] as String? ?? '')
        : '';

    final totalBytes = parts.fold<int>(
        0, (s, p) => s + ((p['size'] as int?) ?? 0));
    final totalMb = (totalBytes / 1024 / 1024).toStringAsFixed(0);

    final duration = _parseTotalDuration(
        parts.map((p) => p['name'] as String? ?? '').toList());

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Session header
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Container(
                width: 42, height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child:
                    const Icon(Icons.cloud_done, color: _green, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Session $sessionId',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    Text(
                      '$dateFolder  ·  ${parts.length} part${parts.length == 1 ? '' : 's'}  ·  $totalMb MB',
                      style: TextStyle(
                          color: Colors.grey[500], fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Synced ✓',
                    style: TextStyle(
                        color: _green,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
          ),

          // Duration row
          if (duration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 66, bottom: 8),
              child: Row(children: [
                const Icon(Icons.videocam_outlined,
                    size: 14, color: _grey),
                const SizedBox(width: 4),
                Text(duration,
                    style: TextStyle(
                        color: Colors.grey[600], fontSize: 12)),
              ]),
            ),

          const Divider(height: 1),

          // Parts list
          ...List.generate(parts.length, (i) {
            final p      = parts[i];
            final name   = p['name'] as String? ?? '';
            final sizeMb = ((p['size'] as int? ?? 0) / 1024 / 1024)
                .toStringAsFixed(0);
            final partDur = _parsePartDuration(name);

            return Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: i < parts.length - 1
                  ? BoxDecoration(
                      border: Border(
                          bottom: BorderSide(color: _border)))
                  : null,
              child: Row(children: [
                Container(
                  width: 30, height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('P${i + 1}',
                      style: const TextStyle(
                          color: _green,
                          fontSize: 11,
                          fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(name,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 8),
                Text(
                  '$sizeMb MB${partDur.isNotEmpty ? '  ·  $partDur' : ''}',
                  style: TextStyle(
                      color: Colors.grey[500], fontSize: 11),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.cloud_done, color: _green, size: 14),
              ]),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildEmptyCloud() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Column(children: [
            Icon(Icons.cloud_off, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 16),
            Text('No synced sessions for ${_filter.label}',
                style:
                    TextStyle(color: Colors.grey[500], fontSize: 15)),
            const SizedBox(height: 8),
            Text('Pull to refresh or change the filter',
                style:
                    TextStyle(color: Colors.grey[400], fontSize: 13)),
          ]),
        ),
      );

  // ── Duration helpers ──────────────────────────────────────────────────────

  String _parsePartDuration(String name) {
    final m = RegExp(r'_(\d{4})-(\d{4})\.mp4').firstMatch(name);
    if (m == null) return '';
    int toSecs(String s) =>
        int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(2));
    final diff = toSecs(m.group(2)!) - toSecs(m.group(1)!);
    if (diff <= 0) return '';
    final mins = diff ~/ 60;
    final secs = diff % 60;
    return secs > 0 ? '${mins}m ${secs}s' : '${mins}m';
  }

  String _parseTotalDuration(List<String> names) {
    if (names.isEmpty) return '';
    try {
      final first = names.first;
      final last  = names.last;
      final sm = RegExp(r'_(\d{4})-\d{4}\.mp4').firstMatch(first);
      final em = RegExp(r'_\d{4}-(\d{4})\.mp4').firstMatch(last);
      if (sm == null || em == null) return '';
      int toSecs(String s) =>
          int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(2));
      final startSecs = toSecs(sm.group(1)!);
      final endSecs   = toSecs(em.group(1)!);
      final diff      = endSecs - startSecs;
      if (diff <= 0) return '';
      String fmt(int t) =>
          '${(t ~/ 60).toString().padLeft(2, '0')}:'
          '${(t % 60).toString().padLeft(2, '0')}';
      return '${fmt(startSecs)} → ${fmt(endSecs)}  ·  '
          '${diff ~/ 60}m ${diff % 60}s';
    } catch (_) {
      return '';
    }
  }

  DateTime? _parseFolderDate(String folder) {
    final parts = folder.split('-');
    if (parts.length != 3) return null;
    try {
      return DateTime(int.parse(parts[2]),
          int.parse(parts[1]), int.parse(parts[0]));
    } catch (_) {
      return null;
    }
  }
}

// ── Filter chip ───────────────────────────────────────────────────────────────

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00C853)
              : Colors.transparent,
          border: Border.all(
              color: selected
                  ? const Color(0xFF00C853)
                  : Colors.grey[300]!),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : Colors.grey[700],
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 13)),
      ),
    );
  }
}