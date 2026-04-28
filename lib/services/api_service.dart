import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/task.dart';
import 'auth_service.dart'; 
import 'dart:io';  

/// Service REST vers Strapi v5.
/// Strapi v5 utilise `documentId` (string) pour update/delete, pas le `id` numérique.
class ApiService {
  static final ApiService instance = ApiService._();
  ApiService._();

  static const String baseUrl = 'http://localhost:1337';        // Câble USB (adb reverse)
  // static const String baseUrl = 'http://10.0.2.2:1337';      // Émulateur Android
  // static const String baseUrl = 'http://192.168.1.223:1337'; // Wi-Fi partagé

  static const _headers = {'Content-Type': 'application/json'};

  // Email de l'utilisateur connecté
  String? currentUserEmail;
  String? currentUserName;

  // Token FCM pour les notifications push
  String? fcmToken;

  // Table de correspondance id numérique (Isar) ↔ documentId Strapi
  // Remplie à chaque getAllTasks / addTask
  final Map<int, String> _docIds = {};

  Uri _uri(String path) => Uri.parse('$baseUrl/api/$path');

  String? _docId(int id) => _docIds[id];

  /// Task Flutter → JSON Strapi (sans createdAt, géré par Strapi)
  Map<String, dynamic> _taskToStrapi(Task task) => {
        'data': {
          'title': task.title,
          'description': task.description,
          'status': task.status,
          'priority': task.priority,
          'deadline': task.deadline,
          'audioPath': task.audioPath,
          'imagePath': task.imagePath,
          'videoPath': task.videoPath,
          'labelsJson': task.labelsJson,
          'checklistJson': task.checklistJson,
          'attachmentsJson': task.attachmentsJson,
          'scheduledNotification': task.scheduledNotification,
          if (currentUserEmail != null) 'createdByEmail': currentUserEmail,
          if (currentUserName != null) 'createdByName': currentUserName,
          if (fcmToken != null) 'fcmToken': fcmToken,
          'assignedTo': task.assignedTo,
        }
      };

  /// Réponse Strapi v5 → Task Flutter
  /// En Strapi v5, les champs sont directement sur l'objet (pas dans `attributes`)
  Task _strapiToTask(Map<String, dynamic> item) {
    final id = item['id'] as int? ?? 0;
    final documentId = item['documentId'] as String?;

    // Mémorise le documentId pour les futures updates/deletes
    if (documentId != null && id != 0) {
      _docIds[id] = documentId;
    }

    final task = Task()
      ..id = id
      ..title = item['title'] as String? ?? ''
      ..description = item['description'] as String?
      ..status = item['status'] as String? ?? 'pending'
      ..priority = item['priority'] as String?
      ..deadline = item['deadline'] as String?
      ..audioPath = item['audioPath'] as String?
      ..imagePath = item['imagePath'] as String?
      ..videoPath = item['videoPath'] as String?
      ..labelsJson = item['labelsJson'] as String?
      ..checklistJson = item['checklistJson'] as String?
      ..attachmentsJson = item['attachmentsJson'] as String?
      ..scheduledNotification = item['scheduledNotification'] as String?
      ..assignedTo = item['assignedTo'] as String?;
    final rawDate = item['createdAt'] as String?;
    if (rawDate != null) task.createdAt = DateTime.tryParse(rawDate) ?? DateTime.now();
    return task;
  }

  // ── CRUD ───────────────────────────────────────────────────────────────────

  Future<List<Task>> getAllTasks() async {
    final res = await http
        .get(_uri('tasks?pagination[pageSize]=200'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('Strapi getAllTasks: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>;
    return data.map((e) => _strapiToTask(e as Map<String, dynamic>)).toList();
  }

  Future<Task> addTask(Task task) async {
    final res = await http
        .post(_uri('tasks'), headers: _headers, body: jsonEncode(_taskToStrapi(task)))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Strapi addTask: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _strapiToTask(body['data'] as Map<String, dynamic>);
  }

  Future<Task> updateTask(Task task) async {
    // Strapi v5 : on utilise le documentId, pas le id numérique
    final docId = _docId(task.id);
    if (docId == null) {
      throw Exception('documentId inconnu pour la tâche ${task.id} — recharge la liste');
    }
    final res = await http
        .put(_uri('tasks/$docId'), headers: _headers, body: jsonEncode(_taskToStrapi(task)))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) {
      throw Exception('Strapi updateTask: ${res.statusCode} ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return _strapiToTask(body['data'] as Map<String, dynamic>);
  }

  /// Récupère la liste des emails des utilisateurs ayant créé des tâches
  /// (utile pour le sélecteur d'assignation)
  Future<List<String>> getKnownUsers() async {
    try {
      final res = await http
          .get(_uri('tasks?fields[0]=createdByEmail&pagination[pageSize]=200'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode != 200) return [];
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>;
      final emails = data
          .map((e) => (e as Map<String, dynamic>)['createdByEmail'] as String?)
          .whereType<String>()
          .toSet()
          .toList();
      return emails;
    } catch (_) {
      return [];
    }
  }

  Future<void> deleteTask(int id) async {
    final docId = _docId(id);
    if (docId == null) {
      throw Exception('documentId inconnu pour la tâche $id');
    }
    final res = await http
        .delete(_uri('tasks/$docId'), headers: _headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception('Strapi deleteTask: ${res.statusCode} ${res.body}');
    }
    _docIds.remove(id);
  }

  // On récupère l'email depuis Firebase
  String get _currentUserEmail => AuthService.instance.userEmail;



  // ── LOGIQUE UPLOAD ────────────────────────────────────────────────────────

  Future<String?> _getPresignedUrl(String fileName) async {
    try {
      final res = await http.post(
        _uri('s3-upload/get-url'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fileName': fileName,
          'fileType': 'audio/mpeg',
          'userEmail': _currentUserEmail, // On envoie l'email Firebase à Strapi
        }),
      );

      if (res.statusCode == 200) {
        return jsonDecode(res.body)['url'];
      }
      return null;
    } catch (e) {
      print("Erreur Strapi: $e");
      return null;
    }
  }

  /// Uploads a file to MinIO via a Strapi presigned URL.
  /// Returns the public URL of the file, or null on failure.
  Future<String?> uploadFile(File file, {String contentType = 'application/octet-stream'}) async {
    try {
      final fileName = file.path.split(RegExp(r'[/\\]')).last;
      final res = await http.post(
        _uri('s3-upload/get-url'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'fileName': fileName,
          'fileType': contentType,
          'userEmail': currentUserEmail ?? 'anonymous',
        }),
      ).timeout(const Duration(seconds: 10));

      if (res.statusCode != 200) return null;

      final json = jsonDecode(res.body) as Map<String, dynamic>;
      String uploadUrl = json['url'] as String;
      final fileKey = json['fileKey'] as String;

      final bytes = await file.readAsBytes();
      final putRes = await http.put(
        Uri.parse(uploadUrl),
        body: bytes,
        headers: {'Content-Type': contentType},
      ).timeout(const Duration(seconds: 60));

      if (putRes.statusCode != 200) return null;

      // Construit l'URL publique depuis les variables d'env Strapi
      const minioEndpoint = 'http://localhost:9000'; // même logique que baseUrl
      const minioBucket = 'my-bucket-file';
      return '$minioEndpoint/$minioBucket/$fileKey';
    } catch (e) {
      print('Erreur upload MinIO: $e');
      return null;
    }
  }
}
