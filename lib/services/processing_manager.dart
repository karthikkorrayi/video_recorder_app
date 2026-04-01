import 'dart:async';

enum ProcessingState { analysing, processing, done, error }

class ProcessingStatus {
  final String sessionId;
  final ProcessingState state;
  final String message;
  final double progress;   // 0.0 → 1.0
  final int currentBlock;
  final int totalBlocks;

  const ProcessingStatus({
    required this.sessionId,
    required this.state,
    required this.message,
    required this.progress,
    this.currentBlock = 0,
    this.totalBlocks = 0,
  });

  bool get isActive => state == ProcessingState.analysing || state == ProcessingState.processing;
  bool get isDone => state == ProcessingState.done;
  bool get isError => state == ProcessingState.error;

  String get stateLabel {
    switch (state) {
      case ProcessingState.analysing:  return 'Analysing';
      case ProcessingState.processing: return 'Processing';
      case ProcessingState.done:       return 'Saved';
      case ProcessingState.error:      return 'Failed';
    }
  }
}

/// Singleton that holds all in-progress and recently-finished processing jobs.
/// Dashboard / any widget can listen to [stream] for live updates.
class ProcessingManager {
  static final ProcessingManager _i = ProcessingManager._();
  factory ProcessingManager() => _i;
  ProcessingManager._();

  // All jobs (active + recently completed)
  final Map<String, ProcessingStatus> _jobs = {};

  final _controller = StreamController<Map<String, ProcessingStatus>>.broadcast();

  /// Stream of all job statuses — emit on every update.
  Stream<Map<String, ProcessingStatus>> get stream => _controller.stream;

  /// Current snapshot (for initial widget build).
  Map<String, ProcessingStatus> get current => Map.unmodifiable(_jobs);

  /// Active jobs only.
  List<ProcessingStatus> get activeJobs =>
      _jobs.values.where((j) => j.isActive).toList();

  /// Recently completed jobs (done or error) — shown briefly in dashboard.
  List<ProcessingStatus> get recentJobs =>
      _jobs.values.where((j) => !j.isActive).toList();

  /// Called by VideoProcessor to push a status update.
  void update(String sessionId, ProcessingStatus status) {
    _jobs[sessionId] = status;
    if (!_controller.isClosed) _controller.add(Map.unmodifiable(_jobs));

    // Auto-remove completed jobs after 8 seconds so dashboard doesn't accumulate them
    if (status.isDone || status.isError) {
      Future.delayed(const Duration(seconds: 8), () {
        _jobs.remove(sessionId);
        if (!_controller.isClosed) _controller.add(Map.unmodifiable(_jobs));
      });
    }
  }

  bool get hasActiveJobs => _jobs.values.any((j) => j.isActive);
}