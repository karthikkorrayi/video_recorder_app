import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/chunk_upload_queue.dart';
import '../services/firestore_cache_service.dart';
import '../services/onedrive_service.dart';
import '../services/user_service.dart';
import '../widgets/network_banner.dart';
import 'history_screen.dart';
import '../services/session_store.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _green  = Color(0xFF00C853);
  static const _orange = Colors.orange;

  final _queue     = ChunkUploadQueue();
  final _firestore = FirestoreCacheService();

  DateFilter _filter          = DateFilter.today;
  String     _userDisplayName = '';

  @override
  void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    _userDisplayName = await UserService().getDisplayName();
    OneDriveService.startBackgroundSync();
    _firestore.backfillFromOneDrive().ignore();
    if (mounted) setState(() {});
  }

  String _fmtFolder(DateTime d) =>
      '${d.day.toString().padLeft(2,'0')}-'
      '${d.month.toString().padLeft(2,'0')}-${d.year}';

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
    while (!cur.isAfter(to)) { out.add(_fmtFolder(cur)); cur = cur.add(const Duration(days: 1)); }
    return out.take(30).toList();
  }

  Stream<DashMetrics> _metricsStream() {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    switch (_filter.type) {
      case FilterType.today:
        return _firestore.metricsStreamForDate(_fmtFolder(today));
      case FilterType.yesterday:
        return _firestore.metricsStreamForDate(
            _fmtFolder(today.subtract(const Duration(days: 1))));
      case FilterType.thisWeek:
        return _firestore.metricsStreamForRange(
            today.subtract(Duration(days: today.weekday - 1)), today);
      case FilterType.thisMonth:
        return _firestore.metricsStreamForRange(
            DateTime(now.year, now.month, 1), today);
      case FilterType.custom:
        if (_filter.from != null && _filter.to != null)
          return _firestore.metricsStreamForRange(_filter.from!, _filter.to!);
        return _firestore.metricsStreamForDate(_fmtFolder(today));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF5F5F5),
    body: NetworkBannerWrapper(
      child: SafeArea(
        child: RefreshIndicator(
          color: _green,
          onRefresh: () async {
            await _firestore.backfillFromOneDrive();
            await _firestore.syncDeletionsFromOneDrive(dateFolders: _filterFolders());
            setState(() {});
          },
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              _header(), const SizedBox(height: 16),
              _startRec(), const SizedBox(height: 16),
              _filterSection(), const SizedBox(height: 12),
              _metrics(), const SizedBox(height: 16),
              _myRecordingsCard(),
            ]),
          ),
        ),
      ),
    ),
  );

  Widget _header() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      Container(width: 48, height: 48,
        decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(10)),
        child: const Center(child: Text('OTN', style: TextStyle(color: _green, fontWeight: FontWeight.bold, fontSize: 13)))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Hello, $_userDisplayName', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const Text('Omni Trade Networks', style: TextStyle(color: Colors.grey, fontSize: 12)),
      ])),
      IconButton(icon: const Icon(Icons.logout, color: Colors.grey), onPressed: () {
        UserService().clearCache(); FirebaseAuth.instance.signOut();
      }),
    ]),
  );

  Widget _startRec() => GestureDetector(
    onTap: () => Navigator.pushNamed(context, '/camera'),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(12)),
      child: const Row(children: [
        Icon(Icons.videocam, color: _green, size: 32), SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Start Recording', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          Text('Tap to open camera', style: TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      ]),
    ),
  );

  Widget _filterSection() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.calendar_month, color: _green, size: 20),
        const SizedBox(width: 8),
        Text(_filter.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ]),
      const SizedBox(height: 12),
      SingleChildScrollView(scrollDirection: Axis.horizontal,
        child: Row(children: [
          ...[DateFilter.today, DateFilter.yesterday, DateFilter.thisWeek, DateFilter.thisMonth]
              .map((f) => _DashChip(
                label: f.label, selected: _filter.type == f.type,
                onTap: () => setState(() => _filter = f))),
        ]),
      ),
    ]),
  );

  Widget _metrics() => StreamBuilder<DashMetrics>(
    // ValueKey forces stream to rebuild when filter changes — fixes stale data
    key: ValueKey(_filter.hashCode),
    stream: _metricsStream(),
    builder: (_, fsSnap) {
      final m       = fsSnap.data ?? const DashMetrics(totalSecs: 0, sessionCount: 0);
      final loading = fsSnap.connectionState == ConnectionState.waiting && m.totalSecs == 0;
      return StreamBuilder<List<ChunkState>>(
        stream: _queue.stream,
        builder: (_, __) {
          final pendingSessions = _queue.pendingSessionCount;
          final pendingSecs     = _queue.pendingSecs;
          final isUploading     = _queue.isUploading;
          final allSynced       = pendingSessions == 0;
          return Row(children: [
            Expanded(child: _MetricTile(
              icon: Icons.timer_outlined,
              value: fmtDuration(m.totalSecs),
              label: '${_filter.label} recorded',
              subLabel: m.sessionCount == 0 ? null
                  : '${m.sessionCount} session${m.sessionCount == 1 ? '' : 's'}',
              color: _green, loading: loading)),
            const SizedBox(width: 12),
            Expanded(child: _MetricTile(
              icon: allSynced ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              value: allSynced ? '✓' : fmtDuration(pendingSecs),
              label: allSynced ? 'All synced'
                  : '$pendingSessions session${pendingSessions == 1 ? '' : 's'} pending',
              color: allSynced ? _green : _orange,
              pulsing: isUploading)),
          ]);
        },
      );
    },
  );

  Widget _myRecordingsCard() => GestureDetector(
    onTap: () => Navigator.push(context,
        MaterialPageRoute(builder: (_) => HistoryScreen(initialFilter: _filter))),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
      child: const Row(children: [
        Icon(Icons.history, color: _green, size: 22), SizedBox(width: 12),
        Text('My Recordings', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        Spacer(),
        Icon(Icons.chevron_right, color: Colors.grey, size: 20),
      ]),
    ),
  );
}

// ── Shared widgets ────────────────────────────────────────────────────────────

class _MetricTile extends StatelessWidget {
  final IconData icon; final String value; final String label;
  final String? subLabel; final Color color;
  final bool loading; final bool pulsing;
  const _MetricTile({required this.icon, required this.value, required this.label,
    required this.color, this.subLabel, this.loading = false, this.pulsing = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color, size: 18),
        if (pulsing) ...[const SizedBox(width: 6),
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle))],
      ]),
      const SizedBox(height: 8),
      loading ? SizedBox(width: 24, height: 24,
          child: CircularProgressIndicator(strokeWidth: 2, color: color))
          : Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 11)),
      if (subLabel != null) ...[const SizedBox(height: 2),
        Text(subLabel!, style: TextStyle(color: color.withValues(alpha: 0.7),
            fontSize: 11, fontWeight: FontWeight.w600))],
    ]),
  );
}

class _DashChip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _DashChip({required this.label, required this.selected, required this.onTap});
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