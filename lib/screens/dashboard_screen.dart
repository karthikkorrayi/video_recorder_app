import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/attendance_service.dart';
import '../services/session_store.dart';
import '../services/user_service.dart';
import 'camera_screen.dart';
import 'history_screen.dart';

const _green   = Color(0xFF00C853);
const _surface = Color(0xFFF4F6F8);
const _card    = Color(0xFFFFFFFF);
const _text    = Color(0xFF1A1A1A);
const _textSub = Color(0xFF666666);
const _border  = Color(0xFFE0E0E0);

enum _AttFilter { today, yesterday, thisWeek, thisMonth, allTime }

extension _Label on _AttFilter {
  String get label {
    switch (this) {
      case _AttFilter.today:     return 'Today';
      case _AttFilter.yesterday: return 'Yesterday';
      case _AttFilter.thisWeek:  return 'This Week';
      case _AttFilter.thisMonth: return 'This Month';
      case _AttFilter.allTime:   return 'All Time';
    }
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _auth       = AuthService();
  final _attendance = AttendanceService();
  final _store      = SessionStore();

  // Metrics
  int _totalRecordings = 0; // local + synced
  int _localCount      = 0;
  int _syncedCount     = 0;
  int _totalSecs       = 0; // sum of all session durations

  // Attendance
  List<AttendanceEntry> _allEntries      = [];
  List<AttendanceEntry> _filteredEntries = [];
  _AttFilter _filter    = _AttFilter.today;
  bool _attExpanded     = false;

  // Display name
  String _displayName = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user  = FirebaseAuth.instance.currentUser!;

    // Load display name from Firestore
    final name = await UserService().getDisplayName();

    // Load all sessions from store (includes local + synced)
    final allSessions = await _store.getAll();
    final localSessions  = allSessions.where((s) => s.status != 'synced').toList();
    final syncedSessions = allSessions.where((s) => s.status == 'synced').toList();
    final totalSecs = allSessions.fold<int>(0, (sum, s) => sum + s.durationSeconds);

    // Load attendance
    final entries = await _attendance.getEntries();

    if (mounted) setState(() {
      _displayName     = name;
      _totalRecordings = allSessions.length;
      _localCount      = localSessions.length;
      _syncedCount     = syncedSessions.length;
      _totalSecs       = totalSecs;
      _allEntries      = entries;
      _applyFilter();
    });
  }

  void _applyFilter() {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    _filteredEntries = _allEntries.where((e) {
      DateTime? d;
      try { d = DateTime.parse(e.date); } catch (_) { return false; }
      switch (_filter) {
        case _AttFilter.today:
          return d.isAtSameMomentAs(today) || (d.isAfter(today) && d.isBefore(today.add(const Duration(days: 1))));
        case _AttFilter.yesterday:
          final yest = today.subtract(const Duration(days: 1));
          return d.isAtSameMomentAs(yest) || (d.isAfter(yest) && d.isBefore(today));
        case _AttFilter.thisWeek:
          final weekStart = today.subtract(Duration(days: today.weekday - 1));
          return !d.isBefore(weekStart);
        case _AttFilter.thisMonth:
          return d.year == now.year && d.month == now.month;
        case _AttFilter.allTime:
          return true;
      }
    }).toList();
  }

  String _fmtSecs(int secs) {
    if (secs == 0) return '0s';
    if (secs < 60) return '${secs}s';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) return '${h}h ${m}m';
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  int get _filteredSessions => _filteredEntries.fold<int>(0, (s, e) => s + e.sessions);
  int get _filteredSecs     => _filteredEntries.fold<int>(0, (s, e) => s + e.totalSeconds);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _surface,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          color: _green,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

              // ── Header card ────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: _card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _border)),
                child: Row(children: [
                  Container(width: 46, height: 46,
                    decoration: BoxDecoration(color: Colors.black,
                        borderRadius: BorderRadius.circular(12)),
                    child: const Center(child: Text('OTN',
                        style: TextStyle(color: _green, fontSize: 11,
                            fontWeight: FontWeight.w800)))),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      _displayName.isEmpty ? 'Hello!' : 'Hello, $_displayName',
                      style: const TextStyle(color: _text, fontSize: 18,
                          fontWeight: FontWeight.w700),
                    ),
                    const Text('Omni Trade Networks',
                        style: TextStyle(color: _textSub, fontSize: 12)),
                  ])),
                  IconButton(
                    icon: const Icon(Icons.logout, color: _textSub),
                    onPressed: () async {
                      UserService().clearCache();
                      await _auth.signOut();
                    },
                  ),
                ]),
              ),

              const SizedBox(height: 14),

              // ── Start Recording button ─────────────────────────────────
              GestureDetector(
                onTap: () async {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const CameraScreen()));
                  _load();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 22),
                  decoration: BoxDecoration(
                    color: Colors.black,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _green.withValues(alpha: 0.6), width: 1.5),
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(width: 48, height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _green, width: 2),
                      ),
                      child: const Icon(Icons.videocam, color: _green, size: 24)),
                    const SizedBox(width: 14),
                    const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Start Recording',
                          style: TextStyle(color: Colors.white, fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      Text('Tap to open camera',
                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                  ]),
                ),
              ),

              const SizedBox(height: 14),

              // ── Metrics row: Total | Local | Synced ───────────────────
              Row(children: [
                _StatCard(
                  label: 'Recordings',
                  value: '$_totalRecordings',
                  icon: Icons.video_library_outlined,
                  color: _green,
                ),
                const SizedBox(width: 10),
                _StatCard(
                  label: 'Total Time',
                  value: _fmtSecs(_totalSecs),
                  icon: Icons.timer_outlined,
                  color: Colors.blue,
                ),
              ]),

              const SizedBox(height: 10),

              Row(children: [
                _StatCard(
                  label: 'Local',
                  value: '$_localCount',
                  icon: Icons.phone_android,
                  color: Colors.orange,
                ),
                const SizedBox(width: 10),
                _StatCard(
                  label: 'Synced',
                  value: '$_syncedCount',
                  icon: Icons.cloud_done_outlined,
                  color: _green,
                ),
              ]),

              const SizedBox(height: 14),

              // ── My Recordings link ─────────────────────────────────────
              GestureDetector(
                onTap: () async {
                  await Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const HistoryScreen()));
                  _load();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(color: _card,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _border)),
                  child: Row(children: [
                    const Icon(Icons.history, color: _green, size: 22),
                    const SizedBox(width: 12),
                    const Expanded(child: Text('My Recordings',
                        style: TextStyle(color: _text, fontSize: 15,
                            fontWeight: FontWeight.w600))),
                    Text('$_totalRecordings video${_totalRecordings != 1 ? 's' : ''}',
                        style: const TextStyle(color: _textSub, fontSize: 13)),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right, color: _textSub, size: 18),
                  ]),
                ),
              ),

              const SizedBox(height: 14),

              // ── Attendance card ────────────────────────────────────────
              Container(
                decoration: BoxDecoration(color: _card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _border)),
                child: Column(children: [
                  // Header row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                    child: Row(children: [
                      const Icon(Icons.calendar_month, color: _green, size: 20),
                      const SizedBox(width: 10),
                      const Text('Daily Record',
                          style: TextStyle(color: _text, fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const Spacer(),
                      // Filter dropdown
                      GestureDetector(
                        onTap: _showFilterSheet,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: _green.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _green.withValues(alpha: 0.4))),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Text(_filter.label,
                                style: const TextStyle(color: _green, fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 4),
                            const Icon(Icons.keyboard_arrow_down, color: _green, size: 16),
                          ]),
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: () => setState(() => _attExpanded = !_attExpanded),
                        child: Icon(_attExpanded
                            ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                            color: _textSub, size: 22)),
                    ]),
                  ),

                  // Summary chips
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Row(children: [
                      _Chip(Icons.repeat, '$_filteredSessions session${_filteredSessions != 1 ? 's' : ''}'),
                      const SizedBox(width: 8),
                      _Chip(Icons.timer, _fmtSecs(_filteredSecs)),
                    ]),
                  ),

                  // Expanded day entries
                  if (_attExpanded && _filteredEntries.isNotEmpty) ...[
                    const Divider(height: 1, color: _border),
                    ..._filteredEntries.map((e) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(children: [
                        Text(e.date, style: const TextStyle(
                            color: _text, fontSize: 13, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        Text('${e.sessions} session${e.sessions != 1 ? 's' : ''}',
                            style: const TextStyle(color: _textSub, fontSize: 12)),
                        const SizedBox(width: 12),
                        Text(_fmtSecs(e.totalSeconds),
                            style: const TextStyle(color: _green, fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ]),
                    )),
                    const SizedBox(height: 4),
                  ],
                  if (_attExpanded && _filteredEntries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Text('No records for this period',
                          style: TextStyle(color: _textSub, fontSize: 13))),
                ]),
              ),

              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }

  void _showFilterSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(mainAxisSize: MainAxisSize.min,
          children: _AttFilter.values.map((f) => ListTile(
            leading: Icon(f == _filter ? Icons.radio_button_checked : Icons.radio_button_off,
                color: f == _filter ? _green : _textSub),
            title: Text(f.label,
                style: TextStyle(
                    color: f == _filter ? _green : _text,
                    fontWeight: f == _filter ? FontWeight.w700 : FontWeight.w400)),
            onTap: () {
              setState(() { _filter = f; _applyFilter(); });
              Navigator.pop(context);
            },
          )).toList()),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _StatCard({required this.label, required this.value,
      required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 24),
      const SizedBox(height: 8),
      Text(value, style: TextStyle(color: color, fontSize: 22,
          fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: _textSub, fontSize: 11)),
    ]),
  ));
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Chip(this.icon, this.label);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: _green.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: _green.withValues(alpha: 0.25))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: _green, size: 14),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(color: _green, fontSize: 12,
          fontWeight: FontWeight.w600)),
    ]),
  );
}