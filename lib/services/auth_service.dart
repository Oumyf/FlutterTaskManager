import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  // Stream de l'état de connexion — écoute dans main.dart
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Utilisateur courant
  User? get currentUser => _auth.currentUser;
  String get userEmail => currentUser?.email ?? '';
  String get userName  => currentUser?.displayName ?? currentUser?.email?.split('@').first ?? 'Utilisateur';
  String? get userPhoto => currentUser?.photoURL;

  // ── Inscription email / mot de passe ──────────────────────────────────────

  Future<UserCredential> register({
    required String email,
    required String password,
    required String name,
  }) async {
    final cred = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    // Mettre à jour le nom d'affichage
    await cred.user?.updateDisplayName(name.trim());
    await cred.user?.reload();
    return cred;
  }

  // ── Connexion email / mot de passe ────────────────────────────────────────

  Future<UserCredential> signInWithEmail({
    required String email,
    required String password,
  }) async {
    return await _auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  // ── Connexion Google ──────────────────────────────────────────────────────

  Future<UserCredential?> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null; // annulé par l'utilisateur

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return await _auth.signInWithCredential(credential);
  }

  // ── Réinitialisation mot de passe ─────────────────────────────────────────

  Future<void> sendPasswordReset(String email) async {
    await _auth.sendPasswordResetEmail(email: email.trim());
  }

  // ── Déconnexion ───────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  // ── Traduction des erreurs Firebase → messages lisibles ───────────────────

  static String errorMessage(FirebaseAuthException e) {
    switch (e.code) {
      case 'email-already-in-use':  return 'Cette adresse email est déjà utilisée.';
      case 'invalid-email':         return 'Adresse email invalide.';
      case 'weak-password':         return 'Mot de passe trop faible (6 caractères min).';
      case 'user-not-found':        return 'Aucun compte trouvé avec cet email.';
      case 'wrong-password':        return 'Mot de passe incorrect.';
      case 'invalid-credential':    return 'Email ou mot de passe incorrect.';
      case 'too-many-requests':     return 'Trop de tentatives. Réessayez plus tard.';
      case 'network-request-failed':return 'Erreur réseau. Vérifiez votre connexion.';
      default:                      return 'Erreur : ${e.message}';
    }
  }
}
