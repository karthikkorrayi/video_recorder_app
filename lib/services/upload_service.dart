import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'dart:io';

class UploadService {
  final _storage = FirebaseStorage.instance;
  final _firestore = FirebaseFirestore.instance;
  final _uuid = const Uuid();

  Future<void> uploadChunks(
    List<String> chunkPaths,
    Function(double) onProgress,
  ) async {
    final videoId = _uuid.v4();          // unique ID for this recording
    final userId = FirebaseAuth.instance.currentUser!.uid;
    final List<String> downloadUrls = [];

    // Upload all 5 chunks in parallel
    final futures = chunkPaths.asMap().entries.map((entry) async {
      final index = entry.key;
      final path = entry.value;
      final file = File(path);

      final ref = _storage.ref(
        'videos/$userId/$videoId/chunk_${index + 1}.mp4'
      );

      final task = ref.putFile(file);
      task.snapshotEvents.listen((snapshot) {
        // Overall progress across all chunks
        onProgress((index + snapshot.bytesTransferred / snapshot.totalBytes) / 5);
      });

      await task;
      final url = await ref.getDownloadURL();
      downloadUrls.add(url);
    });

    await Future.wait(futures); // wait for all 5 to finish

    // Save metadata to Firestore
    await _firestore.collection('videos').doc(videoId).set({
      'userId': userId,
      'videoId': videoId,
      'chunkUrls': downloadUrls,
      'uploadedAt': FieldValue.serverTimestamp(),
      'status': 'chunked',    // Cloud Function will update this to 'merged'
    });
  }
}