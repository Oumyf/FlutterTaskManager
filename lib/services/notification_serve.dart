import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

// ─────────────────────────────────────────────────────────────────────────────
// NotificationService — singleton
// Gère les notifications locales : création tâche, modification, rappel échéance
// ─────────────────────────────────────────────────────────────────────────────
class NotificationService {
  static final navigatorKey = GlobalKey<NavigatorState>();

  // Affiche une notification FCM (titre + body)
  Future<void> showFCMNotification(String title, String body) async {
    await _show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title: title,
      body: body,
    );
  }
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();

  // Canal Android haute importance
  static const _channel = AndroidNotificationChannel(
    'tasks_channel',
    'Tâches',
    description: 'Notifications pour vos tâches',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  // IDs fixes par type de notif
  static const _idCreated  = 1000;
  static const _idUpdated  = 1001;

  // ── Init (à appeler dans main() avant runApp) ───────────────────────────

  Future<void> init() async {
    tz_data.initializeTimeZones();

    // Créer le canal Android
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_channel);

    // Init settings
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _onTap,
    );
  }

  // ── Demande de permission (Android 13+) ─────────────────────────────────

  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  // ── Notification : tâche créée ───────────────────────────────────────────

  Future<void> notifyTaskCreated(String title, {String? deadline}) async {
    final body = deadline != null && deadline.isNotEmpty
        ? 'Échéance : $deadline'
        : 'Nouvelle tâche ajoutée à votre liste';

    await _show(
      id: _idCreated,
      title: '✅ Tâche créée',
      body: '"$title" — $body',
      icon: '📋',
    );

    // Si une échéance est définie → programmer un rappel la veille
    if (deadline != null && deadline.isNotEmpty) {
      await _scheduleDeadlineReminder(title, deadline);
    }
  }

  // ── Notification : tâche modifiée ────────────────────────────────────────

  Future<void> notifyTaskUpdated(String title, String newStatus) async {
    final statusLabel = _statusLabel(newStatus);
    await _show(
      id: _idUpdated,
      title: '✏️ Tâche modifiée',
      body: '"$title" est maintenant : $statusLabel',
      icon: '🔄',
    );
  }

  // ── Rappel programmé la veille de l'échéance ─────────────────────────────

  Future<void> _scheduleDeadlineReminder(
      String taskTitle, String deadline) async {
    try {
      final date = DateTime.parse(deadline);
      final reminderDate = date.subtract(const Duration(days: 1));
      final now = DateTime.now();

      // Ne programme pas si c'est dans le passé
      if (reminderDate.isBefore(now)) return;

      final scheduled = tz.TZDateTime.from(reminderDate, tz.local);
      await _plugin.zonedSchedule(
        date.millisecondsSinceEpoch ~/ 1000, // ID unique basé sur la date
        '⏰ Rappel d\'échéance demain',
        '"$taskTitle" arrive à échéance demain',
        scheduled, // ✅ Bon type
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
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
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {
      // Date invalide → on ignore silencieusement
    }
  }

  // ── Notification programmée par l'utilisateur ────────────────────────────

  Future<void> scheduleTaskNotification({
    required int taskId,
    required String taskTitle,
    required DateTime scheduledDate,
  }) async {
    try {
      if (scheduledDate.isBefore(DateTime.now())) return;

      final scheduled = tz.TZDateTime.from(scheduledDate, tz.local);
      await _plugin.zonedSchedule(
        taskId.abs() % 100000 + 2000, // ID unique basé sur l'id de la tâche
        '🔔 Rappel de tâche',
        taskTitle,
        scheduled,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
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
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {}
  }

  Future<void> cancelScheduledNotification(int taskId) async {
    await _plugin.cancel(taskId.abs() % 100000 + 2000);
  }

  // ── Annuler un rappel programmé ──────────────────────────────────────────

  Future<void> cancelDeadlineReminder(String deadline) async {
    try {
      final date = DateTime.parse(deadline);
      await _plugin.cancel(date.millisecondsSinceEpoch ~/ 1000);
    } catch (_) {}
  }

  // ── Affichage immédiat ───────────────────────────────────────────────────

  Future<void> _show({
    required int id,
    required String title,
    required String body,
    String icon = '',
  }) async {
    await _plugin.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          styleInformation: BigTextStyleInformation(body),
          ticker: title,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  String _statusLabel(String s) {
    switch (s) {
      case 'in_progress': return 'En cours 🔄';
      case 'completed':   return 'Terminée ✅';
      case 'archived':    return 'Archivée 📦';
      default:            return 'À faire 📝';
    }
  }

  void _onTap(NotificationResponse response) {
    // TODO: naviguer vers la tâche concernée
  }
}
