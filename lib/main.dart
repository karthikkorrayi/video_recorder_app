import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'services/local_video_storage.dart';
import 'services/notification_service.dart';

// ── Ben10 Omnitrix colour palette ────────────────────────────────────────────
// Inspired by the Omnitrix watch: white face, bright green accents, black trim
const kGreen     = Color(0xFF00C853); // Omnitrix green
const kGreenDark = Color(0xFF00A045); // darker green for pressed states
const kBlack     = Color(0xFF0D0D0D); // near-black (watch body)
const kSurface   = Color(0xFFF4F4F4); // light grey surface
const kCard      = Color(0xFFFFFFFF); // white card
const kBorder    = Color(0xFFE0E0E0); // subtle border
const kText      = Color(0xFF1A1A1A); // primary text
const kTextSub   = Color(0xFF666666); // secondary text

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService().init();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Light status bar (dark icons on white background)
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarBrightness: Brightness.light,
    statusBarIconBrightness: Brightness.dark,
  ));

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyAU5jiCE8sCIMjm0ywBFnHupvOIAkCbMLM',
      appId: '1:164325680744:android:4f0c0284c3a3db8e4f7ddd',
      messagingSenderId: '164325680744',
      projectId: 'videorecorderapp-305b8',
      storageBucket: 'videorecorderapp-305b8.firebasestorage.app',
    ),
  );

  await LocalVideoStorage.requestStoragePermission();
  runApp(const OTNApp());
}

class OTNApp extends StatelessWidget {
  const OTNApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OTN',
      debugShowCheckedModeBanner: false,
      // Light theme — Ben10 Omnitrix style
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: kSurface,
        colorScheme: const ColorScheme.light(
          primary: kGreen,
          secondary: kGreenDark,
          surface: kCard,
          background: kSurface,
          onPrimary: Colors.white,
          onSurface: kText,
        ),
        useMaterial3: true,
        cardColor: kCard,
        dividerColor: kBorder,
        appBarTheme: const AppBarTheme(
          backgroundColor: kCard,
          foregroundColor: kText,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: kGreen,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
        ),
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: kSurface,
              body: Center(child: CircularProgressIndicator(color: kGreen)),
            );
          }
          if (snapshot.hasData) return const DashboardScreen();
          return const LoginScreen();
        },
      ),
    );
  }
}