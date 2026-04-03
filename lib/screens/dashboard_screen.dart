import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/local_video_storage.dart';
import '../services/attendance_service.dart';
import '../services/processing_manager.dart';
import 'camera_screen.dart';
import 'history_screen.dart';

const _green   = Color(0xFF00C853);
const _black   = Color(0xFF0D0D0D);
const _surface = Color(0xFFF4F4F4);
const _card    = Color(0xFFFFFFFF);
const _text    = Color(0xFF1A1A1A);
const _textSub = Color(0xFF666666);
const _border  = Color(0xFFE0E0E0);

// ── Attendance filter options ─────────────────────────────────────────────────
enum _AttFilter { today, yesterday, thisWeek, thisMonth, allTime, custom }

extension _AttFilterLabel on _AttFilter {
  String get label {
    switch (this) {
      case _AttFilter.today:      return 'Today';
      case _AttFilter.yesterday:  return 'Yesterday';
      case _AttFilter.thisWeek:   return 'This Week';
      case _AttFilter.thisMonth:  return 'This Month';
      case _AttFilter.allTime:    return 'All Time';
      case _AttFilter.custom:     return 'Custom Range';
    }
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _auth = AuthService();
  final _storage = LocalVideoStorage();
  final _attendance = AttendanceService();
  final _proc       = ProcessingManager();

  int _sessions = 0;
  int _totalSecs = 0;
  List<AttendanceEntry> _allEntries = [];
  List<AttendanceEntry> _filteredEntries = [];
  Map<String, ProcessingStatus> _jobs = {};

  // Attendance filter state
  _AttFilter _filter = _AttFilter.today;
  DateTimeRange? _customRange;
  bool _attendanceExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
    _jobs = _proc.current;
    _proc.stream.listen((jobs) {
      if (mounted) {
        setState(() => _jobs = jobs);
        // Refresh stats when a job finishes
        if (jobs.values.any((j) => j.isDone)) _load();
      }
    });
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser!;
    final email = user.email ?? user.uid;
    final count = await _storage.sessionCount(email);
    final secs  = await _storage.totalDurationSeconds(email);
    final ent   = await _attendance.getEntries();
    if (mounted) {
      setState(() {
        _sessions  = count;
        _totalSecs = secs;
        _allEntries = ent;
        _applyFilter();
      });
    }
  }

  void _applyFilter() {
    final now  = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    _filteredEntries = _allEntries.where((e) {
      DateTime? entryDate;
      try { entryDate = DateTime.parse(e.date); } catch (_) { return false; }

      switch (_filter) {
        case _AttFilter.today:
          return entryDate.year == today.year &&
              entryDate.month == today.month &&
              entryDate.day == today.day;
        case _AttFilter.yesterday:
          final y = today.subtract(const Duration(days: 1));
          return entryDate.year == y.year && entryDate.month == y.month && entryDate.day == y.day;
        case _AttFilter.thisWeek:
          final weekStart = today.subtract(Duration(days: today.weekday - 1));
          return !entryDate.isBefore(weekStart) && !entryDate.isAfter(today);
        case _AttFilter.thisMonth:
          return entryDate.year == today.year && entryDate.month == today.month;
        case _AttFilter.allTime:
          return true;
        case _AttFilter.custom:
          if (_customRange == null) return true;
          final start = DateTime(_customRange!.start.year, _customRange!.start.month, _customRange!.start.day);
          final end   = DateTime(_customRange!.end.year, _customRange!.end.month, _customRange!.end.day, 23, 59, 59);
          return !entryDate.isBefore(start) && !entryDate.isAfter(end);
      }
    }).toList();
  }

  // Total time for filtered attendance
  String get _filteredTotal {
    final secs = _filteredEntries.fold<int>(0, (sum, e) => sum + e.totalSeconds);
    if (secs == 0) return '0m';
    final h = secs ~/ 3600; final m = (secs % 3600) ~/ 60; final s = secs % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return s > 0 ? '${m}m ${s}s' : '${m}m';
    return '${s}s';
  }

  int get _filteredSessions =>
      _filteredEntries.fold<int>(0, (sum, e) => sum + e.sessions);

  // ── Attendance dropdown overlay ───────────────────────────────────────────

  void _showAttendanceFilter(BuildContext context) async {
    final result = await showModalBottomSheet<_AttFilter>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AttendanceFilterSheet(
        current: _filter,
        customRange: _customRange,
        onCustomRange: () async {
          Navigator.pop(ctx, _AttFilter.custom);
        },
      ),
    );
    if (result == null) return;

    if (result == _AttFilter.custom) {
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2024),
        lastDate: DateTime.now(),
        initialDateRange: _customRange,
        builder: (ctx, child) => Theme(
          data: Theme.of(ctx).copyWith(
            colorScheme: const ColorScheme.light(
              primary: _green, onPrimary: Colors.white,
              surface: _card, onSurface: _text,
            ),
          ),
          child: child!,
        ),
      );
      if (range != null) {
        setState(() { _customRange = range; _filter = _AttFilter.custom; _applyFilter(); });
      }
    } else {
      setState(() { _filter = result; _applyFilter(); });
    }
  }

  String _fmt(int s) {
    if (s == 0) return '0s';
    if (s < 60) return '${s}s';
    final m = s ~/ 60; final r = s % 60;
    return r > 0 ? '${m}m ${r}s' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final name = (user.email ?? 'User').split('@').first;
    final activeJobs = _jobs.values.where((j) => j.isActive).toList();
    final recentJobs = _jobs.values.where((j) => !j.isActive).toList();

    return Scaffold(
      backgroundColor: _surface,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

            // ── Header ──────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border)),
              child: Row(children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(color: _black,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: _green, width: 2)),
                  child: const Center(child: Text('OTN',
                      style: TextStyle(color: _green, fontSize: 9,
                          fontWeight: FontWeight.w800, letterSpacing: 1))),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Hello, $name',
                      style: const TextStyle(color: _text, fontSize: 17,
                          fontWeight: FontWeight.w700)),
                  const Text('Omni Trade Networks',
                      style: TextStyle(color: _textSub, fontSize: 10, letterSpacing: 0.5)),
                ])),
                IconButton(icon: const Icon(Icons.logout_rounded, color: _textSub, size: 20),
                    onPressed: _auth.signOut),
              ]),
            ),
            const SizedBox(height: 12),

              // ── RECORD BUTTON (top, not middle) ─────────────────────────
              // Placed at top so it's away from phone stand & nav bar
            GestureDetector(
              onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const CameraScreen()),
              ).then((_) => _load()),
              child: Container(
                width: double.infinity, height: 100,
                decoration: BoxDecoration(
                  color: _black,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _green, width: 2),
                  boxShadow: [BoxShadow(color: _green.withOpacity(0.18),
                      blurRadius: 14, spreadRadius: 1)],
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    width: 52, height: 52,
                    decoration: BoxDecoration(shape: BoxShape.circle,
                        color: _green.withOpacity(0.12),
                        border: Border.all(color: _green, width: 2.2)),
                    child: const Icon(Icons.videocam_rounded, color: _green, size: 24)),
                  const SizedBox(width: 16),
                  Column(mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Start Recording',
                        style: TextStyle(color: Colors.white, fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    Text(
                      activeJobs.isNotEmpty
                          ? '${activeJobs.length} processing in background'
                          : 'Tap to open camera',
                      style: TextStyle(
                          color: activeJobs.isNotEmpty ? _green : Colors.white54,
                          fontSize: 11)),
                  ]),
                ]),
              ),
            ),
            const SizedBox(height: 12),

            // ── Processing queue ─────────────────────────────────────────
            if (activeJobs.isNotEmpty || recentJobs.isNotEmpty) ...[
              _sectionLabel('Processing'),
              const SizedBox(height: 6),
              ...activeJobs.map(_processingCard),
              ...recentJobs.map(_processingCard),
              const SizedBox(height: 12),
            ],

            // ── Stats ────────────────────────────────────────────────────
            Row(children: [
              Expanded(child: _stat(Icons.video_collection_rounded,
                  '$_sessions', 'Recordings', _green)),
              const SizedBox(width: 10),
              Expanded(child: _stat(Icons.timer_rounded,
                  _fmt(_totalSecs), 'Total Recorded', const Color(0xFF0091EA))),
            ]),
            const SizedBox(height: 10),

            // ── History tile ─────────────────────────────────────────────
            GestureDetector(
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
              ).then((_) => _load()),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(color: _card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _border)),
                child: Row(children: [
                  Icon(Icons.history_rounded, color: _green, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(child: Text('My Recordings',
                      style: TextStyle(color: _text, fontSize: 14,
                          fontWeight: FontWeight.w600))),
                  Text('$_sessions video${_sessions == 1 ? '' : 's'}',
                      style: const TextStyle(color: _textSub, fontSize: 12)),
                  const SizedBox(width: 6),
                  const Icon(Icons.chevron_right_rounded, color: _textSub, size: 18),
                ]),
              ),
            ),
            const SizedBox(height: 20),

            // ════════════════════════════════════════════════════════════
            // ── ATTENDANCE SECTION ────────────────────────────────────
            // ════════════════════════════════════════════════════════════
            _sectionLabel('Attendance'),
            const SizedBox(height: 8),

            Container(
              decoration: BoxDecoration(color: _card,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _border)),
              child: Column(children: [

                // ── Header row with filter dropdown ───────────────────
                GestureDetector(
                  onTap: () => setState(
                      () => _attendanceExpanded = !_attendanceExpanded),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(children: [
                      const Icon(Icons.calendar_month_rounded,
                          color: _green, size: 18),
                      const SizedBox(width: 8),
                      const Text('Daily Record',
                          style: TextStyle(color: _text, fontSize: 14,
                              fontWeight: FontWeight.w700)),
                      const Spacer(),
                      // Filter chip
                      GestureDetector(
                        onTap: () => _showAttendanceFilter(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: _green.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _green.withOpacity(0.4)),
                          ),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(_filter.label,
                                style: const TextStyle(color: _green,
                                    fontSize: 11, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down_rounded,
                                color: _green, size: 14),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(_attendanceExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                          color: _textSub, size: 20),
                    ]),
                  ),
                ),

                // ── Summary row ───────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Row(children: [
                    _attSummaryChip(Icons.repeat_rounded,
                        '$_filteredSessions session${_filteredSessions == 1 ? '' : 's'}',
                        const Color(0xFF0091EA)),
                    const SizedBox(width: 8),
                    _attSummaryChip(Icons.timer_rounded,
                        _filteredTotal, _green),
                  ]),
                ),

                // ── Expanded entries ──────────────────────────────────
                if (_attendanceExpanded) ...[
                  const Divider(height: 1, color: _border),
                  if (_filteredEntries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Center(child: Text(
                          'No records for ${_filter.label.toLowerCase()}',
                          style: const TextStyle(color: _textSub, fontSize: 13))),
                    )
                  else
                    ...(_filteredEntries.take(30).map((e) => _attendanceRow(e))),
                ],
              ]),
            ),
            const SizedBox(height: 24),
          ]),
        ),
      ),
    );
  }

  Widget _attSummaryChip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 5),
        Text(label, style: TextStyle(color: color, fontSize: 11,
            fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _attendanceRow(AttendanceEntry e) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          border: Border(top: BorderSide(color: _border.withOpacity(0.7)))),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.date, style: const TextStyle(color: _text, fontSize: 13,
              fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${e.sessions} session${e.sessions == 1 ? '' : 's'}  ·  avg ${e.avgStr}',
              style: const TextStyle(color: _textSub, fontSize: 11)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(e.totalStr, style: const TextStyle(color: _green, fontSize: 14,
              fontWeight: FontWeight.w700)),
          Text('${e.firstSession} – ${e.lastSession}',
              style: const TextStyle(color: _textSub, fontSize: 10)),
        ]),
      ]),
    );
  }

  Widget _processingCard(ProcessingStatus j) {
    final Color accent = j.isActive ? _green : j.isDone ? Colors.green : Colors.red;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: accent.withOpacity(0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (j.isActive)
            SizedBox(width: 13, height: 13,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent))
          else
            Icon(j.isDone ? Icons.check_circle_rounded : Icons.error_rounded,
                color: accent, size: 15),
          const SizedBox(width: 8),
          Expanded(child: Text(j.message,
              style: TextStyle(color: j.isDone ? Colors.green : _text,
                  fontSize: 12, fontWeight: FontWeight.w500))),
          Text(j.stateLabel, style: TextStyle(color: accent,
              fontSize: 10, fontWeight: FontWeight.w700)),
        ]),
        if (j.isActive) ...[
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: j.progress, minHeight: 3,
                  backgroundColor: _border,
                  valueColor: AlwaysStoppedAnimation<Color>(accent))),
        ],
      ]),
    );
  }

  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(color: _textSub, fontSize: 10,
          fontWeight: FontWeight.w700, letterSpacing: 1.3));

  Widget _stat(IconData icon, String value, String label, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 8),
        Text(value, style: TextStyle(color: color, fontSize: 18,
            fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: _textSub, fontSize: 10)),
      ]),
    );
  }
}

// ── Attendance filter bottom sheet ────────────────────────────────────────────

class _AttendanceFilterSheet extends StatelessWidget {
  final _AttFilter current;
  final DateTimeRange? customRange;
  final VoidCallback onCustomRange;

  const _AttendanceFilterSheet({
    required this.current, required this.customRange,
    required this.onCustomRange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Handle
        Container(margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40, height: 4,
            decoration: BoxDecoration(color: _border, borderRadius: BorderRadius.circular(2))),

        const Padding(padding: EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Row(children: [
            Icon(Icons.tune_rounded, color: _green, size: 18),
            SizedBox(width: 8),
            Text('Filter Attendance', style: TextStyle(color: _text,
                fontSize: 16, fontWeight: FontWeight.w700)),
          ])),

        const Divider(height: 1, color: _border),

        ..._AttFilter.values.map((f) => ListTile(
          onTap: () => Navigator.pop(context, f),
          leading: Icon(
            f == current ? Icons.radio_button_checked : Icons.radio_button_off,
            color: f == current ? _green : _textSub, size: 20),
          title: Text(f.label, style: TextStyle(
            color: f == current ? _green : _text,
            fontWeight: f == current ? FontWeight.w700 : FontWeight.w400,
            fontSize: 14)),
          trailing: f == _AttFilter.custom && customRange != null
              ? Text(
                  '${customRange!.start.day}/${customRange!.start.month} – '
                  '${customRange!.end.day}/${customRange!.end.month}',
                  style: const TextStyle(color: _textSub, fontSize: 11))
              : null,
        )),

        const SizedBox(height: 16),
      ]),
    );
  }
}