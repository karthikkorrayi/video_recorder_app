import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../models/session_model.dart';
import '../services/upload_service.dart';
import '../services/session_store.dart';

class UploadProgressScreen extends StatefulWidget {
  final SessionModel session;
  const UploadProgressScreen({super.key, required this.session});

  @override
  State<UploadProgressScreen> createState() => _UploadProgressScreenState();
}

class _UploadProgressScreenState extends State<UploadProgressScreen> {
  final _uploadService = UploadService();
  final _store         = SessionStore();

  // Progress state
  int    _currentBlock  = 0;
  int    _totalBlocks   = 0;
  double _blockProgress = 0.0;
  String _statusText    = 'Preparing upload...';
  bool   _isUploading   = false;
  bool   _isPaused      = false;
  bool   _isComplete    = false;
  bool   _hasError      = false;
  bool   _hasNetwork    = true;
  List<int> _uploadedBlocks = [];

  StreamSubscription? _connectivitySub;

  @override
  void initState() {
    super.initState();
    _totalBlocks   = widget.session.blockCount;
    _uploadedBlocks = List.from(widget.session.uploadedBlocks);
    _currentBlock  = _uploadedBlocks.length;
    _listenConnectivity();
    _startUpload();
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  void _listenConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((result) {
      final hasNet = result != ConnectivityResult.none;
      if (!hasNet && !_isPaused) {
        _uploadService.pause();
        setState(() {
          _isPaused  = true;
          _hasNetwork = false;
          _statusText = 'No network — waiting for connection...';
        });
      } else if (hasNet && !_hasNetwork) {
        setState(() => _hasNetwork = true);
        _uploadService.resume();
        setState(() {
          _isPaused   = false;
          _statusText = 'Reconnected — resuming upload...';
        });
      }
    });
  }

  Future<void> _startUpload() async {
    if (_isUploading) return;
    setState(() {
      _isUploading = true;
      _hasError    = false;
      _statusText  = 'Starting upload...';
    });

    // Check backend reachability first
    final reachable = await _uploadService.isBackendReachable();
    if (!reachable) {
      setState(() {
        _isUploading = false;
        _hasError    = true;
        _statusText  = 'Cannot reach upload server. Check your internet connection.';
      });
      return;
    }

    await _store.updateStatus(widget.session.id, 'uploading');

    try {
      final uploaded = await _uploadService.uploadSession(
        sessionId:       widget.session.id,
        chunkPaths:      widget.session.localChunkPaths,
        sessionTime:     widget.session.createdAt,
        alreadyUploaded: _uploadedBlocks,
        onProgress: (block, total, blockProg) {
          if (mounted) setState(() {
            _currentBlock  = block;
            _totalBlocks   = total;
            _blockProgress = blockProg;
          });
        },
        onStatus: (status) {
          if (mounted) setState(() => _statusText = status);
        },
      );

      await _store.updateUploadedBlocks(widget.session.id, uploaded);

      final isComplete = uploaded.length >= widget.session.blockCount;
      setState(() {
        _uploadedBlocks = uploaded;
        _isUploading    = false;
        _isComplete     = isComplete;
        _statusText     = isComplete
            ? 'Upload complete! All blocks synced to OneDrive.'
            : 'Partial upload — ${widget.session.blockCount - uploaded.length} block(s) remaining.';
      });
    } catch (e) {
      await _store.updateStatus(widget.session.id, 'pending');
      if (mounted) setState(() {
        _isUploading = false;
        _hasError    = true;
        _statusText  = 'Upload failed: ${e.toString()}';
      });
    }
  }

  void _togglePause() {
    if (_isPaused) {
      _uploadService.resume();
      setState(() {
        _isPaused   = false;
        _statusText = 'Resuming...';
      });
    } else {
      _uploadService.pause();
      setState(() {
        _isPaused   = true;
        _statusText = 'Paused by user';
      });
    }
  }

  // Overall progress 0.0–1.0
  double get _overallProgress {
    if (_totalBlocks == 0) return 0.0;
    final done = _uploadedBlocks.length.toDouble();
    final curr = _isUploading && _currentBlock > 0
        ? (_currentBlock - 1 + _blockProgress) / _totalBlocks
        : done / _totalBlocks;
    return curr.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_overallProgress * 100).toStringAsFixed(0);

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('Uploading to OneDrive',
            style: TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
        leading: _isComplete
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () {
                  _uploadService.pause();
                  Navigator.pop(context);
                },
              ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Network banner ──────────────────────────────────────
            if (!_hasNetwork)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.orange.shade700),
                ),
                child: Row(children: [
                  const Icon(Icons.wifi_off, color: Colors.orange, size: 18),
                  const SizedBox(width: 10),
                  const Text('No internet — upload paused',
                      style: TextStyle(color: Colors.orange, fontSize: 13)),
                ]),
              ),

            // ── Session info ────────────────────────────────────────
            Text('Session: ${widget.session.id.substring(0, 8).toUpperCase()}',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
            const SizedBox(height: 4),
            Text('$_totalBlocks block${_totalBlocks != 1 ? 's' : ''} • '
                '${(widget.session.durationSeconds / 60).toStringAsFixed(1)} min',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),

            const SizedBox(height: 32),

            // ── Overall progress ────────────────────────────────────
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Overall progress',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              Text('$pct%',
                  style: const TextStyle(
                      color: Color(0xFF00C853),
                      fontWeight: FontWeight.bold,
                      fontSize: 14)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _overallProgress,
                minHeight: 10,
                backgroundColor: Colors.white10,
                valueColor: AlwaysStoppedAnimation<Color>(
                  _isComplete ? const Color(0xFF00C853) : const Color(0xFF00C853),
                ),
              ),
            ),

            const SizedBox(height: 28),

            // ── Block list ──────────────────────────────────────────
            const Text('Blocks', style: TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: _totalBlocks,
                itemBuilder: (ctx, i) {
                  final isDone     = _uploadedBlocks.contains(i);
                  final isCurrent  = _isUploading && (_currentBlock - 1) == i;
                  final isPending  = !isDone && !isCurrent;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: isCurrent
                            ? const Color(0xFF00C853).withOpacity(0.5)
                            : Colors.white10,
                      ),
                    ),
                    child: Row(children: [
                      // Block icon
                      Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDone
                              ? const Color(0xFF00C853).withOpacity(0.15)
                              : isCurrent
                                  ? Colors.blue.withOpacity(0.15)
                                  : Colors.white10,
                        ),
                        child: Center(
                          child: isDone
                              ? const Icon(Icons.check, color: Color(0xFF00C853), size: 16)
                              : isCurrent
                                  ? SizedBox(
                                      width: 16, height: 16,
                                      child: CircularProgressIndicator(
                                        value: _blockProgress,
                                        strokeWidth: 2,
                                        color: Colors.blue,
                                      ),
                                    )
                                  : Text('${i + 1}',
                                      style: const TextStyle(
                                          color: Colors.white38, fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Block label
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Block ${i + 1} of $_totalBlocks',
                              style: TextStyle(
                                  color: isDone
                                      ? Colors.white70
                                      : isCurrent
                                          ? Colors.white
                                          : Colors.white38,
                                  fontSize: 13,
                                  fontWeight: isCurrent
                                      ? FontWeight.w600
                                      : FontWeight.normal)),
                          if (isCurrent)
                            Text('${(_blockProgress * 100).toStringAsFixed(0)}% uploaded',
                                style: const TextStyle(color: Colors.blue, fontSize: 11)),
                        ]),
                      ),
                      // Status chip
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: isDone
                              ? const Color(0xFF00C853).withOpacity(0.1)
                              : isCurrent
                                  ? Colors.blue.withOpacity(0.1)
                                  : Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          isDone ? 'Synced' : isCurrent ? 'Uploading' : 'Pending',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: isDone
                                  ? const Color(0xFF00C853)
                                  : isCurrent
                                      ? Colors.blue
                                      : Colors.white30),
                        ),
                      ),
                    ]),
                  );
                },
              ),
            ),

            const SizedBox(height: 16),

            // ── Status text ─────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _isComplete
                    ? const Color(0xFF00C853).withOpacity(0.08)
                    : _hasError
                        ? Colors.red.withOpacity(0.08)
                        : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _isComplete
                      ? const Color(0xFF00C853).withOpacity(0.3)
                      : _hasError
                          ? Colors.red.withOpacity(0.3)
                          : Colors.white10,
                ),
              ),
              child: Text(_statusText,
                  style: TextStyle(
                      color: _isComplete
                          ? const Color(0xFF00C853)
                          : _hasError
                              ? Colors.redAccent
                              : Colors.white60,
                      fontSize: 13)),
            ),

            const SizedBox(height: 16),

            // ── Action buttons ──────────────────────────────────────
            if (_isComplete)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C853),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              )
            else if (_hasError)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _startUpload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              )
            else
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _hasNetwork ? _togglePause : null,
                    icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
                    label: Text(_isPaused ? 'Resume' : 'Pause'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ]),
          ],
        ),
      ),
    );
  }
}