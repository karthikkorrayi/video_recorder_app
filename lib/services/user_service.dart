import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Single source of truth for resolving the current user's display name.
///
/// Priority:
///   1. Firestore: users/{uid}/displayName
///   2. Firestore: user_names/{email}/name
///   3. Fallback: email prefix (e.g. "test" from test@otn.in)
///
/// Result is cached in memory for the session lifetime.
/// Call [clearCache] on logout.
class UserService {
  static final UserService _instance = UserService._internal();
  factory UserService() => _instance;
  UserService._internal();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  String? _cachedName;

  /// Returns the display name for the current logged-in user.
  /// Used for: dashboard greeting, OneDrive folder name, sync verification.
  Future<String> getDisplayName() async {
    if (_cachedName != null) return _cachedName!;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'User';

    try {
      // 1. Check users/{uid} doc
      final doc = await _db.collection('users').doc(user.uid).get();
      if (doc.exists && doc.data()?['displayName'] != null) {
        _cachedName = doc.data()!['displayName'] as String;
        return _cachedName!;
      }

      // 2. Check user_names/{email} doc
      final email = user.email ?? '';
      if (email.isNotEmpty) {
        final nameDoc =
            await _db.collection('user_names').doc(email).get();
        if (nameDoc.exists && nameDoc.data()?['name'] != null) {
          _cachedName = nameDoc.data()!['name'] as String;
          return _cachedName!;
        }
      }
    } catch (e) {
      // Firestore unavailable — fall through to email prefix
    }

    // 3. Fallback: email prefix
    final email = user.email ?? 'User';
    _cachedName = email.split('@').first;
    return _cachedName!;
  }

  /// Same as [getDisplayName] — alias used for OneDrive folder name.
  Future<String> getOneDriveFolderName() => getDisplayName();

  /// Clear cache on logout so next user gets fresh lookup.
  void clearCache() => _cachedName = null;

  /// Admin utility — sets displayName in Firestore for a user.
  /// Call this from your admin panel or Firebase console script.
  static Future<void> setDisplayName(
      String uid, String name, String email) async {
    final db = FirebaseFirestore.instance;
    await db.collection('users').doc(uid).set(
        {'displayName': name, 'email': email},
        SetOptions(merge: true));
    await db.collection('user_names').doc(email).set(
        {'name': name, 'uid': uid},
        SetOptions(merge: true));
  }
}