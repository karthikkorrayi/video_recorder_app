import 'dart:convert';

/// Status values:
///   'pending'   — recorded locally, not yet uploaded
///   'uploading' — upload in progress
///   'synced'    — all blocks confirmed uploaded to OneDrive
///   'partial'   — some blocks uploaded, some still pending
class SessionModel {
  final String       id;
  final String       userId;
  final DateTime     createdAt;
  final int          durationSeconds;
  final int          blockCount;
  String             status;
  final List<String> localChunkPaths;
  List<int>          uploadedBlocks; // 0-based indices of blocks confirmed uploaded

  SessionModel({
    required this.id,
    required this.userId,
    required this.createdAt,
    required this.durationSeconds,
    required this.blockCount,
    required this.status,
    required this.localChunkPaths,
    List<int>? uploadedBlocks,
  }) : uploadedBlocks = uploadedBlocks ?? [];

  bool get isFullySynced => uploadedBlocks.length >= blockCount;
  bool get isPartial     => uploadedBlocks.isNotEmpty && !isFullySynced;
  int  get pendingBlocks => blockCount - uploadedBlocks.length;

  Map<String, dynamic> toJson() => {
    'id':             id,
    'userId':         userId,
    'createdAt':      createdAt.toIso8601String(),
    'durationSeconds':durationSeconds,
    'blockCount':     blockCount,
    'status':         status,
    'localChunkPaths':localChunkPaths,
    'uploadedBlocks': uploadedBlocks,
  };

  factory SessionModel.fromJson(Map<String, dynamic> j) => SessionModel(
    id:             j['id'],
    userId:         j['userId'],
    createdAt:      DateTime.parse(j['createdAt']),
    durationSeconds:j['durationSeconds'] ?? 0,
    blockCount:     j['blockCount'] ?? 1,
    status:         j['status'] ?? 'pending',
    localChunkPaths:List<String>.from(j['localChunkPaths'] ?? []),
    uploadedBlocks: List<int>.from(j['uploadedBlocks'] ?? []),
  );
}