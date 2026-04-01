import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/local_video_storage.dart';
import '../services/attendance_service.dart';
import '../services/processing_manager.dart';
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
  final _procManager = ProcessingManager();

  int _sessions = 0;
  int _totalSecs = 0;
  List<AttendanceEntry> _attendance7 = [];

  // Processing jobs stream snapshot
  Map<String, ProcessingStatus> _jobs = {};

  @override
  void initState() {
    super.initState();
    _load();

    // Start with current jobs snapshot
    _jobs = _procManager.current;

    // Listen to live processing updates
    _procManager.stream.listen((jobs) {
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
    final secs = await _storage.totalDurationSeconds(email);
    final entries = await _attendance.getEntries();
    if (mounted) setState(() {
      _sessions = count;
      _totalSecs = secs;
      _attendance7 = entries.take(7).toList();
    });
  }

  String _fmtSecs(int s) {
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
      backgroundColor: const Color(0xFF0F0F0F),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header ────────────────────────────────────────────────
              Row(children: [
                // OTN Logo mark
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8620A).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE8620A).withOpacity(0.4)),
                  ),
                  child: const Center(
                    child: Text('OTN',
                        style: TextStyle(
                          color: Color(0xFFE8620A),
                          fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Hello, $name',
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700)),
                  const Text('Omni Trade Networks',
                      style: TextStyle(color: Colors.white30, fontSize: 11, letterSpacing: 0.8)),
                ])),
                IconButton(
                  icon: const Icon(Icons.logout_rounded, color: Colors.white30, size: 20),
                  onPressed: _auth.signOut,
                ),
              ]),
              const SizedBox(height: 24),

              // ── Processing queue (shown only when jobs exist) ─────────
              if (activeJobs.isNotEmpty || recentJobs.isNotEmpty) ...[
                _sectionLabel('Processing'),
                const SizedBox(height: 8),
                ...activeJobs.map((j) => _processingCard(j)),
                ...recentJobs.map((j) => _processingCard(j)),
                const SizedBox(height: 20),
              ],

              // ── Stats ─────────────────────────────────────────────────
              Row(children: [
                Expanded(child: _stat(
                  icon: Icons.video_collection_rounded,
                  value: '$_sessions',
                  label: 'Recordings',
                  color: const Color(0xFFE8620A),
                )),
                const SizedBox(width: 12),
                Expanded(child: _stat(
                  icon: Icons.timer_rounded,
                  value: _fmtSecs(_totalSecs),
                  label: 'Total Recorded',
                  color: const Color(0xFFFF9D4A),
                )),
              ]),
              const SizedBox(height: 24),

              // ── Record button ─────────────────────────────────────────
              GestureDetector(
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CameraScreen()),
                ).then((_) => _load()),
                child: Container(
                  width: double.infinity, height: 160,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE8620A), Color(0xFFB84500)],
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [BoxShadow(
                      color: const Color(0xFFE8620A).withOpacity(0.4),
                      blurRadius: 20, offset: const Offset(0, 8),
                    )],
                  ),
                  child: Stack(children: [
                    // Subtle texture circles
                    Positioned(right: -20, top: -20,
                      child: Container(width: 120, height: 120,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withOpacity(0.05)))),
                    Positioned(right: 40, bottom: -30,
                      child: Container(width: 80, height: 80,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withOpacity(0.04)))),
                    Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Container(width: 56, height: 56,
                        decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15), shape: BoxShape.circle),
                        child: const Icon(Icons.videocam_rounded, color: Colors.white, size: 28)),
                      const SizedBox(height: 10),
                      const Text('Start Recording',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(activeJobs.isNotEmpty
                          ? '${activeJobs.length} video${activeJobs.length == 1 ? '' : 's'} processing in background'
                          : 'Tap to open camera',
                          style: const TextStyle(color: Colors.white60, fontSize: 12)),
                    ])),
                  ]),
                ),
              ),
              const SizedBox(height: 14),

              // ── History tile ──────────────────────────────────────────
              GestureDetector(
                onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const HistoryScreen()),
                ).then((_) => _load()),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.06)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.history_rounded, color: Color(0xFFE8620A), size: 22),
                    const SizedBox(width: 14),
                    const Expanded(child: Text('My Recordings',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500))),
                    Text('$_sessions video${_sessions == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white30, fontSize: 13)),
                    const SizedBox(width: 8),
                    Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(0.20), size: 20),
                  ]),
                ),
              ),

              // ── Attendance ────────────────────────────────────────────
              if (_attendance7.isNotEmpty) ...[
                const SizedBox(height: 24),
                _sectionLabel('Active Participation'),
                const SizedBox(height: 10),
                ..._attendance7.map(_attendanceRow),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── Processing card ────────────────────────────────────────────────────────

  Widget _processingCard(ProcessingStatus j) {
    final isActive = j.isActive;
    final isDone = j.isDone;
    final isError = j.isError;

    Color accent = isActive
        ? const Color(0xFFE8620A)
        : isDone ? Colors.greenAccent : Colors.redAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accent.withOpacity(0.25)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (isActive)
            SizedBox(width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: accent))
          else
            Icon(isDone ? Icons.check_circle_rounded : Icons.error_rounded,
                color: accent, size: 16),
          const SizedBox(width: 10),
          Expanded(child: Text(j.message,
              style: TextStyle(color: isDone ? Colors.greenAccent : Colors.white70,
                  fontSize: 13, fontWeight: FontWeight.w500))),
          Text(j.stateLabel,
              style: TextStyle(color: accent, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        if (isActive) ...[
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: j.progress,
              minHeight: 3,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          if (j.totalBlocks > 0) ...[
            const SizedBox(height: 6),
            Row(children: List.generate(j.totalBlocks, (i) {
              Color c = i < j.currentBlock - 1
                  ? Colors.greenAccent
                  : i == j.currentBlock - 1 ? accent : Colors.white12;
              return Container(
                width: 8, height: 8, margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(shape: BoxShape.circle, color: c));
            })),
          ],
        ],
      ]),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(
          color: Colors.white54, fontSize: 11,
          fontWeight: FontWeight.w600, letterSpacing: 1.2));

  Widget _stat({required IconData icon, required String value,
      required String label, required Color color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.07), borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(height: 10),
        Text(value, style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white30, fontSize: 11)),
      ]),
    );
  }

  Widget _attendanceRow(AttendanceEntry e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A), borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.date,
              style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 3),
          Text('${e.sessions} session${e.sessions == 1 ? '' : 's'}  ·  avg ${e.avgStr}',
              style: const TextStyle(color: Colors.white30, fontSize: 11)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(e.totalStr,
              style: const TextStyle(color: Color(0xFFE8620A), fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('${e.firstSession} – ${e.lastSession}',
              style: const TextStyle(color: Colors.white12, fontSize: 10)),
        ]),
      ]),
    );
  }
}