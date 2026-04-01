import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/local_video_storage.dart';
import '../services/attendance_service.dart';
import 'camera_screen.dart';
import 'history_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final _auth = AuthService();
  final _storage = LocalVideoStorage();
  final _attendance = AttendanceService();

  int _sessions = 0;
  int _totalSecs = 0;
  List<AttendanceEntry> _attendanceEntries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser!;
    final email = user.email ?? user.uid;
    final count = await _storage.sessionCount(email);
    final secs = await _storage.totalDurationSeconds(email);
    final entries = await _attendance.getEntries();
    if (mounted) setState(() {
      _sessions = count;
      _totalSecs = secs;
      _attendanceEntries = entries.take(7).toList(); // show last 7 days
    });
  }

  String _fmtSecs(int secs) {
    if (secs == 0) return '0s';
    if (secs < 60) return '${secs}s';
    final m = secs ~/ 60;
    final s = secs % 60;
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser!;
    final name = (user.email ?? 'User').split('@').first;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Hello, $name 👋',
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  const Text('Ready to record?',
                      style: TextStyle(color: Colors.white38, fontSize: 14)),
                ])),
                IconButton(
                  icon: const Icon(Icons.logout_rounded, color: Colors.white38),
                  onPressed: _auth.signOut,
                ),
              ]),
              const SizedBox(height: 28),

              // ── Stats row ─────────────────────────────────────────────
              Row(children: [
                Expanded(child: _stat(
                  icon: Icons.video_collection_rounded,
                  value: '$_sessions',
                  label: 'My Recordings',
                  color: const Color(0xFF4F8EF7),
                )),
                const SizedBox(width: 12),
                Expanded(child: _stat(
                  icon: Icons.timer_rounded,
                  value: _fmtSecs(_totalSecs),
                  label: 'Total Recorded',
                  color: const Color(0xFF7C6FF7),
                )),
              ]),
              const SizedBox(height: 12),

              // Note
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white.withOpacity(0.06)),
                ),
                child: Row(children: const [
                  Icon(Icons.storage_rounded, color: Colors.white24, size: 16),
                  SizedBox(width: 8),
                  Expanded(child: Text(
                    'Videos saved locally in 2-min blocks. No internet required.',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  )),
                ]),
              ),
              const SizedBox(height: 28),

              // ── Record button ─────────────────────────────────────────
              GestureDetector(
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CameraScreen()),
                ).then((_) => _load()),
                child: Container(
                  width: double.infinity, height: 170,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF4F8EF7), Color(0xFF7C6FF7)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [BoxShadow(
                      color: const Color(0xFF4F8EF7).withOpacity(0.35),
                      blurRadius: 24, offset: const Offset(0, 8),
                    )],
                  ),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(width: 60, height: 60,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
                      child: const Icon(Icons.videocam_rounded, color: Colors.white, size: 30)),
                    const SizedBox(height: 10),
                    const Text('Start Recording',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    const Text('Tap to open camera',
                        style: TextStyle(color: Colors.white60, fontSize: 13)),
                  ]),
                ),
              ),
              const SizedBox(height: 16),

              // ── History tile ──────────────────────────────────────────
              GestureDetector(
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
                ).then((_) => _load()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141420), borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.history_rounded, color: Color(0xFF4F8EF7), size: 24),
                    const SizedBox(width: 14),
                    const Expanded(child: Text('My Recordings',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500))),
                    Text('$_sessions video${_sessions == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white38, fontSize: 13)),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded, color: Colors.white24, size: 20),
                  ]),
                ),
              ),
              const SizedBox(height: 24),

              // ── Attendance section ────────────────────────────────────
              if (_attendanceEntries.isNotEmpty) ...[
                const Text('Active Participation',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                const Text('Your daily recording activity',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
                const SizedBox(height: 12),
                ..._attendanceEntries.map((e) => _attendanceRow(e)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _stat({required IconData icon, required String value,
      required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.15)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 10),
        Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 12)),
      ]),
    );
  }

  Widget _attendanceRow(AttendanceEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF141420), borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.date, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
          const SizedBox(height: 3),
          Text('${e.sessions} session${e.sessions == 1 ? '' : 's'}  ·  avg ${e.avgStr}',
              style: const TextStyle(color: Colors.white38, fontSize: 12)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(e.totalStr,
              style: const TextStyle(color: Color(0xFF4F8EF7), fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${e.firstSession} – ${e.lastSession}',
              style: const TextStyle(color: Colors.white24, fontSize: 10)),
        ]),
      ]),
    );
  }
}