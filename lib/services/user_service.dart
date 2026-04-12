import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Fetches and caches the user's display name from Firestore.
/// Admin can update names in Firestore → app picks up on next load.
/// No app update required.
class UserService {
  static final UserService _i = UserService._();
  factory UserService() => _i;
  UserService._();

  final _db = FirebaseFirestore.instance;
  String? _cachedName;

  /// Returns the display name for the current user.
  /// Checks Firestore 'users' collection first, falls back to email prefix.
  Future<String> getDisplayName() async {
    if (_cachedName != null) return _cachedName!;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'User';

    try {
      // Check per-user doc: users/{uid}/displayName
      final doc = await _db.collection('users').doc(user.uid).get();
      if (doc.exists && doc.data()?['displayName'] != null) {
        _cachedName = doc.data()!['displayName'] as String;
        return _cachedName!;
      }

      // Fallback: check email-based lookup in 'user_names' collection
      final email = user.email ?? '';
      final nameDoc = await _db.collection('user_names').doc(email).get();
      if (nameDoc.exists && nameDoc.data()?['name'] != null) {
        _cachedName = nameDoc.data()!['name'] as String;
        return _cachedName!;
      }
    } catch (e) {
      print('=== UserService: Firestore lookup failed: $e');
    }

    // Final fallback: email prefix
    final email = user.email ?? 'User';
    _cachedName = email.split('@').first;
    return _cachedName!;
  }

  /// Returns the OneDrive folder name for the current user.
  /// Same as display name — used when uploading.
  Future<String> getOneDriveFolderName() async => getDisplayName();

  /// Call this when user logs out to clear cache.
  void clearCache() => _cachedName = null;

  /// Admin utility: set a user's display name in Firestore.
  /// Run from Firebase console or a small admin script.
  /// Structure: users/{uid} → {displayName: "Full Name", email: "..."}
  static Future<void> setDisplayName(String uid, String name, String email) async {
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'displayName': name,
      'email': email,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Also index by email for easy lookup
    await FirebaseFirestore.instance.collection('user_names').doc(email).set({
      'name': name,
      'uid': uid,
    }, SetOptions(merge: true));
  }
}