import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:task_media_app/pages/task_list_page.dart';
import 'package:task_media_app/services/notification_serve.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. Handler background — doit être TOP-LEVEL (pas dans une classe)
//    et déclaré AVANT tout le reste
// ─────────────────────────────────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint('📩 Background message: ${message.messageId}');
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. main() — tout l'init ici, jamais dans build()
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase init
  await Firebase.initializeApp();

  // Background handler — doit être enregistré juste après initializeApp
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Initialiser NotificationService (local + FCM)
  await NotificationService.instance.init();
  await NotificationService.instance.requestPermission();

  // Afficher le token FCM pour les tests
  final token = await FirebaseMessaging.instance.getToken();
  debugPrint('✅ FCM Token: $token');

  runApp(const MyApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// App widget
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
      // NavigatorKey nécessaire pour afficher des dialogs depuis des callbacks
      navigatorKey: NotificationService.navigatorKey,
      home: const _AppInit(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widget qui écoute les messages — STATEFUL pour gérer le lifecycle
// Les listeners sont dans initState/dispose, jamais dans build()
// ─────────────────────────────────────────────────────────────────────────────
class _AppInit extends StatefulWidget {
  const _AppInit();

  @override
  State<_AppInit> createState() => _AppInitState();
}

class _AppInitState extends State<_AppInit> {
  @override
  void initState() {
    super.initState();
    _setupForegroundListener();
    _setupOnOpenedListener();
  }

  // Notification reçue quand l'app est OUVERTE (foreground)
  void _setupForegroundListener() {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('📱 Foreground message: ${message.notification?.title}');

      final notification = message.notification;
      if (notification == null) return;

      // Affiche la notif via NotificationService (centralisé)
      NotificationService.instance.showFCMNotification(
        notification.title ?? '',
        notification.body ?? '',
      );
    });
  }

  // App ouverte depuis une notification (background → foreground)
  void _setupOnOpenedListener() {
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('🚀 Opened from notification: ${message.notification?.title}');
      // TODO: naviguer vers la bonne page selon message.data
    });
  }

  @override
  Widget build(BuildContext context) {
    return const TaskListPage();
  }
}

// (La classe NotificationService pour la navigation/dialog a été supprimée. Utilise le singleton de notification_serve.dart)