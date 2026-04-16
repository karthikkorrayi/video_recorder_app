import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/session_model.dart';
import '../services/upload_service.dart';
import '../services/session_store.dart';
import '../services/notification_service.dart';
import '../services/upload_resume_service.dart';
import '../services/backend_keepalive.dart';

// ── Singleton upload manager — survives navigation ────────────────────────────
class _UploadManager {
  static final _UploadManager _i = _UploadManager._();
  factory _UploadManager() => _i;
  _UploadManager._();

  final _service  = UploadService();
  final _notif    = NotificationService();
  final _resume   = UploadResumeService();
  bool isRunning = false;
  String? activeSessionId;

  final _ctrl = StreamController<_UploadState>.broadcast();
  Stream<_UploadState> get stream => _ctrl.stream;
  _UploadState _state = const _UploadState();
  _UploadState get current => _state;

  void _emit(_UploadState s) { _state = s; _ctrl.add(s); }

  Future<void> start(SessionModel session, SessionStore store) async {
    if (isRunning && activeSessionId == session.id) return;
    isRunning = true;
    activeSessionId = session.id;
    _emit(_UploadState(
      statusText: 'Starting upload...',
      totalBlocks: 1, // always 1 — full file uploads as single item
      uploadedBlocks: [],
    ));

    await store.updateStatus(session.id, 'uploading');

    // ── Wake backend before upload (prevents cold start failure) ─────────
    _emit(_state.copyWith(statusText: 'Connecting to server...'));
    await BackendKeepAlive().wakeNow();

    // ── Persist upload state so it survives app kill ──────────────────────
    await _resume.markUploading(
      sessionId:     session.id,
      totalBlocks:   session.blockCount,
      uploadedBlocks: List.from(session.uploadedBlocks),
    );

    try {
      final uploaded = await _service.uploadSession(
        sessionId:       session.id,
        chunkPaths:      session.localChunkPaths,
        sessionTime:     session.createdAt,
        alreadyUploaded: List.from(session.uploadedBlocks),
        onProgress: (block, total, prog) {
          final pct = (((block - 1 + prog) / total) * 100).round();
          _notif.showUploadProgress(block: block, total: total, percentDone: pct);
          _emit(_state.copyWith(
              currentBlock: block, totalBlocks: total, blockProgress: prog));
          _resume.updateProgress(session.id, _state.uploadedBlocks);
        },
        onStatus: (s) => _emit(_state.copyWith(statusText: s)),
        onOverallProgress: (p) => _emit(_state.copyWith(overallPercent: p)),
      );

      await store.updateUploadedBlocks(session.id, uploaded);
      final done = uploaded.isNotEmpty; // success = at least 1 element returned
      // Clear persisted upload state now that we have a definitive result
      await _resume.clearUpload();
      if (done) {
        _notif.showUploadComplete(1);
      } else {
        _notif.showUploadFailed('Upload failed — tap Retry');
      }
      _emit(_UploadState(
        isComplete: done, isError: !done,
        uploadedBlocks: uploaded,
        totalBlocks: 1,
        currentBlock: 1,
        blockProgress: 1.0,
        overallPercent: done ? 1.0 : 0.0,
        statusText: done
            ? 'Upload complete! Saved to cloud storage ✓'
            : 'Upload failed — tap Retry to try again.',
      ));
    } catch (e) {
      await store.updateStatus(session.id, 'pending');
      await _resume.clearUpload(); // clear so it doesn't keep showing as uploading
      _notif.showUploadFailed('Upload failed — tap to retry');
      _emit(_state.copyWith(isError: true, statusText: 'Upload failed: $e'));
    } finally {
      isRunning = false;
      activeSessionId = null;
    }
  }

  void pause()  => _service.pause();
  void resume() => _service.resume();
  bool get isPaused => _service.isPaused;
}

class _UploadState {
  final int currentBlock;
  final int totalBlocks;
  final double blockProgress;
  final double overallPercent;  // 0.0–1.0, set directly by onOverallProgress
  final String statusText;
  final bool isComplete;
  final bool isError;
  final bool hasNetwork;
  final List<int> uploadedBlocks;

  const _UploadState({
    this.currentBlock  = 0,
    this.totalBlocks   = 0,
    this.blockProgress = 0,
    this.overallPercent = 0,
    this.statusText    = '',
    this.isComplete    = false,
    this.isError       = false,
    this.hasNetwork    = true,
    this.uploadedBlocks = const [],
  });

  _UploadState copyWith({
    int? currentBlock, int? totalBlocks, double? blockProgress,
    double? overallPercent, String? statusText, bool? isComplete,
    bool? isError, bool? hasNetwork, List<int>? uploadedBlocks,
  }) => _UploadState(
    currentBlock:   currentBlock   ?? this.currentBlock,
    totalBlocks:    totalBlocks    ?? this.totalBlocks,
    blockProgress:  blockProgress  ?? this.blockProgress,
    overallPercent: overallPercent ?? this.overallPercent,
    statusText:     statusText     ?? this.statusText,
    isComplete:     isComplete     ?? this.isComplete,
    isError:        isError        ?? this.isError,
    hasNetwork:     hasNetwork     ?? this.hasNetwork,
    uploadedBlocks: uploadedBlocks ?? this.uploadedBlocks,
  );

  // overallProgress: use overallPercent if set, else compute from blocks
  double get overallProgress {
    if (isComplete) return 1.0;
    if (overallPercent > 0) return overallPercent.clamp(0.0, 1.0);
    if (totalBlocks == 0) return 0.0;
    final done = uploadedBlocks.length.toDouble();
    if (currentBlock == 0) return done / totalBlocks;
    return ((currentBlock - 1) + blockProgress) / totalBlocks;
  }
}

// ── UI Screen ─────────────────────────────────────────────────────────────────
class UploadProgressScreen extends StatefulWidget {
  final SessionModel session;
  const UploadProgressScreen({super.key, required this.session});

  // ── Public static accessors so HistoryScreen can listen ──────────────────
  static Stream<_UploadState> get uploadStream => _UploadManager().stream;
  static String? get activeSessionId => _UploadManager().activeSessionId;
  static bool get isUploading => _UploadManager().isRunning;

  @override
  State<UploadProgressScreen> createState() => _UploadProgressScreenState();
}

class _UploadProgressScreenState extends State<UploadProgressScreen> {
  final _manager = _UploadManager();
  final _store   = SessionStore();
  late _UploadState _state;
  StreamSubscription? _sub;
  StreamSubscription? _connSub;
  bool _hasNetwork = true;
  bool _isPaused   = false; // local pause state — synced with manager

  @override
  void initState() {
    super.initState();
    _state = _manager.current.totalBlocks > 0
        ? _manager.current
        : _UploadState(
            totalBlocks:    widget.session.blockCount,
            uploadedBlocks: List.from(widget.session.uploadedBlocks));

    _sub = _manager.stream.listen((s) { if (mounted) setState(() => _state = s); });
    _listenNetwork();

    if (!_manager.isRunning) {
      _manager.start(widget.session, _store);
    }
  }

  void _listenNetwork() {
    _connSub = Connectivity().onConnectivityChanged.listen((r) {
      final has = r != ConnectivityResult.none;
      if (!has && _hasNetwork) {
        _manager.pause();
        if (mounted) setState(() => _hasNetwork = false);
      } else if (has && !_hasNetwork) {
        _manager.resume();
        if (mounted) setState(() => _hasNetwork = true);
      }
    });
  }

  @override
  void dispose() { _sub?.cancel(); _connSub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final pct = (_state.overallProgress * 100).toStringAsFixed(0);

    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: const Color(0xFF1A1A1A),
        title: const Text('Uploading to Cloud Storage',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16,
                color: Color(0xFF1A1A1A))),
      ),
      // ── KEY FIX: SafeArea wraps entire body so nav bar never overlaps ──
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // Network warning
              if (!_hasNetwork) Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade400)),
                child: const Row(children: [
                  Icon(Icons.wifi_off, color: Colors.orange, size: 18),
                  SizedBox(width: 10),
                  Text('No network — upload paused',
                      style: TextStyle(color: Colors.orange, fontSize: 13)),
                ])),

              // Session info
              Text('Session: ${widget.session.id.substring(0, 8).toUpperCase()}',
                  style: const TextStyle(color: Color(0xFF888888), fontSize: 11)),
              const SizedBox(height: 2),
              Text('1 file'
                  ' · ${(widget.session.durationSeconds / 60).toStringAsFixed(1)} min',
                  style: const TextStyle(color: Color(0xFF888888), fontSize: 11)),
              const SizedBox(height: 20),

              // Overall progress
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Overall progress',
                    style: TextStyle(color: Color(0xFF1A1A1A), fontSize: 14,
                        fontWeight: FontWeight.w600)),
                Text('$pct%', style: const TextStyle(
                    color: Color(0xFF00C853), fontWeight: FontWeight.bold, fontSize: 14)),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  // Show indeterminate (animated) when at 0% so it doesn't look frozen
                  value: _state.overallProgress > 0.0 ? _state.overallProgress : null,
                  minHeight: 10,
                  backgroundColor: const Color(0xFFE8E8E8),
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00C853)))),
              const SizedBox(height: 8),
              // Status text — shows current step (waking server, splitting, uploading...)
              if (_state.statusText.isNotEmpty)
                Text(_state.statusText,
                    style: const TextStyle(
                        color: Color(0xFF888888), fontSize: 12),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 20),

              // Single file upload tile
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('File', style: TextStyle(
                      color: Color(0xFF888888), fontSize: 12,
                      fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _state.isComplete
                          ? const Color(0xFF00C853).withOpacity(0.5)
                          : _state.isError ? Colors.red.withOpacity(0.3)
                          : Colors.blue.withOpacity(0.4))),
                    child: Row(children: [
                      Container(width: 40, height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _state.isComplete
                              ? const Color(0xFF00C853).withOpacity(0.1)
                              : _state.isError ? Colors.red.withOpacity(0.1)
                              : Colors.blue.withOpacity(0.1)),
                        child: Center(child: _state.isComplete
                            ? const Icon(Icons.cloud_done,
                                color: Color(0xFF00C853), size: 20)
                            : _state.isError
                                ? const Icon(Icons.error_outline,
                                    color: Colors.red, size: 20)
                                : SizedBox(width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                        value: _state.blockProgress > 0
                                            ? _state.blockProgress : null,
                                        strokeWidth: 2.5,
                                        color: Colors.blue)))),
                      const SizedBox(width: 12),
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${widget.session.id.substring(0, 8).toUpperCase()}.mp4',
                            style: const TextStyle(
                                color: Color(0xFF1A1A1A), fontSize: 13,
                                fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                            '${(widget.session.durationSeconds / 60).toStringAsFixed(1)} min · '
                            '${_state.isComplete ? "Synced" : _state.isError ? "Failed" : "Uploading"}',
                            style: const TextStyle(
                                color: Color(0xFF888888), fontSize: 11)),
                          if (!_state.isComplete && !_state.isError &&
                              _state.blockProgress > 0) ...[
                            const SizedBox(height: 6),
                            ClipRRect(borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                  value: _state.blockProgress,
                                  minHeight: 5,
                                  backgroundColor: const Color(0xFFE0E0E0),
                                  valueColor: const AlwaysStoppedAnimation<Color>(
                                      Colors.blue))),
                            const SizedBox(height: 3),
                            Text(
                              '${(_state.blockProgress * 100).toStringAsFixed(0)}% uploaded'
                              ' · ${(_state.overallProgress * 100).toStringAsFixed(0)}% overall',
                              style: const TextStyle(
                                  color: Colors.blue, fontSize: 10)),
                          ],
                        ])),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _state.isComplete
                              ? const Color(0xFF00C853).withOpacity(0.1)
                              : _state.isError ? Colors.red.withOpacity(0.1)
                              : Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20)),
                        child: Text(
                          _state.isComplete ? 'Synced'
                              : _state.isError ? 'Failed' : 'Uploading',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w600,
                              color: _state.isComplete
                                  ? const Color(0xFF00C853)
                                  : _state.isError ? Colors.red : Colors.blue))),
                    ]),
                  ),
                ],
              )),

              const SizedBox(height: 12),

              // Status text box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _state.isComplete
                      ? const Color(0xFF00C853).withOpacity(0.08)
                      : _state.isError ? Colors.red.withOpacity(0.08)
                      : const Color(0xFFF4F6F8),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _state.isComplete
                      ? const Color(0xFF00C853).withOpacity(0.3)
                      : _state.isError ? Colors.red.withOpacity(0.3)
                      : const Color(0xFFE8E8E8))),
                child: Text(_isPaused ? 'Upload paused — tap Resume to continue'
                    : _state.statusText.isEmpty ? 'Preparing...' : _state.statusText,
                    style: TextStyle(fontSize: 13,
                      color: _state.isComplete ? const Color(0xFF00C853)
                          : _state.isError ? Colors.redAccent
                          : const Color(0xFF555555)))),

              const SizedBox(height: 12),

              // Action button — always visible, never hidden by nav bar
              if (_state.isComplete)
                SizedBox(width: double.infinity, child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C853),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)))))
              else if (_state.isError)
                SizedBox(width: double.infinity, child: ElevatedButton.icon(
                  onPressed: () => _manager.start(widget.session, _store),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry Upload'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)))))
              else
                SizedBox(width: double.infinity, child: OutlinedButton.icon(
                  onPressed: _hasNetwork
                      ? () {
                          setState(() => _isPaused = !_isPaused);
                          if (_isPaused) _manager.pause(); else _manager.resume();
                        }
                      : null,
                  icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                  label: Text(_isPaused ? 'Resume Upload' : 'Pause Upload'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF555555),
                    side: const BorderSide(color: Color(0xFFCCCCCC)),
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))))),
            ],
          ),
        ),
      ),
    );
  }
}