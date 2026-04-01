import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'services/local_video_storage.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // Request storage permission before showing UI
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
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F0F0F),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFFE8620A),
          secondary: const Color(0xFFFF9D4A),
          surface: const Color(0xFF1A1A1A),
          background: const Color(0xFF0F0F0F),
        ),
        useMaterial3: true,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: Color(0xFF0F0F0F),
              body: Center(child: CircularProgressIndicator(color: Color(0xFFE8620A))),
            );
          }
          if (snapshot.hasData) return const DashboardScreen();
          return const LoginScreen();
        },
      ),
    );
  }
}