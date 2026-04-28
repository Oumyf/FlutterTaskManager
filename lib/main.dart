import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:task_media_app/pages/login_page.dart';
import 'package:task_media_app/pages/task_list_page.dart';
import 'package:task_media_app/services/api_service.dart';
import 'package:task_media_app/services/auth_service.dart';
import 'package:task_media_app/services/notification_serve.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Handler background FCM — doit être top-level
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('📩 Background message: ${message.messageId}');
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await NotificationService.instance.init();
  await NotificationService.instance.requestPermission();

  runApp(const MyApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// App root
// ─────────────────────────────────────────────────────────────────────────────
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Task Media App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6366F1)),
        useMaterial3: true,
      ),
      navigatorKey: NotificationService.navigatorKey,
      home: const _AuthGate(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AuthGate — redirige automatiquement selon l'état Firebase Auth
// ─────────────────────────────────────────────────────────────────────────────
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: AuthService.instance.authStateChanges,
      builder: (context, snapshot) {
        // En attente de la réponse Firebase
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Connecté → page des tâches
        if (snapshot.hasData && snapshot.data != null) {
          return const _AppShell();
        }

        // Non connecté → page de login
        return const LoginPage();
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AppShell — écoute FCM une fois connecté
// ─────────────────────────────────────────────────────────────────────────────
class _AppShell extends StatefulWidget {
  const _AppShell();

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  @override
  void initState() {
    super.initState();
    _setupFCM();
  }

  void _setupFCM() async {
    // Récupère le token FCM et le stocke dans ApiService
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) _storeFcmToken(token);
      FirebaseMessaging.instance.onTokenRefresh.listen(_storeFcmToken);
    } catch (e) {
      debugPrint('[FCM] Erreur token: $e');
    }

    // Notification reçue quand l'app est au premier plan
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification == null) return;
      NotificationService.instance.showFCMNotification(
        notification.title ?? '',
        notification.body ?? '',
      );
    });

    // App ouverte depuis une notification
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Opened from notification: ${message.notification?.title}');
    });
  }

  void _storeFcmToken(String token) {
    debugPrint('[FCM] Token enregistré');
    ApiService.instance.fcmToken = token;
  }

  @override
  Widget build(BuildContext context) => const TaskListPage();
}
