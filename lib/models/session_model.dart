class SessionModel {
  final String id;
  final String userId;
  final DateTime createdAt;
  final double durationSeconds;
  final int blockCount;
  final String status; // pending | uploading | synced
  final List<String> localChunkPaths;
  final double uploadProgress;

  SessionModel({
    required this.id,
    required this.userId,
    required this.createdAt,
    required this.durationSeconds,
    required this.blockCount,
    required this.status,
    required this.localChunkPaths,
    this.uploadProgress = 0,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'userId': userId,
        'createdAt': createdAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'blockCount': blockCount,
        'status': status,
        'localChunkPaths': localChunkPaths,
      };

  factory SessionModel.fromMap(Map<String, dynamic> map) => SessionModel(
        id: map['id'],
        userId: map['userId'],
        createdAt: DateTime.parse(map['createdAt']),
        durationSeconds: (map['durationSeconds'] as num).toDouble(),
        blockCount: map['blockCount'],
        status: map['status'],
        localChunkPaths: List<String>.from(map['localChunkPaths'] ?? []),
      );
}