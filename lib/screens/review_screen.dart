import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'dart:io';
import '../services/video_processor.dart';
import '../services/upload_service.dart';

class ReviewScreen extends StatefulWidget {
  final String videoPath;
  const ReviewScreen({super.key, required this.videoPath});
  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late VideoPlayerController _playerController;
  final _processor = VideoProcessor();
  final _uploader = UploadService();
  double _uploadProgress = 0;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _playerController = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) => setState(() {}))
      ..setLooping(true)
      ..play();
  }

  @override
  void dispose() {
    _playerController.dispose();
    super.dispose();
  }

  Future<void> _saveAndUpload() async {
    setState(() => _isProcessing = true);

    try {
      // Step 1: Process (mute, ratio, fps, compress)
      final processedPath = await _processor.processVideo(widget.videoPath);

      // Step 2: Split into 5 chunks
      final chunks = await _processor.splitIntoFiveChunks(processedPath);

      // Step 3: Upload all 5 chunks
      await _uploader.uploadChunks(chunks, (progress) {
        setState(() => _uploadProgress = progress);
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video uploaded successfully!')),
      );
      Navigator.popUntil(context, (route) => route.isFirst);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Video playback
          if (_playerController.value.isInitialized)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _playerController.value.size.width,
                  height: _playerController.value.size.height,
                  child: VideoPlayer(_playerController),
                ),
              ),
            ),

          // Bottom buttons
          Positioned(
            bottom: 50, left: 0, right: 0,
            child: _isProcessing
                ? Column(
                    children: [
                      const Text('Processing & uploading...', style: TextStyle(color: Colors.white)),
                      const SizedBox(height: 12),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: LinearProgressIndicator(value: _uploadProgress),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.replay),
                        label: const Text('Recapture'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.grey[800]),
                      ),
                      ElevatedButton.icon(
                        onPressed: _saveAndUpload,
                        icon: const Icon(Icons.cloud_upload),
                        label: const Text('Save & Upload'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.blue),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}