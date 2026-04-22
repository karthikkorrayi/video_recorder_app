import 'dart:async';
import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/session_store.dart';        // SessionModel re-exported from here
import '../services/upload_manager.dart';

export '../services/upload_manager.dart' show UploadManager, UploadState;

class UploadProgressScreen extends StatefulWidget {
  final SessionModel session;
  const UploadProgressScreen({super.key, required this.session});
  @override
  State<UploadProgressScreen> createState() => _UploadProgressScreenState();
}

class _UploadProgressScreenState extends State<UploadProgressScreen> {
  final _manager = UploadManager();
  // FIX: SessionStore.empty() — no 'sessions' arg needed for a fresh instance
  final _store   = SessionStore.empty();
  late UploadState _state;
  StreamSubscription? _sub;
  StreamSubscription? _connSub;
  bool _hasNetwork = true;

  @override
  void initState() {
    super.initState();
    _state = _manager.current.totalBlocks > 0
        ? _manager.current
        : UploadState(
            totalBlocks:    widget.session.blockCount,
            uploadedBlocks: List.from(widget.session.uploadedBlocks));

    _sub = _manager.stream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _listenNetwork();

    if (!_manager.isRunning) {
      _manager.start(widget.session, _store);
    }
  }

  void _listenNetwork() {
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final has = results.isNotEmpty &&
          !results.every((r) => r == ConnectivityResult.none);
      if (!has && _hasNetwork) {
        if (mounted) setState(() => _hasNetwork = false);
      } else if (has && !_hasNetwork) {
        if (mounted) setState(() => _hasNetwork = true);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _connSub?.cancel();
    super.dispose();
  }

  static const _green  = Color(0xFF00C853);
  static const _red    = Colors.red;
  static const _blue   = Colors.blue;
  static const _grey   = Color(0xFF888888);
  static const _bg     = Color(0xFFF4F6F8);
  static const _border = Color(0xFFE8E8E8);
  static const _text   = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) {
    final pct = (_state.overallProgress * 100).toStringAsFixed(0);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: _text,
        title: const Text('Uploading to Cloud Storage',
            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: _text)),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // Network warning
              if (!_hasNetwork)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.orange.shade400)),
                  child: const Row(children: [
                    Icon(Icons.wifi_off, color: Colors.orange, size: 18),
                    SizedBox(width: 10),
                    Text('No network — waiting to reconnect',
                        style: TextStyle(color: Colors.orange, fontSize: 13)),
                  ])),

              // Session info
              Text('Session: ${widget.session.id.substring(0, 8).toUpperCase()}',
                  style: const TextStyle(color: _grey, fontSize: 11)),
              const SizedBox(height: 2),
              Text('1 file · ${(widget.session.durationSeconds / 60).toStringAsFixed(1)} min',
                  style: const TextStyle(color: _grey, fontSize: 11)),
              const SizedBox(height: 20),

              // Overall progress bar
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Overall progress',
                    style: TextStyle(color: _text, fontSize: 14, fontWeight: FontWeight.w600)),
                Text('$pct%',
                    style: const TextStyle(color: _green, fontWeight: FontWeight.bold, fontSize: 14)),
              ]),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: _state.overallProgress > 0.0 ? _state.overallProgress : null,
                  minHeight: 10,
                  backgroundColor: _border,
                  valueColor: const AlwaysStoppedAnimation<Color>(_green))),
              const SizedBox(height: 8),
              if (_state.statusText.isNotEmpty)
                Text(_state.statusText,
                    style: const TextStyle(color: _grey, fontSize: 12),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 20),

              // File tile
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('File',
                      style: TextStyle(color: _grey, fontSize: 12, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _state.isComplete
                            ? _green.withValues(alpha: 0.5)
                            : _state.isError
                                ? _red.withValues(alpha: 0.3)
                                : _blue.withValues(alpha: 0.4))),
                    child: Row(children: [
                      // Status icon
                      Container(
                        width: 40, height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _state.isComplete
                              ? _green.withValues(alpha: 0.1)
                              : _state.isError
                                  ? _red.withValues(alpha: 0.1)
                                  : _blue.withValues(alpha: 0.1)),
                        child: Center(child: _state.isComplete
                            ? const Icon(Icons.cloud_done, color: _green, size: 20)
                            : _state.isError
                                ? const Icon(Icons.error_outline, color: _red, size: 20)
                                : SizedBox(
                                    width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                      value: _state.blockProgress > 0
                                          ? _state.blockProgress : null,
                                      strokeWidth: 2.5, color: _blue)))),
                      const SizedBox(width: 12),
                      // File info
                      Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${widget.session.id.substring(0, 8).toUpperCase()}.mp4',
                            style: const TextStyle(color: _text, fontSize: 13,
                                fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                            '${(widget.session.durationSeconds / 60).toStringAsFixed(1)} min · '
                            '${_state.isComplete ? "Synced" : _state.isError ? "Failed" : "Uploading"}',
                            style: const TextStyle(color: _grey, fontSize: 11)),
                          if (!_state.isComplete && !_state.isError && _state.blockProgress > 0) ...[
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: _state.blockProgress,
                                minHeight: 5,
                                backgroundColor: _border,
                                valueColor: const AlwaysStoppedAnimation<Color>(_blue))),
                            const SizedBox(height: 3),
                            Text(
                              '${(_state.blockProgress * 100).toStringAsFixed(0)}% this part'
                              ' · overall $pct%',
                              style: const TextStyle(color: _blue, fontSize: 10)),
                          ],
                        ])),
                      // Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _state.isComplete
                              ? _green.withValues(alpha: 0.1)
                              : _state.isError
                                  ? _red.withValues(alpha: 0.1)
                                  : _blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20)),
                        child: Text(
                          _state.isComplete ? 'Synced'
                              : _state.isError ? 'Failed' : 'Uploading',
                          style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w600,
                            color: _state.isComplete ? _green
                                : _state.isError ? _red : _blue))),
                    ]),
                  ),
                ],
              )),

              const SizedBox(height: 12),

              // Status box
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _state.isComplete
                      ? _green.withValues(alpha: 0.08)
                      : _state.isError
                          ? _red.withValues(alpha: 0.08)
                          : _bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _state.isComplete
                        ? _green.withValues(alpha: 0.3)
                        : _state.isError
                            ? _red.withValues(alpha: 0.3)
                            : _border)),
                child: Text(
                  _state.statusText.isEmpty ? 'Preparing...' : _state.statusText,
                  style: TextStyle(
                    fontSize: 13,
                    color: _state.isComplete ? _green
                        : _state.isError ? Colors.redAccent
                        : const Color(0xFF555555)))),

              const SizedBox(height: 12),

              // Action button
              if (_state.isComplete)
                SizedBox(width: double.infinity, child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
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
            ],
          ),
        ),
      ),
    );
  }
}