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
  static const _orange = Colors.orange;

  final _queue = ChunkUploadQueue();
  final _cache = CloudCacheService();

  DateFilter _filter          = DateFilter.today;
  String     _userDisplayName = '';
  Timer?     _syncTimer;
  Timer?     _bannerTimer;
  bool       _showBanner      = false;
  int        _banneredCount   = 0;

  @override
  void initState() {
    super.initState();
    _init();
    _cache.stream.listen(_onCacheState);
  }

  Future<void> _init() async {
    _userDisplayName = await UserService().getDisplayName();
    OneDriveService.startBackgroundSync();
    await _cache.init();
    _syncTimer = Timer.periodic(const Duration(minutes: 5), (_) => _cache.syncNow());
    if (mounted) setState(() {});
  }

  void _onCacheState(CacheState s) {
    if (!mounted) return;
    final completed = s.lastUploadCompletedAt;
    if (completed != null &&
        DateTime.now().difference(completed).inSeconds < 10 &&
        s.files.length != _banneredCount) {
      _banneredCount = s.files.length;
      _bannerTimer?.cancel();
      setState(() => _showBanner = true);
      _bannerTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _showBanner = false);
      });
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _bannerTimer?.cancel();
    super.dispose();
  }

  Future<void> _manualRefresh() async {
    await _cache.syncNow();
    if (mounted) setState(() {});
  }

  void _applyFilter(DateFilter f) => setState(() => _filter = f);

  // ── Folder for current filter ─────────────────────────────────────────────

  String _folderForFilter() {
    final now = DateTime.now();
    if (_filter.type == FilterType.yesterday) {
      final y = now.subtract(const Duration(days: 1));
      return '${y.day.toString().padLeft(2,'0')}-${y.month.toString().padLeft(2,'0')}-${y.year}';
    }
    return '${now.day.toString().padLeft(2,'0')}-${now.month.toString().padLeft(2,'0')}-${now.year}';
  }

  // ── Issue 1+2: Metrics in seconds ────────────────────────────────────────

  /// Total recorded time for filter — from cloud cache (seconds), fallback queue
  int get _recordedSecs {
    final cloudSecs = _cache.totalSecsForFolder(_folderForFilter());
    if (cloudSecs > 0) return cloudSecs;
    // Fallback: actual elapsed from done queue chunks
    return _queue.all
        .where((s) => s.status == ChunkStatus.done)
        .fold(0, (s, e) => s + e.chunk.durationSecs);
  }

  int get _sessionCount {
    final cloud = _cache.sessionCountForFolder(_folderForFilter());
    if (cloud > 0) return cloud;
    return _queue.all.map((s) => s.chunk.sessionId).toSet().length;
  }

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
            child: Column(children: [
              _buildHeader(),
              const SizedBox(height: 16),
              _buildStartRecording(),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: _showBanner ? _buildBanner() : const SizedBox.shrink(),
              ),
              if (_showBanner) const SizedBox(height: 16),
              _buildFilterSection(),
              const SizedBox(height: 12),
              _buildMetrics(),
              const SizedBox(height: 16),
              _buildMyRecordingsCard(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() => Container(
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
      IconButton(
        icon: const Icon(Icons.logout, color: Colors.grey),
        onPressed: () { UserService().clearCache(); FirebaseAuth.instance.signOut(); },
      ),
    ]),
  );

  Widget _buildStartRecording() => GestureDetector(
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

  Widget _buildBanner() => Container(
    key: const ValueKey('banner'),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(12)),
    child: Row(children: [
      const Icon(Icons.cloud_done, color: _green, size: 16), const SizedBox(width: 8),
      Text('${_cache.files.length} file(s) uploaded \u2713',
          style: const TextStyle(color: _green, fontWeight: FontWeight.w600, fontSize: 13)),
      const Spacer(),
      const Text('Just now', style: TextStyle(color: _green, fontSize: 12)),
    ]),
  );

  Widget _buildFilterSection() => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.calendar_month, color: _green, size: 20), const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(12)),
          child: Text(_cache.lastSyncLabel, style: const TextStyle(color: _green, fontSize: 12)),
        ),
        const SizedBox(width: 8),
        Text(_filter.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      ]),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          ...[DateFilter.today, DateFilter.yesterday, DateFilter.thisWeek, DateFilter.thisMonth]
              .map((f) => _DashChip(label: f.label, selected: _filter.type == f.type, onTap: () => _applyFilter(f))),
          _CalendarChip(selected: _filter.type == FilterType.custom,
              label: _filter.type == FilterType.custom ? _filter.label : null, onTap: _pickCustomRange),
        ]),
      ),
    ]),
  );

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, 1),
      lastDate: DateTime(now.year, now.month + 1, 0),
      builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(colorScheme: const ColorScheme.light(primary: _green)), child: child!),
    );
    if (picked != null) _applyFilter(DateFilter(FilterType.custom, from: picked.start, to: picked.end));
  }

  Widget _buildMetrics() {
    return StreamBuilder<CacheState>(
      stream: _cache.stream,
      builder: (_, __) => StreamBuilder<List<ChunkState>>(
        stream: _queue.stream,
        builder: (_, __) {
          // Issue 1+2: use seconds for accurate display
          final recSecs  = _recordedSecs;
          final sessions = _sessionCount;
          final pendSecs = _queue.pendingSecs;

          return Column(children: [
            Row(children: [
              Expanded(child: _Tile(
                icon: Icons.timer_outlined,
                value: fmtDuration(recSecs),  // Issue 1: shows '10s', '1m 2s', '5m'
                label: '${_filter.label} recorded',
                color: _green,
                loading: _cache.isSyncing && recSecs == 0,
              )),
              const SizedBox(width: 12),
              Expanded(child: _Tile(
                icon: Icons.play_circle_outline,
                value: '$sessions',
                label: sessions == 1 ? '1 session' : '$sessions sessions',
                color: Colors.blue,
                loading: _cache.isSyncing && sessions == 0,
              )),
            ]),
            if (pendSecs > 0) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: _orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _orange.withValues(alpha: 0.3)),
                ),
                child: Row(children: [
                  Icon(Icons.cloud_upload_outlined, color: _orange, size: 16),
                  const SizedBox(width: 8),
                  // Issue 2: shows actual elapsed time, not 2-min multiples
                  Text('${fmtDuration(pendSecs)} pending upload',
                      style: TextStyle(color: _orange, fontSize: 12, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('${_queue.pendingCount} chunk${_queue.pendingCount == 1 ? '' : 's'}',
                      style: TextStyle(color: Colors.orange[300], fontSize: 11)),
                ]),
              ),
            ],
          ]);
        },
      ),
    );
  }

  Widget _buildMyRecordingsCard() => GestureDetector(
    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => HistoryScreen(initialFilter: _filter))),
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

class _Tile extends StatelessWidget {
  final IconData icon; final String value, label; final Color color; final bool loading;
  const _Tile({required this.icon, required this.value, required this.label, required this.color, this.loading = false});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.2)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: color, size: 20), const SizedBox(height: 8),
      loading ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: color))
              : Text(value, style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(height: 2),
      Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 11)),
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
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(color: selected ? Colors.white : Colors.grey[700], fontWeight: selected ? FontWeight.w600 : FontWeight.normal, fontSize: 13)),
    ),
  );
}

class _CalendarChip extends StatelessWidget {
  final bool selected; final VoidCallback onTap; final String? label;
  const _CalendarChip({required this.selected, required this.onTap, this.label});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF00C853) : Colors.transparent,
        border: Border.all(color: selected ? const Color(0xFF00C853) : Colors.grey[300]!),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.calendar_today, size: 14, color: selected ? Colors.white : Colors.grey[600]),
        if (label != null) ...[const SizedBox(width: 4), Text(label!, style: TextStyle(color: selected ? Colors.white : Colors.grey[700], fontSize: 12))],
      ]),
    ),
  );
}