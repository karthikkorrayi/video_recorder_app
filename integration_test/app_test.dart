// integration_test/app_test.dart
//
// OTN Video Recorder — Device Integration Tests
// Run on real Vivo I2217 via: flutter test integration_test/app_test.dart -d <device_id>
//
// Tests run IN ORDER. Each test depends on a real device with:
//   - Camera permission granted
//   - Storage permission granted
//   - A logged-in Firebase user
//   - Active internet connection

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video_recorder_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // ────────────────────────────────────────────────────────────────────────
  // TEST 1 — App launches and reaches Dashboard (not login screen)
  // What to check: Firebase Auth user is already logged in from previous run
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T1: App launches and shows Dashboard', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Should see Dashboard — not the login screen
    expect(find.text('My Recordings'), findsOneWidget,
        reason: 'Dashboard should load if user is already logged in');

    debugPrint('✓ T1: Dashboard visible');
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 2 — Camera screen opens
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T2: Camera screen opens from Dashboard', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Tap the record button (the green camera FAB)
    final recordBtn = find.byIcon(Icons.videocam);
    expect(recordBtn, findsOneWidget, reason: 'Record button should be on Dashboard');
    await tester.tap(recordBtn);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Camera screen should be visible — shows the timer "--:--" initially
    expect(find.text('--:--'), findsOneWidget,
        reason: 'Camera screen should show timer in detecting state');

    debugPrint('✓ T2: Camera screen opened');
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 3 — Short recording saves locally
  // Records for 6 seconds manually, checks session appears in history
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T3: Short recording saves to local history', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Open camera
    await tester.tap(find.byIcon(Icons.videocam));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Tap Start Recording button
    final startBtn = find.text('Start New Recording');
    expect(startBtn, findsOneWidget);
    await tester.tap(startBtn);

    // Wait for 5-sec countdown + 6 sec recording
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    // Tap Stop Recording
    final stopBtn = find.text('Stop Recording');
    expect(stopBtn, findsOneWidget, reason: 'Stop button should be visible while recording');
    await tester.tap(stopBtn);
    await tester.pumpAndSettle(const Duration(seconds: 4)); // wait for "saved" state

    // Saved confirmation should show
    expect(find.text('Recording Saved!'), findsOneWidget,
        reason: 'Should show saved confirmation overlay');

    // Go back to dashboard
    await tester.tap(find.byIcon(Icons.home_rounded));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Wait for background processing (FFmpeg copy)
    await Future.delayed(const Duration(seconds: 8));
    await tester.pumpAndSettle();

    // Open My Recordings
    await tester.tap(find.text('My Recordings'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // At least 1 local session should exist
    expect(find.text('Local'), findsOneWidget);
    // "Not uploaded" badge means it's saved locally
    expect(find.text('Not uploaded'), findsWidgets,
        reason: 'New session should appear as Not uploaded');

    debugPrint('✓ T3: Session saved and visible in history');
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 4 — Saved file exists on disk and is playable
  // Checks the actual file path and size
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T4: Saved video file exists on disk with correct size', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Check Android media directory
    final mediaBase = Directory(
        '/storage/emulated/0/Android/media/com.otn.videorecorder/OTN/VideoRecorder');
    expect(mediaBase.existsSync(), isTrue,
        reason: 'OTN/VideoRecorder directory should exist after first recording');

    // Find any .mp4 file recursively
    final files = mediaBase
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.mp4'))
        .toList();

    expect(files.isNotEmpty, isTrue,
        reason: 'At least one .mp4 should exist in VideoRecorder folder');

    // All files should be >1KB (not empty/corrupt)
    for (final f in files) {
      final sizeMB = f.lengthSync() / 1024 / 1024;
      debugPrint('  File: ${f.path.split('/').last} — ${sizeMB.toStringAsFixed(2)}MB');
      expect(f.lengthSync(), greaterThan(1024),
          reason: '${f.path} should be >1KB, not empty/corrupt');
    }

    // No chunk files should be in media dir (they go to cache)
    final chunkFiles = files.where((f) => f.path.contains('_chunk')).toList();
    expect(chunkFiles.isEmpty, isTrue,
        reason: 'Chunk files should be in cache, not media dir. Found: ${chunkFiles.map((f) => f.path.split('/').last).join(', ')}');

    debugPrint('✓ T4: ${files.length} file(s) found, all valid');
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 5 — Upload starts and shows progress
  // Requires backend deployed and internet connection
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T5: Upload starts and shows progress UI', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Open history
    await tester.tap(find.text('My Recordings'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Find the first "Upload" button
    final uploadBtn = find.text('Upload');
    if (uploadBtn.evaluate().isEmpty) {
      debugPrint('SKIP T5: No pending sessions to upload');
      return;
    }

    await tester.tap(uploadBtn.first);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Progress screen should open
    expect(find.text('Uploading to Cloud Storage'), findsOneWidget,
        reason: 'Upload progress screen should open');

    // Wait a bit — should show connecting or uploading status
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Progress bar should be visible
    expect(find.byType(LinearProgressIndicator), findsWidgets,
        reason: 'Progress indicator should be visible');

    // Should NOT immediately show "Failed"
    expect(find.text('Failed'), findsNothing,
        reason: 'Upload should not immediately fail — check backend URL');

    debugPrint('✓ T5: Upload progress screen working');
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 6 — Dashboard shows upload badge when upload is active
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T6: Dashboard shows live upload banner', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Start an upload from history
    await tester.tap(find.text('My Recordings'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    final uploadBtn = find.text('Upload');
    if (uploadBtn.evaluate().isEmpty) {
      debugPrint('SKIP T6: No pending sessions');
      return;
    }
    await tester.tap(uploadBtn.first);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Go back to dashboard
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle(const Duration(seconds: 2));
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Dashboard should show the upload banner
    expect(find.text('Uploading to cloud...'), findsOneWidget,
        reason: 'Dashboard should show live upload banner when upload is active');

    debugPrint('✓ T6: Live upload banner visible on Dashboard');
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 7 — Backend health check
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T7: Backend /health responds correctly', (tester) async {
    // Direct HTTP check — no UI needed
    final client = HttpClient();
    try {
      final req = await client.getUrl(
          Uri.parse('https://video-recorder-app-d7zk.onrender.com/health'));
      final res = await req.close();
      expect(res.statusCode, equals(200),
          reason: 'Backend /health should return 200. '
              'Got ${res.statusCode} — check Render deployment');
      debugPrint('✓ T7: Backend is healthy (200 OK)');
    } catch (e) {
      fail('T7: Backend /health failed: $e\n'
          'Make sure server.js is deployed to Render with /health endpoint');
    } finally {
      client.close();
    }
  });

  // ────────────────────────────────────────────────────────────────────────
  // TEST 8 — Beep service plays without crashing
  // ────────────────────────────────────────────────────────────────────────
  testWidgets('T8: Beep service initializes without error', (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Open camera to trigger beep init
    await tester.tap(find.byIcon(Icons.videocam));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Tap start — countdown beeps should play without crash
    final startBtn = find.text('Start New Recording');
    if (startBtn.evaluate().isNotEmpty) {
      await tester.tap(startBtn);
      // Wait through countdown (5 seconds of beeps)
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      // If we get here without exception, beep service worked
      debugPrint('✓ T8: Beep service ran without crash');

      // Stop recording
      final stopBtn = find.text('Stop Recording');
      if (stopBtn.evaluate().isNotEmpty) {
        await tester.tap(stopBtn);
        await tester.pumpAndSettle(const Duration(seconds: 3));
      }
    }
  });
}