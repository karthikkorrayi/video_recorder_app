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
  List<AttendanceEntry> _entries = [];
  Map<String, ProcessingStatus> _jobs = {};

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
    if (mounted) setState(() {
      _sessions = count;
      _totalSecs = secs;
      _entries   = ent.take(7).toList();
    });
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
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── Header ──────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: _border),
                ),
                child: Row(children: [
                  // Omnitrix mini logo
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                      color: _black,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _green, width: 2),
                    ),
                    child: const Center(
                      child: Text('OTN',
                          style: TextStyle(color: _green, fontSize: 9,
                              fontWeight: FontWeight.w800, letterSpacing: 1)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Hello, $name',
                        style: const TextStyle(color: _text, fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    const Text('Omni Trade Networks',
                        style: TextStyle(color: _textSub, fontSize: 11,
                            letterSpacing: 0.5)),
                  ])),
                  IconButton(
                    icon: const Icon(Icons.logout_rounded, color: _textSub, size: 20),
                    onPressed: _auth.signOut,
                  ),
                ]),
              ),
              const SizedBox(height: 14),

              // ── RECORD BUTTON (top, not middle) ─────────────────────────
              // Placed at top so it's away from phone stand & nav bar
              GestureDetector(
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CameraScreen()),
                ).then((_) => _load()),
                child: Container(
                  width: double.infinity, height: 110,
                  decoration: BoxDecoration(
                    color: _black,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _green, width: 2),
                    boxShadow: [
                      BoxShadow(color: _green.withOpacity(0.2),
                          blurRadius: 16, spreadRadius: 1)
                    ],
                  ),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    // Omnitrix dial circle
                    Container(
                      width: 62, height: 62,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _green.withOpacity(0.12),
                        border: Border.all(color: _green, width: 2.5),
                      ),
                      child: const Icon(Icons.videocam_rounded,
                          color: _green, size: 28),
                    ),
                    const SizedBox(width: 18),
                    Column(mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Start Recording',
                          style: TextStyle(color: Colors.white, fontSize: 18,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(
                        activeJobs.isNotEmpty
                            ? '${activeJobs.length} processing in background'
                            : 'Tap to open camera',
                        style: TextStyle(
                            color: activeJobs.isNotEmpty ? _green : Colors.white54,
                            fontSize: 12),
                      ),
                    ]),
                  ]),
                ),
              ),
              const SizedBox(height: 14),

              // ── Processing queue ─────────────────────────────────────────
              if (activeJobs.isNotEmpty || recentJobs.isNotEmpty) ...[
                _sectionLabel('Processing'),
                const SizedBox(height: 8),
                ...activeJobs.map(_processingCard),
                ...recentJobs.map(_processingCard),
                const SizedBox(height: 14),
              ],

              // ── Stats row ────────────────────────────────────────────────
              Row(children: [
                Expanded(child: _stat(
                    icon: Icons.video_collection_rounded,
                    value: '$_sessions', label: 'Recordings', color: _green)),
                const SizedBox(width: 12),
                Expanded(child: _stat(
                    icon: Icons.timer_rounded,
                    value: _fmt(_totalSecs), label: 'Total Recorded',
                    color: const Color(0xFF0091EA))),
              ]),
              const SizedBox(height: 14),

              // ── History tile ─────────────────────────────────────────────
              GestureDetector(
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
                ).then((_) => _load()),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: _border),
                  ),
                  child: Row(children: [
                    Icon(Icons.history_rounded, color: _green, size: 22),
                    const SizedBox(width: 14),
                    Expanded(child: const Text('My Recordings',
                        style: TextStyle(color: _text, fontSize: 15,
                            fontWeight: FontWeight.w600))),
                    Text('$_sessions video${_sessions == 1 ? '' : 's'}',
                        style: const TextStyle(color: _textSub, fontSize: 13)),
                    const SizedBox(width: 6),
                    const Icon(Icons.chevron_right_rounded,
                        color: _textSub, size: 20),
                  ]),
                ),
              ),

              // ── Attendance ───────────────────────────────────────────────
              if (_entries.isNotEmpty) ...[
                const SizedBox(height: 20),
                _sectionLabel('Active Participation'),
                const SizedBox(height: 10),
                ..._entries.map(_attendanceRow),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _processingCard(ProcessingStatus j) {
    final isActive = j.isActive;
    final Color accent = isActive ? _green : j.isDone ? Colors.green : Colors.red;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (isActive)
            SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: accent))
          else
            Icon(j.isDone ? Icons.check_circle_rounded : Icons.error_rounded,
                color: accent, size: 16),
          const SizedBox(width: 10),
          Expanded(child: Text(j.message,
              style: TextStyle(color: j.isDone ? Colors.green : _text,
                  fontSize: 13, fontWeight: FontWeight.w500))),
          Text(j.stateLabel,
              style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        if (isActive) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: j.progress, minHeight: 4,
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _sectionLabel(String t) => Text(t,
      style: const TextStyle(color: _textSub, fontSize: 11,
          fontWeight: FontWeight.w700, letterSpacing: 1.2));

  Widget _stat({required IconData icon, required String value,
      required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 10),
        Text(value, style: TextStyle(color: color, fontSize: 20,
            fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: _textSub, fontSize: 11)),
      ]),
    );
  }

  Widget _attendanceRow(AttendanceEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _border),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.date, style: const TextStyle(color: _text, fontSize: 13,
              fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
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
}