import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
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
      case FilterType.yesterday:
        from = to = today.subtract(const Duration(days: 1));
      case FilterType.thisWeek:
        from = today.subtract(Duration(days: today.weekday - 1)); to = today;
      case FilterType.thisMonth:
        from = DateTime(now.year, now.month, 1); to = today;
      case FilterType.custom:
        from = _filter.from ?? today; to = _filter.to ?? today;
    }
    final out = <String>[]; var cur = from;
    while (!cur.isAfter(to)) {
      out.add(_fmtFolder(cur)); cur = cur.add(const Duration(days: 1));
    }
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
        if (_filter.from != null && _filter.to != null) {
          return _firestore.metricsStreamForRange(_filter.from!, _filter.to!);
        }
        return _firestore.metricsStreamForDate(_fmtFolder(today));
    }
  }

  Future<void> _showCalendarPicker() async {
    DateTime? from = _filter.type == FilterType.custom ? _filter.from : null;
    DateTime? to   = _filter.type == FilterType.custom ? _filter.to   : null;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _CalendarPicker(
        initialFrom: from, initialTo: to,
        onApply: (f, t) => setState(() =>
            _filter = DateFilter(FilterType.custom, from: f, to: t)),
      ),
    );
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
            await _firestore.syncDeletionsFromOneDrive(
                dateFolders: _filterFolders());
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
    decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      Container(width: 48, height: 48,
        decoration: BoxDecoration(color: Colors.black,
            borderRadius: BorderRadius.circular(10)),
        child: const Center(child: Text('OTN', style: TextStyle(
            color: _green, fontWeight: FontWeight.bold, fontSize: 13)))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Text('Hello, $_userDisplayName', style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 16)),
        const Text('Omni Trade Networks',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      ])),
      IconButton(
        icon: const Icon(Icons.logout, color: Colors.grey),
        onPressed: () async {
          // Clear in-memory queue + pending DB rows for this user BEFORE sign-out.
          // Without this, the next user to log in on the same device inherits
          // the previous user's pending sessions in Pending Uploads.
          final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
          await ChunkUploadQueue().clearForUser(uid);
          UserService().clearCache();
          await FirebaseAuth.instance.signOut();
        }),
    ]),
  );

  Widget _startRec() => GestureDetector(
    onTap: () => Navigator.pushNamed(context, '/camera'),
    child: Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: Colors.black,
          borderRadius: BorderRadius.circular(12)),
      child: const Row(children: [
        Icon(Icons.videocam, color: _green, size: 32),
        SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Start Recording', style: TextStyle(
              color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
          Text('Tap to open camera',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
        ]),
      ]),
    ),
  );

  Widget _filterSection() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.calendar_month, color: _green, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(_filter.label, style: const TextStyle(
            fontWeight: FontWeight.bold, fontSize: 15))),
      ]),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          ...[DateFilter.today, DateFilter.yesterday,
              DateFilter.thisWeek, DateFilter.thisMonth]
              .map((f) => _DashChip(
                label: f.label, selected: _filter.type == f.type,
                onTap: () => setState(() => _filter = f))),
          // Calendar custom range picker — always visible with label
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: GestureDetector(
              onTap: _showCalendarPicker,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                    color: _filter.type == FilterType.custom
                        ? _green : Colors.transparent,
                    border: Border.all(color: _filter.type == FilterType.custom
                        ? _green : Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(20)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.calendar_today, size: 14,
                      color: _filter.type == FilterType.custom
                          ? Colors.white : Colors.grey[600]),
                  const SizedBox(width: 5),
                  Text(
                    _filter.type == FilterType.custom
                        ? _filter.label : 'Pick Dates',
                    style: TextStyle(
                        color: _filter.type == FilterType.custom
                            ? Colors.white : Colors.grey[600],
                        fontSize: 12,
                        fontWeight: _filter.type == FilterType.custom
                            ? FontWeight.w600 : FontWeight.normal),
                  ),
                ]),
              ),
            )),
        ]),
      ),
    ]),
  );

  Widget _metrics() => StreamBuilder<DashMetrics>(
    key: ValueKey(_filter.hashCode),
    stream: _metricsStream(),
    builder: (_, fsSnap) {
      final m       = fsSnap.data ?? const DashMetrics(totalSecs: 0, sessionCount: 0);
      final loading = fsSnap.connectionState == ConnectionState.waiting
          && m.totalSecs == 0;
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
              icon: allSynced
                  ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
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
        MaterialPageRoute(builder: (_) => const HistoryScreen())),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(color: Colors.white,
          borderRadius: BorderRadius.circular(12)),
      child: const Row(children: [
        Icon(Icons.history, color: _green, size: 22), SizedBox(width: 12),
        Text('My Recordings',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        Spacer(),
        Icon(Icons.chevron_right, color: Colors.grey, size: 20),
      ]),
    ),
  );
}

// ── Calendar date range picker popup ─────────────────────────────────────────
class _CalendarPicker extends StatefulWidget {
  final DateTime? initialFrom;
  final DateTime? initialTo;
  final void Function(DateTime, DateTime) onApply;
  const _CalendarPicker(
      {this.initialFrom, this.initialTo, required this.onApply});
  @override
  State<_CalendarPicker> createState() => _CalendarPickerState();
}

class _CalendarPickerState extends State<_CalendarPicker> {
  static const _green = Color(0xFF00C853);
  DateTime  _viewMonth = DateTime.now();
  DateTime? _from;
  DateTime? _to;

  @override
  void initState() {
    super.initState();
    _from      = widget.initialFrom;
    _to        = widget.initialTo;
    _viewMonth = DateTime(
        _from?.year  ?? DateTime.now().year,
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
    final now         = DateTime.now();
    final today       = DateTime(now.year, now.month, now.day);
    final firstDay    = DateTime(_viewMonth.year, _viewMonth.month, 1);
    final daysInMonth =
        DateTime(_viewMonth.year, _viewMonth.month + 1, 0).day;
    final startDow    = firstDay.weekday % 7;
    final monthLabel  = DateFormat('MMMM yyyy').format(_viewMonth);

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),

          // Month navigation
          Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _prevMonth),
              Expanded(child: Text(monthLabel,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16))),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: _viewMonth.year < today.year ||
                    (_viewMonth.year == today.year &&
                        _viewMonth.month <= today.month)
                    ? _nextMonth : null),
            ]),
          ),

          // Weekday labels
          Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: ['Su','Mo','Tu','We','Th','Fr','Sa']
                .map((d) => Expanded(child: Center(child: Text(d,
                    style: TextStyle(fontSize: 12, color: Colors.grey[500],
                        fontWeight: FontWeight.w600)))))
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
                ...List.generate(startDow, (_) => const SizedBox()),
                ...List.generate(daysInMonth, (i) {
                  final day     = DateTime(_viewMonth.year, _viewMonth.month, i+1);
                  final isFuture = day.isAfter(today);
                  final isFrom  = _from != null &&
                      day.year == _from!.year &&
                      day.month == _from!.month &&
                      day.day == _from!.day;
                  final isTo    = _to != null &&
                      day.year == _to!.year &&
                      day.month == _to!.month &&
                      day.day == _to!.day;
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
                      child: Center(child: Text('${i+1}', style: TextStyle(
                        fontSize: 13,
                        fontWeight: (isFrom || isTo)
                            ? FontWeight.bold : FontWeight.normal,
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

          if (_from != null)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _to != null
                    ? '${DateFormat('d MMM').format(_from!)} → '
                        '${DateFormat('d MMM yyyy').format(_to!)}'
                    : 'Select end date',
                style: TextStyle(color: Colors.grey[600], fontSize: 13),
              ),
            ),

          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: SizedBox(width: double.infinity,
              child: ElevatedButton(
                onPressed: (_from != null && _to != null)
                    ? () {
                        Navigator.pop(context);
                        widget.onApply(_from!, _to!);
                      }
                    : null,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _green, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: const Text('Apply',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────
class _MetricTile extends StatelessWidget {
  final IconData icon; final String value; final String label;
  final String? subLabel; final Color color;
  final bool loading; final bool pulsing;
  const _MetricTile({required this.icon, required this.value,
    required this.label, required this.color,
    this.subLabel, this.loading = false, this.pulsing = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.2))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: color, size: 18),
        if (pulsing) ...[const SizedBox(width: 6),
          Container(width: 6, height: 6, decoration: BoxDecoration(
              color: color, shape: BoxShape.circle))],
      ]),
      const SizedBox(height: 8),
      loading
          ? SizedBox(width: 24, height: 24,
              child: CircularProgressIndicator(strokeWidth: 2, color: color))
          : Text(value, style: TextStyle(
              fontSize: 24, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 11)),
      if (subLabel != null) ...[const SizedBox(height: 2),
        Text(subLabel!, style: TextStyle(
            color: color.withValues(alpha: 0.7),
            fontSize: 11, fontWeight: FontWeight.w600))],
    ]),
  );
}

class _DashChip extends StatelessWidget {
  final String label; final bool selected; final VoidCallback onTap;
  const _DashChip(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF00C853) : Colors.transparent,
        border: Border.all(color: selected
            ? const Color(0xFF00C853) : Colors.grey[300]!),
        borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(
        color: selected ? Colors.white : Colors.grey[700],
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        fontSize: 13)),
    ),
  );
}