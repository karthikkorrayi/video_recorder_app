import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/chunk_upload_queue.dart';
import '../services/cloud_cache_service.dart';
import '../services/session_store.dart';
import '../services/onedrive_service.dart';
import '../services/user_service.dart';
import 'history_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _green  = Color(0xFF00C853);
  static const _blue   = Colors.blue;
  static const _orange = Colors.orange;
  static const _red    = Colors.redAccent;

  final _queue = ChunkUploadQueue();
  final _cache = CloudCacheService();

  DateFilter _filter = DateFilter.today;
  String _userDisplayName = '';
  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _userDisplayName = await UserService().getDisplayName();
    OneDriveService.startBackgroundSync();
    _cache.syncIfStale();

    // Sync every 5 minutes
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cache.syncNow();
    });

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    super.dispose();
  }

  Future<void> _manualRefresh() async {
    await _cache.syncNow();
    if (mounted) setState(() {});
  }

  void _applyFilter(DateFilter f) => setState(() => _filter = f);

  // ── Cloud metrics from CloudCacheService ──────────────────────────────────

  /// Files matching selected filter
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
          final y = DateTime(now.year, now.month, now.day)
              .subtract(const Duration(days: 1));
          return d == y;
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

  /// Unique sessions in the filtered files (grouped by sessionFolder)
  int get _filteredSessionCount {
    final keys = <String>{};
    for (final f in _filteredFiles) {
      keys.add(f['sessionFolder'] as String? ??
          f['dateFolder'] as String? ?? '');
    }
    return keys.length;
  }

  /// Total recorded minutes from filtered files (parsed from filename)
  int get _filteredTotalMins {
    int total = 0;
    for (final f in _filteredFiles) {
      total += _parseFileDurationMins(f['name'] as String? ?? '');
    }
    return total;
  }

  /// This month totals from ALL cloud files
  List<Map<String, dynamic>> get _monthFiles {
    final now = DateTime.now();
    return _cache.files.where((f) {
      final folder = f['dateFolder'] as String? ?? '';
      final dt     = _parseFolderDate(folder);
      return dt != null && dt.year == now.year && dt.month == now.month;
    }).toList();
  }

  int get _monthTotalMins {
    return _monthFiles.fold(
        0, (s, f) => s + _parseFileDurationMins(f['name'] as String? ?? ''));
  }

  int get _monthSessionCount {
    final keys = <String>{};
    for (final f in _monthFiles) {
      keys.add(f['sessionFolder'] as String? ?? '');
    }
    return keys.length;
  }

  int get _syncedForFilter => _filteredFiles.length;

  String _fmtMins(int mins) =>
      mins < 60 ? '${mins}m' : '${mins ~/ 60}h ${mins % 60}m';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: RefreshIndicator(
          color: _green,
          onRefresh: _manualRefresh,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildHeader(),
                const SizedBox(height: 16),
                _buildStartRecording(),
                const SizedBox(height: 16),
                _buildSyncBanner(),
                const SizedBox(height: 16),
                _buildFilterSection(),
                const SizedBox(height: 12),
                // ── TOP ROW: Live queue stats ──────────────────────────
                _buildLiveQueueRow(),
                const SizedBox(height: 16),
                // ── ATTENDANCE: Cloud totals ───────────────────────────
                _buildAttendance(),
                const SizedBox(height: 16),
                _buildMyRecordingsCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _buildHeader() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: Row(children: [
          Container(
            width: 48, height: 48,
            decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(10)),
            child: const Center(
              child: Text('OTN',
                  style: TextStyle(
                      color: _green,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hello, $_userDisplayName',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16)),
                const Text('Omni Trade Networks',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.grey),
            onPressed: () {
              UserService().clearCache();
              FirebaseAuth.instance.signOut();
            },
          ),
        ]),
      );

  Widget _buildStartRecording() => GestureDetector(
        onTap: () => Navigator.pushNamed(context, '/camera'),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12)),
          child: const Row(children: [
            Icon(Icons.videocam, color: _green, size: 32),
            SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Start Recording',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
                Text('Tap to open camera',
                    style: TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
          ]),
        ),
      );

  Widget _buildSyncBanner() {
    return StreamBuilder<CacheState>(
      stream: _cache.stream,
      builder: (_, snap) {
        final synced = _cache.files.length;
        if (synced == 0) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
              color: const Color(0xFFE8F5E9),
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.cloud_done, color: _green),
            const SizedBox(width: 8),
            Text('$synced file(s) synced ✓',
                style: const TextStyle(
                    color: _green, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(_cache.lastSyncLabel,
                style: const TextStyle(color: _green, fontSize: 12)),
          ]),
        );
      },
    );
  }

  // ── Filter section ────────────────────────────────────────────────────────

  Widget _buildFilterSection() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.calendar_month, color: _green, size: 20),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(12)),
                child: Text(_cache.lastSyncLabel,
                    style: const TextStyle(color: _green, fontSize: 12)),
              ),
              const SizedBox(width: 8),
              Text(_filter.label,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
            ]),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                ...[
                  DateFilter.today,
                  DateFilter.yesterday,
                  DateFilter.thisWeek,
                  DateFilter.thisMonth,
                ].map((f) => _DashChip(
                      label: f.label,
                      selected: _filter.type == f.type,
                      onTap: () => _applyFilter(f),
                    )),
                _CalendarChip(
                  selected: _filter.type == FilterType.custom,
                  label: _filter.type == FilterType.custom
                      ? _filter.label
                      : null,
                  onTap: _pickCustomRange,
                ),
              ]),
            ),
          ],
        ),
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
        child: child!,
      ),
    );
    if (picked != null) {
      _applyFilter(DateFilter(FilterType.custom,
          from: picked.start, to: picked.end));
    }
  }

  // ── TOP ROW: Live ChunkUploadQueue stats ──────────────────────────────────

  Widget _buildLiveQueueRow() {
    return StreamBuilder<List<ChunkState>>(
      stream: _queue.stream,
      builder: (_, snap) {
        final pending   = _queue.pendingCount;
        final uploading = _queue.uploadingCount;
        final failed    = _queue.failedCount;
        final synced    = _syncedForFilter;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            _MetricTile(
              icon: Icons.play_circle_outline,
              value: '$synced',
              label: 'sessions',
              color: _green,
            ),
            _vDivider(),
            _MetricTile(
              icon: Icons.cloud_upload_outlined,
              value: '$uploading${pending > 0 ? '+$pending' : ''}',
              label: uploading > 0 ? 'uploading' : 'idle',
              color: uploading > 0 ? _blue : Colors.grey,
            ),
            _vDivider(),
            _MetricTile(
              icon: failed > 0
                  ? Icons.error_outline
                  : Icons.check_circle_outline,
              value: failed > 0 ? '$failed' : '✓',
              label: failed > 0 ? 'failed' : 'synced',
              color: failed > 0 ? _red : _green,
            ),
          ]),
        );
      },
    );
  }

  Widget _vDivider() => Container(
      height: 32,
      width: 1,
      color: Colors.grey[200],
      margin: const EdgeInsets.symmetric(horizontal: 8));

  // ── ATTENDANCE: Cloud totals ──────────────────────────────────────────────

  Widget _buildAttendance() {
    return StreamBuilder<CacheState>(
      stream: _cache.stream,
      builder: (_, __) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.person_outline, color: _green, size: 20),
                const SizedBox(width: 8),
                const Text('Attendance',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: const Color(0xFFE8F5E9),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text(_cache.lastSyncLabel,
                      style:
                          const TextStyle(color: _green, fontSize: 12)),
                ),
              ]),
              const SizedBox(height: 12),

              // Recorded time for selected filter
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: const Color(0xFFE8F5E9),
                    borderRadius: BorderRadius.circular(10)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.calendar_today,
                          color: _green, size: 20),
                      const SizedBox(width: 8),
                      Text(_fmtMins(_filteredTotalMins),
                          style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: _green)),
                    ]),
                    const SizedBox(height: 4),
                    Text("${_filter.label}'s recorded time",
                        style: TextStyle(
                            color: Colors.grey[600], fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // This month totals (always month, regardless of filter)
              Row(children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: const Color(0xFFE3F2FD),
                        borderRadius: BorderRadius.circular(10)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.timer_outlined,
                            color: Colors.blue, size: 20),
                        const SizedBox(height: 4),
                        Text(_fmtMins(_monthTotalMins),
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue)),
                        const SizedBox(height: 2),
                        const Text('Total Time\n(this month)',
                            style: TextStyle(
                                color: Colors.blue, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3E5F5),
                        borderRadius: BorderRadius.circular(10)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.play_circle_outline,
                            color: Colors.purple, size: 20),
                        const SizedBox(height: 4),
                        Text('$_monthSessionCount',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.purple)),
                        const SizedBox(height: 2),
                        const Text('All Sessions\n(this month)',
                            style: TextStyle(
                                color: Colors.purple, fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ]),
            ],
          ),
        );
      },
    );
  }

  Widget _buildMyRecordingsCard() => GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => HistoryScreen(initialFilter: _filter),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.history, color: _green, size: 22),
            const SizedBox(width: 12),
            const Text('My Recordings',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const Spacer(),
            Text(
              '$_filteredSessionCount session${_filteredSessionCount == 1 ? '' : 's'}',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, color: Colors.grey, size: 20),
          ]),
        ),
      );

  // ── Helpers ───────────────────────────────────────────────────────────────

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

  int _parseFileDurationMins(String name) {
    final m = RegExp(r'_(\d{4})-(\d{4})\.mp4').firstMatch(name);
    if (m == null) return 0;
    int toSecs(String s) =>
        int.parse(s.substring(0, 2)) * 60 + int.parse(s.substring(2));
    final diff = toSecs(m.group(2)!) - toSecs(m.group(1)!);
    return (diff / 60).ceil().clamp(0, 9999);
  }
}

// ── Small reusable widgets ────────────────────────────────────────────────────

class _DashChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _DashChip(
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
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                fontSize: 13)),
      ),
    );
  }
}

class _CalendarChip extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final String? label;
  const _CalendarChip(
      {required this.selected, required this.onTap, this.label});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF00C853) : Colors.transparent,
          border: Border.all(
              color: selected
                  ? const Color(0xFF00C853)
                  : Colors.grey[300]!),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.calendar_today,
              size: 14,
              color: selected ? Colors.white : Colors.grey[600]),
          if (label != null) ...[
            const SizedBox(width: 4),
            Text(label!,
                style: TextStyle(
                    color: selected ? Colors.white : Colors.grey[700],
                    fontSize: 12)),
          ],
        ]),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final Color color;
  const _MetricTile(
      {required this.icon,
      required this.value,
      required this.label,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 13, color: color)),
        Text(label,
            style: TextStyle(color: Colors.grey[500], fontSize: 11)),
      ]),
    );
  }
}