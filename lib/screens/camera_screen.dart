import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'review_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  bool _isRecording = false;
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    _controller = CameraController(cameras[0], ResolutionPreset.high);
    await _controller!.initialize();
    setState(() {});
  }

  Future<void> _toggleTorch() async {
    _torchOn = !_torchOn;
    await _controller!.setFlashMode(
      _torchOn ? FlashMode.torch : FlashMode.off
    );
    setState(() {});
  }

  Future<void> _startRecording() async {
    await _controller!.startVideoRecording();
    setState(() => _isRecording = true);
  }

  Future<void> _stopRecording() async {
    final file = await _controller!.stopVideoRecording();
    setState(() => _isRecording = false);

    // Go to review screen
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => ReviewScreen(videoPath: file.path),
    ));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Full screen camera preview
          SizedBox.expand(child: CameraPreview(_controller!)),

          // Top bar — torch button
          Positioned(
            top: 50, right: 20,
            child: IconButton(
              icon: Icon(
                _torchOn ? Icons.flashlight_on : Icons.flashlight_off,
                color: _torchOn ? Colors.yellow : Colors.white,
                size: 32,
              ),
              onPressed: _toggleTorch,
            ),
          ),

          // Bottom bar — record / stop button
          Positioned(
            bottom: 60, left: 0, right: 0,
            child: Center(
              child: GestureDetector(
                onTap: _isRecording ? _stopRecording : _startRecording,
                child: Container(
                  width: 80, height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: _isRecording ? Colors.red : Colors.transparent,
                  ),
                  child: _isRecording
                      ? const Icon(Icons.stop, color: Colors.white, size: 36)
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}