import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'services/local_video_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait for all non-camera screens
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyAU5jiCE8sCIMjm0ywBFnHupvOIAkCbMLM',
      appId: '1:164325680744:android:4f0c0284c3a3db8e4f7ddd',
      messagingSenderId: '164325680744',
      projectId: 'videorecorderapp-305b8',
      storageBucket: 'videorecorderapp-305b8.firebasestorage.app',
    ),
  );

  runApp(const KineSyncApp());
}

class KineSyncApp extends StatelessWidget {
  const KineSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KineSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4F8EF7),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const _PermissionGate(),
    );
  }
}

/// Requests storage permission once on first launch, then shows auth gate.
class _PermissionGate extends StatefulWidget {
  const _PermissionGate();

  @override
  State<_PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<_PermissionGate> {
  bool _permissionChecked = false;
  bool _permissionGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    final granted = await LocalVideoStorage.requestStoragePermission();
    if (mounted) setState(() {
      _permissionGranted = granted;
      _permissionChecked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionChecked) {
      return const Scaffold(
        backgroundColor: Color(0xFF0A0A0F),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF4F8EF7))),
      );
    }

    if (!_permissionGranted) {
      return Scaffold(
        backgroundColor: const Color(0xFF0A0A0F),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.folder_off_rounded, color: Colors.white38, size: 56),
              const SizedBox(height: 20),
              const Text('Storage Permission Required',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              const Text(
                'KineSync needs access to storage to save your recordings in the Movies/KineSync folder on your device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: () async {
                  await openAppSettings();
                  await _checkPermissions();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F8EF7),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Open Settings', style: TextStyle(color: Colors.white, fontSize: 15)),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _checkPermissions,
                child: const Text('Try Again', style: TextStyle(color: Colors.white38)),
              ),
            ]),
          ),
        ),
      );
    }

    // Permission granted — show auth gate
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            backgroundColor: Color(0xFF0A0A0F),
            body: Center(child: CircularProgressIndicator(color: Color(0xFF4F8EF7))),
          );
        }
        if (snapshot.hasData) return const DashboardScreen();
        return const LoginScreen();
      },
    );
  }
}