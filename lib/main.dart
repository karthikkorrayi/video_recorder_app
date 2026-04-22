import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/login_screen.dart';
import 'screens/history_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/camera_screen.dart';
import 'services/local_video_storage.dart';
import 'services/notification_service.dart';
import 'services/upload_resume_service.dart';
import 'services/backend_keepalive.dart';
import 'services/cloud_cache_service.dart';
import 'services/session_store.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

const kGreen     = Color(0xFF00C853);
const kGreenDark = Color(0xFF00A045);
const kBlack     = Color(0xFF0D0D0D);
const kSurface   = Color(0xFFF4F4F4);
const kCard      = Color(0xFFFFFFFF);
const kBorder    = Color(0xFFE0E0E0);
const kText      = Color(0xFF1A1A1A);
const kTextSub   = Color(0xFF666666);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey:           'AIzaSyAU5jiCE8sCIMjm0ywBFnHupvOIAkCbMLM',
      appId:            '1:164325680744:android:4f0c0284c3a3db8e4f7ddd',
      messagingSenderId:'164325680744',
      projectId:        'videorecorderapp-305b8',
      storageBucket:    'videorecorderapp-305b8.firebasestorage.app',
    ),
  );

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness:     Brightness.light,
    statusBarIconBrightness: Brightness.dark,
  ));

  try {
    await NotificationService().init();
    NotificationService().setOnFailureTap(() {
      navigatorKey.currentState?.pushNamed('/history');
    });
  } catch (e) {
    debugPrint('=== NotificationService init failed: $e');
  }

  // ── Check for interrupted upload and auto-resume ──────────────────────────
  try {
    final pending = await UploadResumeService().getPendingUpload();
    if (pending != null && pending.isIncomplete) {
      debugPrint('=== Found interrupted upload: ${pending.sessionId} '
          '(${pending.completedBlocks}/${pending.totalBlocks} done)');

      // FIX: use SessionStore.load() (async factory) then getById()
      final store   = await SessionStore.load();
      final session = await store.getById(pending.sessionId);

      if (session != null && session.status == 'uploading') {
        final newStatus          = pending.completedBlocks > 0 ? 'partial' : 'pending';
        session.uploadedBlocks   = pending.uploadedBlocks;
        session.status           = newStatus;
        await store.save(session); // FIX: save(SessionModel) not save(session: ...)
        debugPrint('=== Reset interrupted upload to $newStatus');
      }
      await UploadResumeService().clearUpload();
    }
  } catch (e) {
    debugPrint('=== Upload resume check failed: $e');
  }

  try {
    await LocalVideoStorage.requestStoragePermission();
  } catch (e) {
    debugPrint('=== Storage permission request failed: $e');
  }

  BackendKeepAlive().start();
  CloudCacheService().init();

  runApp(const OTNApp());
}

class OTNApp extends StatelessWidget {
  const OTNApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      routes: {
        '/history': (_) => const HistoryScreen(),
        '/camera':  (_) => const CameraScreen(),
      },
      title: 'OTN',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: kSurface,
        colorScheme: const ColorScheme.light(
          primary:   kGreen,
          secondary: kGreenDark,
          surface:   kCard,
          onPrimary: Colors.white,
          onSurface: kText,
        ),
        useMaterial3: true,
        cardColor:    kCard,
        dividerColor: kBorder,
        appBarTheme: const AppBarTheme(
          backgroundColor:  kCard,
          foregroundColor:  kText,
          elevation:        0,
          surfaceTintColor: Colors.transparent,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
        ),
      ),
      builder: (context, child) {
        ErrorWidget.builder = (FlutterErrorDetails details) {
          return Scaffold(
            backgroundColor: kSurface,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: kGreen, size: 48),
                    const SizedBox(height: 16),
                    const Text('Something went wrong',
                        style: TextStyle(
                            color: kText,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(details.summary.toString(),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: kTextSub, fontSize: 12)),
                  ],
                ),
              ),
            ),
          );
        };
        return child ?? const SizedBox.shrink();
      },
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: kSurface,
              body: Center(child: CircularProgressIndicator(color: kGreen)),
            );
          }
          if (snapshot.hasError) {
            return Scaffold(
              backgroundColor: kSurface,
              body: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.cloud_off, color: kGreen, size: 48),
                  const SizedBox(height: 16),
                  const Text('Connection error',
                      style: TextStyle(
                          color: kText,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text('${snapshot.error}',
                      style: const TextStyle(color: kTextSub, fontSize: 12)),
                ]),
              ),
            );
          }
          if (snapshot.hasData) return const DashboardScreen();
          return const LoginScreen();
        },
      ),
    );
  }
}