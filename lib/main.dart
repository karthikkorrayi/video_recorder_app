import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: 'AIzaSyAU5jiCE8sCIMjm0ywBFnHupvOIAkCbMLM',
      appId: '1:164325680744:android:4f0c0284c3a3db8e4f7ddd',
      messagingSenderId: '164325680744',
      projectId: 'videorecorderapp-305b8',
      storageBucket: 'videorecorderapp-305b8.firebasestorage.app',
    ),
  );
  runApp(const VideoApp());
}

class VideoApp extends StatelessWidget {
  const VideoApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Recorder',
      theme: ThemeData.dark(),
      home: const LoginScreen(),
    );
  }
}