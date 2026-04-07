import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:task_media_app/pages/task_list_page.dart';

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
// 2. Canal Android (obligatoire Android 8+)
// ─────────────────────────────────────────────────────────────────────────────
const _androidChannel = AndroidNotificationChannel(
  'high_importance_channel',
  'Notifications importantes',
  description: 'Canal pour les notifications de tâches',
  importance: Importance.max,
  playSound: true,
);

final FlutterLocalNotificationsPlugin _localNotifications =
    FlutterLocalNotificationsPlugin();

// ─────────────────────────────────────────────────────────────────────────────
// 3. main() — tout l'init ici, jamais dans build()
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase init
  await Firebase.initializeApp();

  // Background handler — doit être enregistré juste après initializeApp
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  // Initialiser le plugin de notifications locales
  await _initLocalNotifications();

  // Demander la permission (Android 13+ et iOS)
  await _requestPermissions();

  // Afficher le token FCM pour les tests
  final token = await FirebaseMessaging.instance.getToken();
  debugPrint('✅ FCM Token: $token');

  runApp(const MyApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Init notifications locales (nécessaire pour afficher en foreground)
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _initLocalNotifications() async {
  // Créer le canal Android
  await _localNotifications
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_androidChannel);

  // Init du plugin
  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  await _localNotifications.initialize(
    const InitializationSettings(
        android: androidSettings, iOS: iosSettings),
  );

  // Forcer l'affichage des notifications FCM en FOREGROUND sur iOS
  await FirebaseMessaging.instance
      .setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Demande de permission
// ─────────────────────────────────────────────────────────────────────────────
Future<void> _requestPermissions() async {
  final settings = await FirebaseMessaging.instance.requestPermission(
    alert: true,
    badge: true,
    sound: true,
    provisional: false,
  );
  debugPrint('🔔 Permission: ${settings.authorizationStatus}');
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

      // Afficher via flutter_local_notifications (FCM seul ne suffit pas en foreground Android)
      _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _androidChannel.id,
            _androidChannel.name,
            channelDescription: _androidChannel.description,
            importance: Importance.max,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Service de navigation globale (pour dialogues depuis callbacks)
// ─────────────────────────────────────────────────────────────────────────────
class NotificationService {
  static final navigatorKey = GlobalKey<NavigatorState>();

  static void showNotificationDialog(String title, String body) {
    final context = navigatorKey.currentContext;
    if (context == null) return;

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.notifications, color: Color(0xFF6366F1)),
            const SizedBox(width: 8),
            Expanded(child: Text(title)),
          ],
        ),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () =>
                navigatorKey.currentState?.pop(),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }
}