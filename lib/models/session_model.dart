/// Single source of truth for SessionModel.
/// Imported by session_store.dart (which re-exports it).
/// Do NOT define SessionModel anywhere else.
class SessionModel {
  final String id;              // UUID
  int    durationSeconds;
  int    blockCount;
  String status;                // 'pending' | 'uploading' | 'partial' | 'synced'
  List<String> localChunkPaths;
  List<int>    uploadedBlocks;
  DateTime     recordedAt;

  // ── OneDrive folder fields (set when session is created) ──────────────────
  String dateFolder;    // DD-MM-YYYY  e.g. 22-04-2026
  String sessionDate;   // YYYYMMDD    e.g. 20260422
  String startTime;     // HHmmss      e.g. 024720  ← session START only
  String userFullName;  // from UserService
  List<String> partNames; // cloud filenames e.g. 9NE5B0_..._part01_0000-0200.mp4

  SessionModel({
    required this.id,
    required this.durationSeconds,
    required this.blockCount,
    required this.status,
    required this.localChunkPaths,
    required this.uploadedBlocks,
    required this.recordedAt,
    this.dateFolder   = '',
    this.sessionDate  = '',
    this.startTime    = '',
    this.userFullName = '',
    List<String>? partNames,
  }) : partNames = partNames ?? [];

  // Convenience getters used by upload_progress_screen
  String get sessionId  => id;
  int    get totalParts => blockCount;
  int    get uploadedParts => uploadedBlocks.length;

  Map<String, dynamic> toJson() => {
    'id':              id,
    'durationSeconds': durationSeconds,
    'blockCount':      blockCount,
    'status':          status,
    'localChunkPaths': localChunkPaths,
    'uploadedBlocks':  uploadedBlocks,
    'recordedAt':      recordedAt.toIso8601String(),
    'dateFolder':      dateFolder,
    'sessionDate':     sessionDate,
    'startTime':       startTime,
    'userFullName':    userFullName,
    'partNames':       partNames,
  };

  factory SessionModel.fromJson(Map<String, dynamic> j) => SessionModel(
    id:              j['id'] as String,
    durationSeconds: j['durationSeconds'] as int? ?? 0,
    blockCount:      j['blockCount'] as int? ?? 1,
    status:          j['status'] as String? ?? 'pending',
    localChunkPaths: List<String>.from(j['localChunkPaths'] as List? ?? []),
    uploadedBlocks:  List<int>.from(j['uploadedBlocks'] as List? ?? []),
    recordedAt:      DateTime.tryParse(j['recordedAt'] as String? ?? '') ??
        DateTime.now(),
    dateFolder:      j['dateFolder'] as String? ?? '',
    sessionDate:     j['sessionDate'] as String? ?? '',
    startTime:       j['startTime'] as String? ?? '',
    userFullName:    j['userFullName'] as String? ?? '',
    partNames:       List<String>.from(j['partNames'] as List? ?? []),
  );
}