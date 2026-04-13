import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:intl/intl.dart';
import '../services/auth_service.dart';
import '../services/session_store.dart';
import '../services/user_service.dart';
import '../models/session_model.dart';
import 'camera_screen.dart';
import 'history_screen.dart';

const _green   = Color(0xFF00C853);
const _surface = Color(0xFFF4F6F8);
const _card    = Color(0xFFFFFFFF);
const _text    = Color(0xFF1A1A1A);
const _textSub = Color(0xFF666666);
const _border  = Color(0xFFE0E0E0);

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _auth       = AuthService();
  final _store      = SessionStore();

  // All raw data
  List<SessionModel>    _allSessions = [];
  String _displayName = '';

  // ── Selected date range — default is today ─────────────────────────────
  late DateTime _rangeStart;
  late DateTime _rangeEnd;
  String _rangeLabel = 'Today';

  @override
  void initState() {
    super.initState();
    // Default: today
    final now = DateTime.now();
    _rangeStart = DateTime(now.year, now.month, now.day);
    _rangeEnd   = _rangeStart;
    _load();
  }

  Future<void> _load() async {
    final name       = await UserService().getDisplayName();
    final sessions   = await _store.getAll();
    if (mounted) setState(() {
      _displayName = name;
      _allSessions = sessions;
    });
  }

  // ── Filtering helpers ───────────────────────────────────────────────────
  bool _inRange(DateTime dt) {
    final d = DateTime(dt.year, dt.month, dt.day);
    return !d.isBefore(_rangeStart) && !d.isAfter(_rangeEnd);
  }

  List<SessionModel> get _filteredSessions =>
      _allSessions.where((s) => _inRange(s.createdAt)).toList();


  // Metrics for filtered range
  int get _recordingCount  => _filteredSessions.length;
  int get _localCount      => _filteredSessions.where((s) => s.status != 'synced').length;
  int get _syncedCount     => _filteredSessions.where((s) => s.status == 'synced').length;
  int get _totalSecs       => _filteredSessions.fold(0, (s, e) => s + e.durationSeconds);

  String _fmt(int secs) {
    if (secs == 0) return '0s';
    if (secs < 60) return '${secs}s';
    final h = secs ~/ 3600;
    final m = (secs % 3600) ~/ 60;
    final s = secs % 60;
    if (h > 0) return s > 0 ? '${h}h ${m}m' : '${h}h ${m}m';
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  // ── Calendar picker ─────────────────────────────────────────────────────
  Future<void> _openCalendar() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: DateTimeRange(start: _rangeStart, end: _rangeEnd),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: _green)),
        child: child!),
    );

    if (picked != null) {
      final s = picked.start;
      final e = picked.end;
      String label;
      final today  = DateTime(now.year, now.month, now.day);
      final yest   = today.subtract(const Duration(days: 1));
      final startD = DateTime(s.year, s.month, s.day);
      final endD   = DateTime(e.year, e.month, e.day);

      if (startD == today && endD == today) {
        label = 'Today';
      } else if (startD == yest && endD == yest) {
        label = 'Yesterday';
      } else if (startD == endD) {
        label = DateFormat('d MMM yyyy').format(s);
      } else {
        label = '${DateFormat('d MMM').format(s)} – ${DateFormat('d MMM yyyy').format(e)}';
      }

      setState(() {
        _rangeStart = startD;
        _rangeEnd   = endD;
        _rangeLabel = label;
      });
    }
  }

  // Quick presets
  void _setPreset(String preset) {
    final now   = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime s, e;
    switch (preset) {
      case 'today':
        s = today; e = today;
        _rangeLabel = 'Today';
        break;
      case 'yesterday':
        s = today.subtract(const Duration(days: 1));
        e = s;
        _rangeLabel = 'Yesterday';
        break;
      case 'week':
        s = today.subtract(Duration(days: today.weekday - 1));
        e = today;
        _rangeLabel = 'This Week';
        break;
      case 'month':
        s = DateTime(now.year, now.month, 1);
        e = today;
        _rangeLabel = 'This Month';
        break;
      case 'all':
        s = DateTime(2020); e = today;
        _rangeLabel = 'All Time';
        break;
      default: return;
    }
    setState(() { _rangeStart = s; _rangeEnd = e; });
  }

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

              // ── Header ─────────────────────────────────────────────────
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
                    Text(_displayName.isEmpty ? 'Hello!' : 'Hello, $_displayName',
                        style: const TextStyle(color: _text, fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const Text('Omni Trade Networks',
                        style: TextStyle(color: _textSub, fontSize: 12)),
                  ])),
                  IconButton(
                    icon: const Icon(Icons.logout, color: _textSub),
                    onPressed: () async {
                      UserService().clearCache();
                      await _auth.signOut();
                    }),
                ]),
              ),

              const SizedBox(height: 14),

              // ── Start Recording ─────────────────────────────────────────
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
                    border: Border.all(color: _green.withValues(alpha: 0.6), width: 1.5)),
                  child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    CircleAvatar(backgroundColor: Colors.transparent,
                      child: Icon(Icons.videocam, color: _green, size: 28)),
                    SizedBox(width: 14),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Start Recording',
                          style: TextStyle(color: Colors.white, fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      Text('Tap to open camera',
                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                  ]),
                ),
              ),

              const SizedBox(height: 16),

              // ── Date filter row ─────────────────────────────────────────
              // Calendar icon + range label + quick presets
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(color: _card,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    // Calendar icon button
                    GestureDetector(
                      onTap: _openCalendar,
                      child: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: _green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: _green.withValues(alpha: 0.3))),
                        child: const Icon(Icons.calendar_month,
                            color: _green, size: 20)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: GestureDetector(
                      onTap: _openCalendar,
                      child: Text(_rangeLabel,
                          style: const TextStyle(color: _text, fontSize: 15,
                              fontWeight: FontWeight.w700)),
                    )),
                    // Edit icon hint
                    GestureDetector(
                      onTap: _openCalendar,
                      child: const Icon(Icons.edit_calendar_outlined,
                          color: _textSub, size: 18)),
                  ]),
                  const SizedBox(height: 10),
                  // Quick preset chips
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      _Preset('Today',     () => _setPreset('today'),     _rangeLabel == 'Today'),
                      _Preset('Yesterday', () => _setPreset('yesterday'), _rangeLabel == 'Yesterday'),
                      _Preset('This Week', () => _setPreset('week'),      _rangeLabel == 'This Week'),
                      _Preset('This Month',() => _setPreset('month'),     _rangeLabel == 'This Month'),
                      _Preset('All Time',  () => _setPreset('all'),       _rangeLabel == 'All Time'),
                    ]),
                  ),
                ]),
              ),

              const SizedBox(height: 12),

              // ── Metrics (filtered by date range) ───────────────────────
              Row(children: [
                _StatCard(
                  label: 'Recordings',
                  value: '$_recordingCount',
                  sub: _fmt(_totalSecs),
                  icon: Icons.video_library_outlined,
                  color: _green,
                ),
                const SizedBox(width: 10),
                _StatCard(
                  label: 'Total Time',
                  value: _fmt(_totalSecs),
                  sub: '$_recordingCount recording${_recordingCount != 1 ? 's' : ''}',
                  icon: Icons.timer_outlined,
                  color: Colors.blue,
                ),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                _StatCard(
                  label: 'Local',
                  value: '$_localCount',
                  sub: 'not yet uploaded',
                  icon: Icons.phone_android,
                  color: Colors.orange,
                ),
                const SizedBox(width: 10),
                _StatCard(
                  label: 'Synced',
                  value: '$_syncedCount',
                  sub: 'on OneDrive',
                  icon: Icons.cloud_done_outlined,
                  color: _green,
                ),
              ]),

              const SizedBox(height: 14),

              // ── My Recordings link ──────────────────────────────────────
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
                    Text('$_recordingCount video${_recordingCount != 1 ? 's' : ''}',
                        style: const TextStyle(color: _textSub, fontSize: 13)),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right, color: _textSub, size: 18),
                  ]),
                ),
              ),

              const SizedBox(height: 24),
            ]),
          ),
        ),
      ),
    );
  }
}

// ── Preset chip ───────────────────────────────────────────────────────────────
class _Preset extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool active;
  const _Preset(this.label, this.onTap, this.active);

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: active ? _green : _surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: active ? _green : _border)),
      child: Text(label,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600,
              color: active ? Colors.white : _textSub)),
    ),
  );
}

// ── Stat card ─────────────────────────────────────────────────────────────────
class _StatCard extends StatelessWidget {
  final String label, value;
  final String? sub;
  final IconData icon;
  final Color color;
  const _StatCard({required this.label, required this.value,
      required this.icon, required this.color, this.sub});

  @override
  Widget build(BuildContext context) => Expanded(child: Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 22),
      const SizedBox(height: 8),
      Text(value, style: TextStyle(color: color, fontSize: 22,
          fontWeight: FontWeight.bold)),
      const SizedBox(height: 2),
      Text(label, style: const TextStyle(color: _textSub, fontSize: 11,
          fontWeight: FontWeight.w600)),
      if (sub != null) ...[
        const SizedBox(height: 2),
        Text(sub!, style: const TextStyle(color: _textSub, fontSize: 10),
            overflow: TextOverflow.ellipsis),
      ],
    ]),
  ));
}