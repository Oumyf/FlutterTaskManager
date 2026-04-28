import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_whisper_kit/flutter_whisper_kit.dart';
import 'package:whisper_kit/whisper_kit.dart' as wk;
import '../models/task.dart';
import '../services/isar_service.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/notification_serve.dart';
import 'task_detail_page.dart';
import 'settings_page.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Couleurs globales
// ─────────────────────────────────────────────────────────────────────────────
const _primary = Color(0xFF6366F1);
const _surface = Color(0xFFF4F4FF);
const _cardBg = Colors.white;
const _green = Color(0xFF10B981);   // completed
const _blue = Color(0xFF3B82F6);    // in_progress
const _red = Color(0xFFEF4444);     // high priority / delete
const _amber = Color(0xFFF59E0B);   // pending
const _grey = Color(0xFF94A3B8);    // archived / low priority

// Palette étiquettes (8 couleurs)
const _labelPalette = [
  Color(0xFFEF4444), // rouge
  Color(0xFFF59E0B), // orange
  Color(0xFF10B981), // vert
  Color(0xFF3B82F6), // bleu
  Color(0xFF8B5CF6), // violet
  Color(0xFFEC4899), // rose
  Color(0xFF06B6D4), // cyan
  Color(0xFF64748B), // ardoise
];

// ─────────────────────────────────────────────────────────────────────────────
// Widget principal
// ─────────────────────────────────────────────────────────────────────────────
class TaskListPage extends StatefulWidget {
  const TaskListPage({super.key});
  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage>
    with SingleTickerProviderStateMixin {
  int _currentPage = 0;
  String _statusFilter = 'all';
  DateTime? _filterDateStart;
  DateTime? _filterDateEnd;
  Task? _editingTask;
  int? _transcribingTaskId;
  static const String _transcriptMarker = '\n\n[TRANSCRIPTION_AUDIO]\n';

  final TextEditingController _searchController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autoValidateMode = AutovalidateMode.disabled;

  // Services
  final IsarService isarService = IsarService();
  final ApiService _api = ApiService.instance;

  // true = les tâches viennent de Strapi, false = local Isar uniquement
  bool _useStrapi = false;

  final ImagePicker _picker = ImagePicker();
  final FlutterWhisperKit _whisperKit = FlutterWhisperKit();

  // ✅ CORRECTION : WhisperModel.small (smallQ5_1 n'existe pas), sans const
  final wk.Whisper _androidWhisper = wk.Whisper(model: wk.WhisperModel.small);

  bool _isTranscribingAudio = false;
  bool _whisperModelLoaded = false;

  // Serveur Whisper distant
  String _serverUrl = '';
  static const _prefKeyServer = 'whisper_server_url';
  final _serverController = TextEditingController();

  // Formulaire
  final titleController = TextEditingController();
  final descriptionController = TextEditingController();
  final deadlineController = TextEditingController();
  String status = 'pending';
  String? priority;
  String? imagePath;
  String? videoPath;
  String? audioPath;

  // Audio
  final Record _recorder = Record();
  bool _isRecording = false;
  bool _hasAudioDraft = false;
  Duration _recordDuration = Duration.zero;
  late AnimationController _pulseController;

  // Étiquettes, checklist et pièces jointes (formulaire en cours)
  List<Map<String, dynamic>> _labels = [];
  List<Map<String, dynamic>> _checklist = [];
  List<Map<String, dynamic>> _attachments = [];

  // Assignation
  String? _assignedTo;
  List<String> _knownUsers = [];

  // Notification programmée
  DateTime? _scheduledNotifDate;

  // Image de fond du board
  String? _boardBgPath;
  static const _prefBgKey = 'board_background_path';

  // Données
  List<Task> tasks = [];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _detectStrapi().then((_) async {
      await loadTasks();
      _loadKnownUsers();
    });
    _preloadWhisperModel();
    _loadServerUrl();
    _loadBoardBg();
  }

  Future<void> _preloadWhisperModel() async {
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        // ✅ CORRECTION : small au lieu de medium (plus rapide, bonne précision)
        await _whisperKit.loadModel('small');
        _whisperModelLoaded = true;
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _recorder.dispose();
    _searchController.dispose();
    _serverController.dispose();
    titleController.dispose();
    descriptionController.dispose();
    deadlineController.dispose();
    super.dispose();
  }

  // ── Serveur Whisper ──────────────────────────────────────────────────────

  Future<void> _loadServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKeyServer) ?? '';
    setState(() {
      _serverUrl = saved;
      _serverController.text = saved;
    });
  }

  Future<void> _saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyServer, url);
    setState(() => _serverUrl = url);
  }

  bool get _hasServer => _serverUrl.trim().isNotEmpty;

  Future<void> _loadBoardBg() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _boardBgPath = prefs.getString(_prefBgKey));
  }

  /// Envoie le fichier audio au serveur FastAPI et retourne le texte transcrit.
  Future<String> _transcribeViaServer(String audioPath) async {
    final uri = Uri.parse('${_serverUrl.trimRight()}/transcribe');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(await http.MultipartFile.fromPath('file', audioPath));

    final streamed = await request.send()
        .timeout(const Duration(seconds: 60));
    final body = await streamed.stream.bytesToString();

    if (streamed.statusCode != 200) {
      throw Exception('Erreur serveur ${streamed.statusCode} : $body');
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    return (json['text'] as String? ?? '').trim();
  }

  // ── Données ──────────────────────────────────────────────────────────────

  Future<void> loadTasks() async {
    if (_useStrapi) {
      try {
        final loaded = await _api.getAllTasks();
        setState(() => tasks = loaded);
        return;
      } catch (e) {
        // Strapi inaccessible → bascule sur Isar
        setState(() => _useStrapi = false);
        _showSnack('Strapi hors ligne, mode local activé');
      }
    }
    final loaded = await isarService.getAllTasks();
    setState(() => tasks = loaded);
  }

  Future<void> _loadKnownUsers() async {
    if (!_useStrapi) return;
    final users = await _api.getKnownUsers();
    // Ajoute l'utilisateur courant s'il n'est pas dedans
    final me = AuthService.instance.userEmail;
    if (me.isNotEmpty && !users.contains(me)) users.insert(0, me);
    if (mounted) setState(() => _knownUsers = users);
  }

  // ── Helpers CRUD centralisés ─────────────────────────────────────────────

  /// Crée une nouvelle tâche (Strapi si connecté, sinon Isar)
  Future<void> _persistNewTask(Task task) async {
    if (_useStrapi) {
      try {
        final saved = await _api.addTask(task);
        task.id = saved.id;
      } catch (e) {
        debugPrint('[Strapi addTask] $e');
        setState(() => _useStrapi = false);
        await isarService.addTask(task);
      }
    } else {
      await isarService.addTask(task);
    }
  }

  /// Met à jour une tâche existante (Strapi si connecté, sinon Isar)
  Future<void> _persistUpdate(Task task) async {
    if (_useStrapi) {
      try {
        await _api.updateTask(task);
      } catch (e) {
        debugPrint('[Strapi updateTask] $e');
        await isarService.updateTask(task);
      }
    } else {
      await isarService.updateTask(task);
    }
  }

  /// Supprime une tâche (Strapi si connecté, sinon Isar)
  Future<void> _persistDelete(int id) async {
    if (_useStrapi) {
      try {
        await _api.deleteTask(id);
      } catch (e) {
        debugPrint('[Strapi deleteTask] $e');
        await isarService.deleteTask(id);
      }
    } else {
      await isarService.deleteTask(id);
    }
  }

  /// Teste la connexion Strapi et bascule automatiquement si disponible.
  Future<void> _detectStrapi() async {
    // Passe l'utilisateur connecté à ApiService pour le champ createdBy
    final user = AuthService.instance.currentUser;
    _api.currentUserEmail = user?.email;
    _api.currentUserName = user?.displayName ?? user?.email?.split('@').first;

    try {
      await _api.getAllTasks().timeout(const Duration(seconds: 3));
      setState(() => _useStrapi = true);
      _showSnack('Connecté à Strapi ✓');
    } catch (e) {
      setState(() => _useStrapi = false);
      // Affiche l'erreur exacte dans le snackbar pour diagnostiquer
      _showSnack('Strapi: $e', isError: true);
      debugPrint('[Strapi] Non disponible : $e');
    }
  }

  Future<void> addTask() async {
    final hasTitle = titleController.text.trim().isNotEmpty;
    final hasAudio = audioPath != null;
    if (!hasTitle && !hasAudio) {
      _showSnack('Écrivez un titre ou enregistrez un audio', isError: true);
      return;
    }

    String? finalImagePath = imagePath;
    String? finalVideoPath = videoPath;
    String? finalAudioPath = audioPath;
    if (_useStrapi) {
      if (imagePath != null && !imagePath!.startsWith('http')) {
        _showSnack('Envoi de l\'image...');
        finalImagePath = await _api.uploadFile(File(imagePath!), contentType: 'image/jpeg') ?? imagePath;
      }
      if (videoPath != null && !videoPath!.startsWith('http')) {
        _showSnack('Envoi de la vidéo...');
        finalVideoPath = await _api.uploadFile(File(videoPath!), contentType: 'video/mp4') ?? videoPath;
      }
      if (audioPath != null && !audioPath!.startsWith('http')) {
        _showSnack('Envoi de l\'audio...');
        finalAudioPath = await _api.uploadFile(File(audioPath!), contentType: 'audio/mpeg') ?? audioPath;
      }
    }

    final task = Task()
      ..title = hasTitle ? titleController.text.trim() : '🎤 Note vocale'
      ..description = descriptionController.text
      ..status = status
      ..priority = priority
      ..deadline = deadlineController.text
      ..imagePath = finalImagePath
      ..videoPath = finalVideoPath
      ..audioPath = finalAudioPath
      ..labelsJson = _labels.isEmpty ? null : jsonEncode(_labels)
      ..checklistJson = _checklist.isEmpty ? null : jsonEncode(_checklist)
      ..attachmentsJson = _attachments.isEmpty ? null : jsonEncode(_attachments)
      ..scheduledNotification = _scheduledNotifDate?.toIso8601String()
      ..assignedTo = _assignedTo;
    await _persistNewTask(task);
    await NotificationService.instance.notifyTaskCreated(
      task.title,
      deadline: task.deadline,
    );
    if (_scheduledNotifDate != null) {
      await NotificationService.instance.scheduleTaskNotification(
        taskId: task.id,
        taskTitle: task.title,
        scheduledDate: _scheduledNotifDate!,
      );
    }
    _showSnack('Tâche créée');
    _resetForm();
    setState(() => _currentPage = 0);
    await loadTasks();
  }

  Future<void> updateTask() async {
    final current = _editingTask;
    if (current == null) return;

    final hasTitle = titleController.text.trim().isNotEmpty;
    final hasAudio = audioPath != null;
    if (!hasTitle && !hasAudio) {
      _showSnack('Écrivez un titre ou enregistrez un audio', isError: true);
      return;
    }

    String? finalImagePath = imagePath;
    String? finalVideoPath = videoPath;
    String? finalAudioPath = audioPath;
    if (_useStrapi) {
      if (imagePath != null && !imagePath!.startsWith('http')) {
        _showSnack('Envoi de l\'image...');
        finalImagePath = await _api.uploadFile(File(imagePath!), contentType: 'image/jpeg') ?? imagePath;
      }
      if (videoPath != null && !videoPath!.startsWith('http')) {
        _showSnack('Envoi de la vidéo...');
        finalVideoPath = await _api.uploadFile(File(videoPath!), contentType: 'video/mp4') ?? videoPath;
      }
      if (audioPath != null && !audioPath!.startsWith('http')) {
        _showSnack('Envoi de l\'audio...');
        finalAudioPath = await _api.uploadFile(File(audioPath!), contentType: 'audio/mpeg') ?? audioPath;
      }
    }

    current
      ..title = hasTitle ? titleController.text.trim() : '🎤 Note vocale'
      ..description = descriptionController.text
      ..status = status
      ..priority = priority
      ..deadline = deadlineController.text
      ..imagePath = finalImagePath
      ..videoPath = finalVideoPath
      ..audioPath = finalAudioPath
      ..labelsJson = _labels.isEmpty ? null : jsonEncode(_labels)
      ..checklistJson = _checklist.isEmpty ? null : jsonEncode(_checklist)
      ..attachmentsJson = _attachments.isEmpty ? null : jsonEncode(_attachments)
      ..scheduledNotification = _scheduledNotifDate?.toIso8601String()
      ..assignedTo = _assignedTo;

    await _persistUpdate(current);
    await NotificationService.instance
        .notifyTaskUpdated(current.title, current.status);
    // Annuler l'ancienne notif, reprogrammer si une date est définie
    await NotificationService.instance.cancelScheduledNotification(current.id);
    if (_scheduledNotifDate != null) {
      await NotificationService.instance.scheduleTaskNotification(
        taskId: current.id,
        taskTitle: current.title,
        scheduledDate: _scheduledNotifDate!,
      );
    }
    _showSnack('Tâche modifiée');
    _resetForm();
    setState(() {
      _editingTask = null;
      _currentPage = 0;
    });
    await loadTasks();
  }

  Future<void> _submitTask() async {
    FocusScope.of(context).unfocus();
    final isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid) {
      setState(() => _autoValidateMode = AutovalidateMode.onUserInteraction);
      _showSnack('Veuillez corriger les champs du formulaire', isError: true);
      return;
    }
    if (_editingTask == null) {
      await addTask();
      return;
    }
    await updateTask();
  }

  void _startEditing(Task task) {
    titleController.text = task.title;
    descriptionController.text = task.description ?? '';
    deadlineController.text = task.deadline ?? '';

    setState(() {
      _editingTask = task;
      status = task.status;
      priority = task.priority;
      imagePath = task.imagePath;
      videoPath = task.videoPath;
      audioPath = task.audioPath;
      _hasAudioDraft = task.audioPath != null && task.audioPath!.isNotEmpty;
      _currentPage = 1;
      _autoValidateMode = AutovalidateMode.disabled;
      _labels = _TaskListPageState._parseLabels(task.labelsJson);
      _checklist = _TaskListPageState._parseChecklist(task.checklistJson);
      _attachments = _TaskListPageState._parseAttachments(task.attachmentsJson);
      _scheduledNotifDate = task.scheduledNotification != null
          ? DateTime.tryParse(task.scheduledNotification!)
          : null;
      _assignedTo = task.assignedTo;
    });
  }

  // ── Transcription ─────────────────────────────────────────────────────────

  Future<void> _transcribeDraftAudio() async {
    if (audioPath == null || audioPath!.isEmpty) {
      _showSnack('Aucun audio à transcrire', isError: true);
      return;
    }
    if (Platform.isAndroid) {
      await _transcribeOnAndroid(audioPath!, onDone: _appendTranscription);
      return;
    }
    if (!(Platform.isIOS || Platform.isMacOS)) {
      _showSnack('Transcription non supportée sur cette plateforme',
          isError: true);
      return;
    }
    await _transcribeOnIos(audioPath!, onDone: _appendTranscription);
  }

  Future<void> _transcribeOnIos(
    String path, {
    required void Function(String) onDone,
  }) async {
    setState(() => _isTranscribingAudio = true);
    try {
      if (!_whisperModelLoaded) {
        await _whisperKit.loadModel('small');
        _whisperModelLoaded = true;
      }
      // ✅ CORRECTION : pas de decodingOptions (non exposé dans ce package)
      final result = await _whisperKit.transcribeFromFile(path);
      final text = result?.text.trim() ?? '';
      if (text.isEmpty) {
        _showSnack('Transcription vide', isError: true);
        return;
      }
      onDone(text);
      _showSnack('Transcription ajoutée');
    } catch (e) {
      _showSnack('Erreur transcription: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isTranscribingAudio = false);
    }
  }

  Future<void> _transcribeOnAndroid(
    String path, {
    required void Function(String) onDone,
  }) async {
    // ── Serveur distant disponible → on l'utilise en priorité ───────────────
    if (_hasServer) {
      _showTranscribingDialog();
      setState(() => _isTranscribingAudio = true);
      try {
        final text = await _transcribeViaServer(path);
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        if (text.isEmpty) {
          _showSnack('Transcription vide, réessayez', isError: true);
          return;
        }
        onDone(text);
        _showSnack('Transcription ajoutée ✓');
      } catch (e) {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        _showSnack('Erreur serveur : $e', isError: true);
      } finally {
        if (mounted) setState(() => _isTranscribingAudio = false);
      }
      return;
    }

    // ── Fallback : whisper_kit local (lent sur appareils entrée de gamme) ───
    if (!path.toLowerCase().endsWith('.wav')) {
      _showSnack('Enregistrez un nouvel audio WAV 16 kHz pour Android',
          isError: true);
      return;
    }

    _showTranscribingDialog();
    setState(() => _isTranscribingAudio = true);
    try {
      final result = await _androidWhisper.transcribe(
        transcribeRequest: wk.TranscribeRequest(
          audio: path,
          language: 'fr',
          isNoTimestamps: true,
          isTranslate: false,
          threads: 4,
          nProcessors: 1,
        ),
      );

      if (mounted) Navigator.of(context, rootNavigator: true).pop();

      final text = result.text.trim();
      if (text.isEmpty) {
        _showSnack('Transcription vide, réessayez', isError: true);
        return;
      }
      onDone(text);
      _showSnack('Transcription ajoutée');
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      final msg = e.toString();
      if (msg.contains('MODEL_DOWNLOAD_FAILED') ||
          msg.contains('huggingface') ||
          msg.contains('Network error')) {
        _showModelDownloadDialog();
      } else {
        _showSnack('Erreur transcription: $msg', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isTranscribingAudio = false);
    }
  }

  void _appendTranscription(String text) {
    final existing = descriptionController.text;
    descriptionController.text = _upsertTranscript(existing, text);
    if (mounted) setState(() {});
  }

  String _upsertTranscript(String base, String transcript) {
    final cleaned = transcript.trim();
    if (cleaned.isEmpty) return base;
    final idx = base.indexOf(_transcriptMarker);
    if (idx >= 0) {
      return '${base.substring(0, idx)}$_transcriptMarker$cleaned';
    }
    final prefix = base.trim();
    if (prefix.isEmpty) return '$_transcriptMarker$cleaned';
    return '$prefix$_transcriptMarker$cleaned';
  }

  String? _extractTranscript(String? description) {
    if (description == null || description.isEmpty) return null;
    final idx = description.indexOf(_transcriptMarker);
    if (idx < 0) return null;
    final text =
        description.substring(idx + _transcriptMarker.length).trim();
    return text.isEmpty ? null : text;
  }

  Future<void> _transcribeTaskAudio(Task task) async {
    final path = task.audioPath;
    if (path == null || path.isEmpty) {
      _showSnack('Aucun audio à transcrire', isError: true);
      return;
    }

    setState(() => _transcribingTaskId = task.id);
    try {
      void onDone(String text) async {
        task.description = _upsertTranscript(task.description ?? '', text);
        await _persistUpdate(task);
        await loadTasks();
        _showSnack('Transcription ajoutée à la tâche');
      }

      if (Platform.isAndroid) {
        await _transcribeOnAndroid(path, onDone: onDone);
      } else if (Platform.isIOS || Platform.isMacOS) {
        await _transcribeOnIos(path, onDone: onDone);
      } else {
        _showSnack('Transcription non supportée sur cette plateforme',
            isError: true);
      }
    } catch (e) {
      _showSnack('Erreur transcription tâche: $e', isError: true);
    } finally {
      if (mounted) setState(() => _transcribingTaskId = null);
    }
  }

  Future<void> deleteTask(int id) async {
    await _persistDelete(id);
    await NotificationService.instance.cancelScheduledNotification(id);
    loadTasks();
  }

  void _resetForm() {
    titleController.clear();
    descriptionController.clear();
    deadlineController.clear();
    _formKey.currentState?.reset();
    setState(() {
      status = 'pending';
      priority = null;
      imagePath = null;
      videoPath = null;
      audioPath = null;
      _editingTask = null;
      _hasAudioDraft = false;
      _isRecording = false;
      _recordDuration = Duration.zero;
      _autoValidateMode = AutovalidateMode.disabled;
      _labels = [];
      _checklist = [];
      _attachments = [];
      _scheduledNotifDate = null;
      _assignedTo = null;
    });
  }

  // ── Audio ─────────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _showSnack('Permission micro refusée', isError: true);
      return;
    }
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.wav';

    // ✅ CORRECTION : AudioEncoder.wav pour iOS et Android (pcm16bits n'existe pas)
    await _recorder.start(
      path: path,
      encoder: AudioEncoder.wav,
      samplingRate: 16000,
      numChannels: 1,
    );

    setState(() {
      _isRecording = true;
      _recordDuration = Duration.zero;
      audioPath = path;
    });
    _tickDuration();
  }

  void _tickDuration() {
    Future.delayed(const Duration(seconds: 1), () {
      if (_isRecording && mounted) {
        setState(() => _recordDuration += const Duration(seconds: 1));
        _tickDuration();
      }
    });
  }

  Future<void> _stopRecording() async {
    await _recorder.stop();
    setState(() {
      _isRecording = false;
      _hasAudioDraft = true;
    });
  }

  Future<void> _cancelRecording() async {
    await _recorder.stop();
    if (audioPath != null) {
      final f = File(audioPath!);
      if (await f.exists()) await f.delete();
    }
    setState(() {
      _isRecording = false;
      _hasAudioDraft = false;
      audioPath = null;
      _recordDuration = Duration.zero;
    });
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  // ── Médias ────────────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    FocusScope.of(context).unfocus();
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: _primary),
        ),
        child: child!,
      ),
    );
    if (date != null) {
      setState(() {
        deadlineController.text = date.toIso8601String().split('T').first;
      });
    }
  }

  void _showTranscribingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Expanded(
              child: Text(
                  'Transcription en cours…\nCela peut prendre quelques secondes.'),
            ),
          ],
        ),
      ),
    );
  }

  void _showProfileSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Poignée
              Container(
                width: 40, height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Avatar + nom + email
              CircleAvatar(
                radius: 32,
                backgroundColor: _primary,
                child: Text(
                  AuthService.instance.userName.isNotEmpty
                      ? AuthService.instance.userName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                AuthService.instance.userName,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                AuthService.instance.userEmail,
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
              ),
              const SizedBox(height: 24),
              const Divider(),
              // Bouton déconnexion
              ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEF4444).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.logout,
                      color: Color(0xFFEF4444), size: 22),
                ),
                title: const Text(
                  'Se déconnecter',
                  style: TextStyle(
                      color: Color(0xFFEF4444), fontWeight: FontWeight.w600),
                ),
                onTap: () {
                  Navigator.pop(context); // ferme le sheet
                  _confirmLogout();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Se déconnecter ?'),
        content: const Text(
            'Vous serez redirigé vers la page de connexion.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444)),
            onPressed: () async {
              Navigator.pop(context);
              await AuthService.instance.signOut();
              // _AuthGate dans main.dart redirige automatiquement
            },
            child: const Text('Déconnecter'),
          ),
        ],
      ),
    );
  }

  void _showServerConfigDialog() {
    _serverController.text = _serverUrl;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Serveur Whisper'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Entre l\'adresse IP de ton PC sur le même WiFi.\n'
              'Ex : http://192.168.1.42:8000',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _serverController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'URL du serveur',
                hintText: 'http://192.168.x.x:8000',
                prefixIcon: Icon(Icons.computer),
                border: OutlineInputBorder(),
              ),
            ),
            if (_hasServer) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _saveServerUrl('');
                  _showSnack('Serveur supprimé');
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text('Supprimer', style: TextStyle(color: Colors.red)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () async {
              final url = _serverController.text.trim();
              Navigator.pop(ctx);
              await _saveServerUrl(url);
              if (url.isNotEmpty) {
                _showSnack('Serveur configuré : $url');
              }
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _showModelDownloadDialog() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Téléchargement requis'),
        content: const Text(
          'La transcription audio nécessite de télécharger le modèle Whisper (~466 Mo) '
          'depuis internet.\n\n'
          'Connectez-vous à internet et réessayez. '
          'Le téléchargement n\'est effectué qu\'une seule fois.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? _red : _primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ── Couleurs helpers ──────────────────────────────────────────────────────

  Color _priorityColor(String? p) {
    switch (p) {
      case 'high':   return _red;
      case 'medium': return _amber;
      case 'low':    return _green;
      default:       return _grey;
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'in_progress': return _blue;
      case 'completed':   return _green;
      case 'archived':    return _grey;
      default:            return _amber; // pending
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'in_progress':
        return 'En cours';
      case 'completed':
        return 'Terminée';
      case 'archived':
        return 'Archivée';
      default:
        return 'À faire';
    }
  }

  String? _validateTitle(String? value) {
    final text = (value ?? '').trim();
    final hasAudio = audioPath != null;
    if (text.isEmpty && !hasAudio) return 'Titre requis si aucun audio';
    if (text.length > 80) return 'Maximum 80 caractères';
    return null;
  }

  String? _validateDescription(String? value) {
    final text = (value ?? '').trim();
    if (text.length > 500) return 'Maximum 500 caractères';
    return null;
  }

  String? _validateDeadline(String? value) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return null;
    final parsed = DateTime.tryParse(text);
    if (parsed == null) return 'Date invalide';
    if (parsed.year < 2000 || parsed.year > 2100) {
      return 'Date hors plage (2000-2100)';
    }
    return null;
  }

  // Filtre pour la vue liste (respecte _statusFilter)
  List<Task> _filteredTasks() {
    final query = _searchController.text.trim().toLowerCase();
    return tasks.where((t) {
      final byStatus = _statusFilter == 'all' || t.status == _statusFilter;
      final byText = query.isEmpty ||
          t.title.toLowerCase().contains(query) ||
          (t.description ?? '').toLowerCase().contains(query);
      bool byDate = true;
      if (_filterDateStart != null || _filterDateEnd != null) {
        final deadline = t.deadline != null ? DateTime.tryParse(t.deadline!) : null;
        if (deadline == null) {
          byDate = false;
        } else {
          if (_filterDateStart != null && deadline.isBefore(_filterDateStart!)) byDate = false;
          if (_filterDateEnd != null && deadline.isAfter(_filterDateEnd!.add(const Duration(days: 1)))) byDate = false;
        }
      }
      return byStatus && byText && byDate;
    }).toList();
  }

  Future<void> _pickDateFilter() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _filterDateStart != null && _filterDateEnd != null
          ? DateTimeRange(start: _filterDateStart!, end: _filterDateEnd!)
          : null,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: _primary),
        ),
        child: child!,
      ),
    );
    if (range != null) {
      setState(() {
        _filterDateStart = range.start;
        _filterDateEnd = range.end;
      });
    }
  }

  // Filtre pour le Kanban : ignore _statusFilter (les colonnes = les statuts)
  List<Task> _boardFilteredTasks() {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return List.from(tasks);
    return tasks.where((t) =>
      t.title.toLowerCase().contains(query) ||
      (t.description ?? '').toLowerCase().contains(query),
    ).toList();
  }

  // ── Labels & Checklist helpers ────────────────────────────────────────────

  static List<Map<String, dynamic>> _parseAttachments(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(json));
    } catch (_) { return []; }
  }

  Future<void> _pickAttachment() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    setState(() {
      for (final f in result.files) {
        if (f.path != null) {
          _attachments.add({'n': f.name, 'p': f.path!});
        }
      }
    });
    _showSnack('${result.files.length} fichier(s) ajouté(s)');
  }

  Future<void> _showScheduleNotifDialog() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _scheduledNotifDate ?? now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: _primary),
        ),
        child: child!,
      ),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_scheduledNotifDate ?? now),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: _primary),
        ),
        child: child!,
      ),
    );
    if (time == null) return;
    setState(() {
      _scheduledNotifDate = DateTime(
          date.year, date.month, date.day, time.hour, time.minute);
    });
    _showSnack(
        'Notification programmée le ${date.day}/${date.month}/${date.year} à ${time.format(context)}');
  }

  static List<Map<String, dynamic>> _parseLabels(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(json));
    } catch (_) { return []; }
  }

  static List<Map<String, dynamic>> _parseChecklist(String? json) {
    if (json == null || json.isEmpty) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(json));
    } catch (_) { return []; }
  }

  void _openDetail(Task task) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TaskDetailPage(
          task: task,
          onTaskUpdated: loadTasks,
        ),
      ),
    );
  }

  Future<void> _copyTask(Task source) async {
    final copy = Task()
      ..title = '${source.title} (copie)'
      ..description = source.description
      ..status = 'pending'
      ..priority = source.priority
      ..deadline = source.deadline
      ..labelsJson = source.labelsJson
      ..checklistJson = source.checklistJson;
    await _persistNewTask(copy);
    await loadTasks();
    _showSnack('Tâche copiée');
  }

  void _showLabelPicker() {
    final textCtrl = TextEditingController();
    int selectedColor = 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.fromLTRB(
              20, 16, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Text('Nouvelle étiquette',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: textCtrl,
                decoration: InputDecoration(
                  hintText: 'Nom de l\'étiquette...',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Couleur',
                  style: TextStyle(fontSize: 13, color: Colors.grey)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(_labelPalette.length, (i) {
                  return GestureDetector(
                    onTap: () => setModal(() => selectedColor = i),
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: _labelPalette[i],
                        shape: BoxShape.circle,
                        border: selectedColor == i
                            ? Border.all(color: Colors.black87, width: 3)
                            : null,
                      ),
                      child: selectedColor == i
                          ? const Icon(Icons.check,
                              color: Colors.white, size: 18)
                          : null,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    final text = textCtrl.text.trim();
                    if (text.isEmpty) return;
                    setState(() => _labels.add(
                        {'t': text, 'c': selectedColor}));
                    Navigator.pop(ctx);
                  },
                  child: const Text('Ajouter'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _addChecklistItem() {
    final textCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nouvel élément'),
        content: TextField(
          controller: textCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Décrivez l\'étape...'),
          onSubmitted: (_) {
            final text = textCtrl.text.trim();
            if (text.isNotEmpty) {
              setState(() => _checklist.add({'t': text, 'd': false}));
            }
            Navigator.pop(ctx);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final text = textCtrl.text.trim();
              if (text.isNotEmpty) {
                setState(() => _checklist.add({'t': text, 'd': false}));
              }
              Navigator.pop(ctx);
            },
            child: const Text('Ajouter'),
          ),
        ],
      ),
    );
  }

  Future<void> _moveTaskToStatus(Task task, String newStatus) async {
    if (task.status == newStatus) return;

    final oldStatus = task.status;
    // Mise à jour optimiste : l'UI bouge immédiatement sans attendre Isar
    setState(() => task.status = newStatus);

    try {
      await _persistUpdate(task);
      await NotificationService.instance
          .notifyTaskUpdated(task.title, newStatus);
      await loadTasks(); // sync final avec la DB
    } catch (e) {
      // Rollback visuel si la DB échoue
      setState(() => task.status = oldStatus);
      _showSnack('Erreur lors du déplacement : $e', isError: true);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // BUILD
  // ─────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isFormPage = _currentPage == 1;
    return Scaffold(
      backgroundColor: _surface,
      appBar: _buildAppBar(isFormPage: isFormPage),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.04, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: KeyedSubtree(
          key: ValueKey<int>(_currentPage),
          child: _buildCurrentPage(),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentPage,
        onDestinationSelected: (i) {
          if (i == 1 && _currentPage != 1) _resetForm();
          setState(() => _currentPage = i);
        },
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.checklist_rounded), label: 'Liste'),
          NavigationDestination(
              icon: Icon(Icons.post_add_rounded), label: 'Ajouter'),
          NavigationDestination(
              icon: Icon(Icons.view_kanban_outlined), label: 'Board'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined), label: 'Paramètres'),
        ],
      ),
    );
  }

  Widget _buildCurrentPage() {
    if (_currentPage == 1) {
      return SafeArea(
          child: SingleChildScrollView(child: _buildForm()));
    }
    if (_currentPage == 2) return _buildKanbanBoard();
    if (_currentPage == 3) return const SettingsPage();
    return Column(children: [
      _buildSearchBar(),
      _buildListFilters(),
      _buildList(),
    ]);
  }

  // ── AppBar ────────────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar({required bool isFormPage}) {
    return AppBar(
      systemOverlayStyle: SystemUiOverlayStyle.light,
      backgroundColor: _primary,
      foregroundColor: Colors.white,
      elevation: 0,
      title: Text(
        isFormPage
            ? (_editingTask == null ? 'Ajouter une tâche' : 'Modifier la tâche')
            : 'Mes tâches',
        style:
            const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
      ),
      actions: [
        // Indicateur Strapi + reconnexion
        IconButton(
          tooltip: _useStrapi ? 'Strapi connecté' : 'Strapi hors ligne – appuyer pour reconnecter',
          icon: Icon(
            _useStrapi ? Icons.cloud_done : Icons.cloud_off,
            color: _useStrapi ? const Color(0xFF86EFAC) : Colors.white38,
          ),
          onPressed: () async {
            await _detectStrapi();
            if (_useStrapi) await loadTasks();
          },
        ),
        // Bouton config serveur Whisper
        IconButton(
          tooltip: _hasServer ? 'Serveur : $_serverUrl' : 'Configurer le serveur Whisper',
          icon: Icon(
            Icons.settings_voice,
            color: _hasServer ? const Color(0xFF86EFAC) : Colors.white54,
          ),
          onPressed: _showServerConfigDialog,
        ),
        // Compteur de tâches
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${tasks.length} tâche${tasks.length > 1 ? 's' : ''}',
              style: const TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          ),
        ),
        const SizedBox(width: 6),
        // Avatar cliquable → profil + déconnexion (à droite du compteur)
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: InkWell(
            onTap: _showProfileSheet,
            borderRadius: BorderRadius.circular(20),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: Colors.white,
              child: Text(
                AuthService.instance.userName.isNotEmpty
                    ? AuthService.instance.userName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    color: _primary, fontWeight: FontWeight.w800, fontSize: 14),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildListFilters() {
    final hasDateFilter = _filterDateStart != null || _filterDateEnd != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _filterChip('Tout', 'all'),
          const SizedBox(width: 8),
          _filterChip('À faire', 'pending'),
          const SizedBox(width: 8),
          _filterChip('En cours', 'in_progress'),
          const SizedBox(width: 8),
          _filterChip('Terminées', 'completed'),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _pickDateFilter,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: hasDateFilter
                    ? _primary.withValues(alpha: 0.15)
                    : Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: hasDateFilter ? _primary : Colors.grey[300]!,
                  width: hasDateFilter ? 1.5 : 1,
                ),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.date_range_rounded,
                    size: 15,
                    color: hasDateFilter ? _primary : Colors.grey[600]),
                const SizedBox(width: 5),
                Text(
                  hasDateFilter
                      ? '${_filterDateStart!.day}/${_filterDateStart!.month} – ${_filterDateEnd!.day}/${_filterDateEnd!.month}'
                      : 'Date',
                  style: TextStyle(
                    fontSize: 13,
                    color: hasDateFilter ? _primary : Colors.grey[700],
                    fontWeight: hasDateFilter
                        ? FontWeight.w600
                        : FontWeight.w400,
                  ),
                ),
                if (hasDateFilter) ...[
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () => setState(() {
                      _filterDateStart = null;
                      _filterDateEnd = null;
                    }),
                    child: const Icon(Icons.close, size: 14, color: _primary),
                  ),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: TextField(
        controller: _searchController,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          hintText: 'Rechercher une tâche...',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close),
                ),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final selected = _statusFilter == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _statusFilter = value),
      selectedColor: _primary.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: selected ? _primary : Colors.grey[700],
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }

  // ── Formulaire ────────────────────────────────────────────────────────────

  Widget _buildForm() {
    return Container(
      decoration: const BoxDecoration(
        color: _primary,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(32),
          bottomRight: Radius.circular(32),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 20),
      child: Card(
        elevation: 8,
        shadowColor: _primary.withValues(alpha: 0.3),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        color: _cardBg,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            autovalidateMode: _autoValidateMode,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _input(titleController, 'Titre de la tâche',
                    Icons.edit_note_rounded,
                    validator: _validateTitle, maxLength: 80),
                const SizedBox(height: 10),
                _input(descriptionController, 'Description (optionnelle)',
                    Icons.notes_rounded,
                    maxLines: 2,
                    validator: _validateDescription,
                    maxLength: 500),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                      child: _dropdown(
                    value: status,
                    label: 'Statut',
                    icon: Icons.flag_outlined,
                    items: const {
                      'pending': 'À faire',
                      'in_progress': 'En cours',
                      'completed': 'Terminée',
                      'archived': 'Archivée',
                    },
                    onChanged: (v) =>
                        setState(() => status = v ?? 'pending'),
                    isDense: true,
                  )),
                  const SizedBox(width: 8),
                  Expanded(
                      child: _dropdown(
                    value: priority,
                    label: 'Priorité',
                    icon: Icons.bar_chart_rounded,
                    items: const {
                      'low': 'Basse',
                      'medium': 'Moyenne',
                      'high': 'Haute',
                    },
                    onChanged: (v) => setState(() => priority = v),
                    isDense: true,
                  )),
                ]),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _pickDate,
                  child: AbsorbPointer(
                    child: TextFormField(
                      controller: deadlineController,
                      readOnly: true,
                      validator: _validateDeadline,
                      decoration: _inputDec(
                        deadlineController.text.isEmpty
                            ? 'Échéance (optionnelle)'
                            : deadlineController.text,
                        Icons.event_rounded,
                      ).copyWith(
                        suffixIcon: deadlineController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 16),
                                onPressed: () => setState(
                                    () => deadlineController.clear()),
                              )
                            : const Icon(Icons.calendar_today_rounded,
                                size: 18),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // ── Étiquettes ──────────────────────────────────────────────
                _buildLabelSection(),
                const SizedBox(height: 10),
                // ── Checklist ───────────────────────────────────────────────
                _buildChecklistSection(),
                const SizedBox(height: 10),
                // ── Pièces jointes ──────────────────────────────────────────
                _buildAttachmentsSection(),
                const SizedBox(height: 10),
                // ── Assignation ─────────────────────────────────────────────
                if (_useStrapi) _buildAssignSection(),
                if (_useStrapi) const SizedBox(height: 10),
                // ── Notification programmée ─────────────────────────────────
                _buildScheduleNotifSection(),
                const SizedBox(height: 10),
                Row(children: [
                  _mediaBtn(
                      icon: Icons.image_outlined,
                      label: 'Image',
                      active: imagePath != null,
                      color: _primary,
                      onTap: _pickImage),
                  const SizedBox(width: 8),
                  _mediaBtn(
                      icon: Icons.videocam_outlined,
                      label: 'Vidéo',
                      active: videoPath != null,
                      color: _blue,
                      onTap: _pickVideo),
                ]),
                if (imagePath != null) ...[
                  const SizedBox(height: 10),
                  _imagePreview(imagePath!,
                      onRemove: () => setState(() => imagePath = null)),
                ],
                if (videoPath != null) ...[
                  const SizedBox(height: 10),
                  _mediaChip(Icons.videocam, 'Vidéo sélectionnée', _blue,
                      onRemove: () => setState(() => videoPath = null)),
                ],
                if (_hasAudioDraft && audioPath != null) ...[
                  const SizedBox(height: 10),
                  _AudioPlaybackChip(
                    path: audioPath!,
                    onRemove: () => setState(() {
                      audioPath = null;
                      _hasAudioDraft = false;
                    }),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _isTranscribingAudio
                        ? null
                        : _transcribeDraftAudio,
                    icon: _isTranscribingAudio
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.subtitles_outlined),
                    label: Text(_isTranscribingAudio
                        ? 'Transcription en cours...'
                        : 'Transcrire l\'audio'),
                  ),
                  if (_extractTranscript(descriptionController.text) !=
                      null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: _blue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: _blue.withValues(alpha: 0.25)),
                      ),
                      child: Text(
                        _extractTranscript(descriptionController.text)!,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 14),
                _buildBottomBar(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLabelSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.label_outline, color: _primary, size: 18),
          const SizedBox(width: 6),
          Text('Étiquettes',
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          const Spacer(),
          TextButton.icon(
            onPressed: _showLabelPicker,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Ajouter', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: _primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ]),
        if (_labels.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: _labels.asMap().entries.map((e) {
              final color = _labelPalette[e.value['c'] as int];
              return Chip(
                label: Text(e.value['t'] as String,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 11)),
                backgroundColor: color,
                deleteIcon:
                    const Icon(Icons.close, size: 14, color: Colors.white),
                onDeleted: () =>
                    setState(() => _labels.removeAt(e.key)),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),
        ],
      ],
    );
  }

  Widget _buildChecklistSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.checklist_rounded, color: _primary, size: 18),
          const SizedBox(width: 6),
          Text('Checklist',
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          if (_checklist.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '${_checklist.where((i) => i['d'] == true).length}/${_checklist.length}',
                style: const TextStyle(
                    color: _primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ),
          const Spacer(),
          TextButton.icon(
            onPressed: _addChecklistItem,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Ajouter', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: _primary,
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ]),
        if (_checklist.isNotEmpty) ...[
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              children: _checklist.asMap().entries.map((e) {
                final idx = e.key;
                final item = e.value;
                final done = item['d'] as bool;
                return Row(children: [
                  Checkbox(
                    value: done,
                    onChanged: (v) =>
                        setState(() => _checklist[idx]['d'] = v ?? false),
                    activeColor: _primary,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                  ),
                  Expanded(
                    child: Text(
                      item['t'] as String,
                      style: TextStyle(
                        fontSize: 13,
                        decoration:
                            done ? TextDecoration.lineThrough : null,
                        color: done ? Colors.grey[400] : Colors.black87,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        size: 16, color: Colors.grey[400]),
                    onPressed: () =>
                        setState(() => _checklist.removeAt(idx)),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  const SizedBox(width: 8),
                ]);
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAttachmentsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.attach_file_rounded, color: _primary, size: 18),
          const SizedBox(width: 6),
          Text('Pièces jointes',
              style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          const Spacer(),
          TextButton.icon(
            onPressed: _pickAttachment,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Ajouter', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: _primary,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ]),
        if (_attachments.isNotEmpty) ...[
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFAFAFF),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              children: _attachments.asMap().entries.map((e) {
                final idx = e.key;
                final name = e.value['n'] as String;
                final ext = name.contains('.')
                    ? name.split('.').last.toLowerCase()
                    : '';
                final icon = ['pdf'].contains(ext)
                    ? Icons.picture_as_pdf_rounded
                    : ['jpg', 'jpeg', 'png', 'gif'].contains(ext)
                        ? Icons.image_outlined
                        : ['mp4', 'mov', 'avi'].contains(ext)
                            ? Icons.videocam_outlined
                            : Icons.insert_drive_file_outlined;
                return ListTile(
                  dense: true,
                  leading: Icon(icon, color: _primary, size: 20),
                  title: Text(name,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: Icon(Icons.close, size: 16, color: Colors.grey[400]),
                    onPressed: () => setState(() => _attachments.removeAt(idx)),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildAssignSection() {
    final me = AuthService.instance.userEmail;
    // Combine utilisateurs connus + l'utilisateur courant sans doublons
    final options = {me, ..._knownUsers}.where((e) => e.isNotEmpty).toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(children: [
        const Icon(Icons.person_pin_outlined, color: _primary, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _assignedTo,
              isExpanded: true,
              hint: const Text('Assigner à...', style: TextStyle(fontSize: 13, color: Colors.grey)),
              items: [
                const DropdownMenuItem(value: null, child: Text('— Aucune assignation —')),
                ...options.map((email) => DropdownMenuItem(
                      value: email,
                      child: Row(children: [
                        CircleAvatar(
                          radius: 10,
                          backgroundColor: _primary,
                          child: Text(email[0].toUpperCase(),
                              style: const TextStyle(fontSize: 10, color: Colors.white)),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(email,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: email == me ? FontWeight.w700 : FontWeight.normal)),
                        ),
                      ]),
                    )),
              ],
              onChanged: (val) => setState(() => _assignedTo = val),
            ),
          ),
        ),
        if (_assignedTo != null)
          GestureDetector(
            onTap: () => setState(() => _assignedTo = null),
            child: const Icon(Icons.close, size: 16, color: _primary),
          ),
      ]),
    );
  }

  Widget _buildScheduleNotifSection() {
    final hasDate = _scheduledNotifDate != null;
    return GestureDetector(
      onTap: _showScheduleNotifDialog,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: hasDate ? _primary.withValues(alpha: 0.06) : const Color(0xFFFAFAFF),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hasDate ? _primary.withValues(alpha: 0.4) : Colors.grey[300]!,
            width: hasDate ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(Icons.notifications_outlined,
              size: 20, color: hasDate ? _primary : Colors.grey[500]),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              hasDate
                  ? 'Notification : ${_scheduledNotifDate!.day.toString().padLeft(2, '0')}/'
                    '${_scheduledNotifDate!.month.toString().padLeft(2, '0')}/'
                    '${_scheduledNotifDate!.year} à '
                    '${_scheduledNotifDate!.hour.toString().padLeft(2, '0')}h'
                    '${_scheduledNotifDate!.minute.toString().padLeft(2, '0')}'
                  : 'Programmer une notification',
              style: TextStyle(
                fontSize: 13,
                color: hasDate ? _primary : Colors.grey[500],
                fontWeight: hasDate ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          if (hasDate)
            GestureDetector(
              onTap: () => setState(() => _scheduledNotifDate = null),
              child: const Icon(Icons.close, size: 16, color: _primary),
            ),
        ]),
      ),
    );
  }

  Widget _buildBottomBar() {
    if (_isRecording) return _buildRecordingBar();
    return Row(children: [
      GestureDetector(
        onLongPressStart: (_) => _startRecording(),
        onLongPressEnd: (_) => _stopRecording(),
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (_, __) => Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _green.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(color: _green, width: 1.5),
            ),
            child: const Icon(Icons.mic_rounded, color: _green, size: 26),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text('Maintenir pour enregistrer',
            style: TextStyle(fontSize: 12, color: Colors.grey[500])),
      ),
      // Bouton Annuler (visible seulement en mode modification)
      if (_editingTask != null) ...[
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: () {
            _resetForm();
            setState(() {
              _editingTask = null;
              _currentPage = 0;
            });
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: _grey,
            side: const BorderSide(color: _grey),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
          child: const Text('Annuler', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(width: 8),
      ],
      ElevatedButton(
        onPressed: _submitTask,
        style: ElevatedButton.styleFrom(
          backgroundColor: _primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          padding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          elevation: 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _editingTask == null
                  ? Icons.add_circle_outline
                  : Icons.edit_note_rounded,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              _editingTask == null ? 'Ajouter' : 'Mettre à jour',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _buildRecordingBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _green.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: _cancelRecording,
          child: Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _red.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child:
                const Icon(Icons.delete_outline, color: _red, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Row(children: [
            AnimatedBuilder(
              animation: _pulseController,
              builder: (_, __) => Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _red.withValues(
                      alpha: 0.5 + 0.5 * _pulseController.value),
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _formatDuration(_recordDuration),
              style: const TextStyle(
                  color: _red,
                  fontWeight: FontWeight.w600,
                  fontSize: 14),
            ),
            const SizedBox(width: 8),
            Expanded(
                child:
                    _WaveformAnimation(controller: _pulseController)),
          ]),
        ),
        const SizedBox(width: 10),
        GestureDetector(
          onTap: _stopRecording,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
                color: _green, shape: BoxShape.circle),
            child: const Icon(Icons.send_rounded,
                color: Colors.white, size: 20),
          ),
        ),
      ]),
    );
  }

  Future<void> _pickImage() async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.photo_library_outlined,
                    color: _primary),
              ),
              title: const Text('Galerie'),
              onTap: () async {
                final f = await _picker.pickImage(
                    source: ImageSource.gallery);
                Navigator.pop(context);
                if (f != null) setState(() => imagePath = f.path);
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _blue.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.camera_alt_outlined,
                    color: _blue),
              ),
              title: const Text('Appareil photo'),
              onTap: () async {
                final f = await _picker.pickImage(
                    source: ImageSource.camera);
                Navigator.pop(context);
                if (f != null) setState(() => imagePath = f.path);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Future<void> _pickVideo() async {
    final f = await _picker.pickVideo(source: ImageSource.gallery);
    if (f != null) setState(() => videoPath = f.path);
  }

  // ── Liste ─────────────────────────────────────────────────────────────────

  Widget _buildList() {
    final filteredTasks = _filteredTasks();
    return Expanded(
      child: filteredTasks.isEmpty
          ? _emptyState()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 90),
              itemCount: filteredTasks.length,
              itemBuilder: (_, i) => _TaskCard(
                task: filteredTasks[i],
                onTap: () => _openDetail(filteredTasks[i]),
                onEdit: () => _startEditing(filteredTasks[i]),
                onDelete: () => deleteTask(filteredTasks[i].id),
                onCopy: () => _copyTask(filteredTasks[i]),
                onTranscribeAudio: filteredTasks[i].audioPath != null &&
                        filteredTasks[i].audioPath!.isNotEmpty
                    ? () => _transcribeTaskAudio(filteredTasks[i])
                    : null,
                transcribing:
                    _transcribingTaskId == filteredTasks[i].id,
                priorityColor:
                    _priorityColor(filteredTasks[i].priority),
                statusColor: _statusColor(filteredTasks[i].status),
                statusLabel: _statusLabel(filteredTasks[i].status),
              ),
            ),
    );
  }

  Widget _buildKanbanBoard() {
    // _boardFilteredTasks ignore le filtre de statut — les colonnes sont déjà les statuts
    final source     = _boardFilteredTasks();
    final pending    = source.where((t) => t.status == 'pending').toList();
    final inProgress = source.where((t) => t.status == 'in_progress').toList();
    final completed  = source.where((t) => t.status == 'completed').toList();

    return Container(
      decoration: _boardBgPath != null
          ? BoxDecoration(
              image: DecorationImage(
                image: FileImage(File(_boardBgPath!)),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                  Colors.black.withValues(alpha: 0.25),
                  BlendMode.darken,
                ),
              ),
            )
          : const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFEEF2FF), Color(0xFFF8FAFF)],
              ),
            ),
      child: Column(children: [
        _buildSearchBar(),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildBoardColumn(
                    title: 'À faire',
                    statusKey: 'pending',
                    color: _amber,
                    columnTasks: pending),
                const SizedBox(width: 12),
                _buildBoardColumn(
                    title: 'En cours',
                    statusKey: 'in_progress',
                    color: _blue,
                    columnTasks: inProgress),
                const SizedBox(width: 12),
                _buildBoardColumn(
                    title: 'Terminées',
                    statusKey: 'completed',
                    color: _green,
                    columnTasks: completed),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _buildBoardColumn({
    required String title,
    required String statusKey,
    required Color color,
    required List<Task> columnTasks,
  }) {
    final screenH = MediaQuery.of(context).size.height - 200;
    return SizedBox(
      width: 280,
      height: screenH,
      child: Container(
        clipBehavior: Clip.none,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$title (${columnTasks.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.w700, color: color),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: DragTarget<Task>(
                onWillAcceptWithDetails: (_) => true,
                onAcceptWithDetails: (details) =>
                    _moveTaskToStatus(details.data, statusKey),
                builder: (context, candidateData, __) {
                  final isHovered = candidateData.isNotEmpty;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: isHovered
                          ? color.withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      border: isHovered
                          ? Border.all(color: color, width: 2)
                          : null,
                    ),
                    child: columnTasks.isEmpty
                        ? Center(
                            child: Text(
                              isHovered
                                  ? 'Déposer ici ↓'
                                  : 'Glissez une tâche ici',
                              style: TextStyle(
                                color: isHovered ? color : Colors.grey,
                                fontWeight: isHovered
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            padding: const EdgeInsets.all(4),
                            child: Column(
                              children: [
                                for (final task in columnTasks) ...[
                                  LongPressDraggable<Task>(
                                    data: task,
                                    hapticFeedbackOnStart: true,
                                    feedback: Material(
                                      color: Colors.transparent,
                                      child: ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(
                                                maxWidth: 260),
                                        child:
                                            _BoardTaskTile(task: task),
                                      ),
                                    ),
                                    childWhenDragging: Opacity(
                                      opacity: 0.3,
                                      child: _BoardTaskTile(task: task),
                                    ),
                                    child: InkWell(
                                      borderRadius:
                                          BorderRadius.circular(12),
                                      onTap: () => _openDetail(task),
                                      child: _BoardTaskTile(task: task),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                ],
                              ],
                            ),
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.checklist_rounded,
                size: 56, color: _primary.withValues(alpha: 0.3)),
          ),
          const SizedBox(height: 16),
          Text('Aucune tâche',
              style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text('Ajoutez votre première tâche ci-dessus',
              style:
                  TextStyle(color: Colors.grey[400], fontSize: 13)),
        ],
      ),
    );
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  InputDecoration _inputDec(String label, IconData icon) =>
      InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20, color: _primary),
        border:
            OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _primary, width: 1.5),
        ),
        filled: true,
        fillColor: const Color(0xFFFAFAFF),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        labelStyle: TextStyle(color: Colors.grey[500], fontSize: 14),
      );

  Widget _input(TextEditingController c, String label, IconData icon,
          {int maxLines = 1,
          String? Function(String?)? validator,
          int? maxLength}) =>
      TextFormField(
        controller: c,
        maxLines: maxLines,
        validator: validator,
        maxLength: maxLength,
        decoration: _inputDec(label, icon),
      );

  Widget _dropdown({
    required String? value,
    required String label,
    required IconData icon,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
    bool isDense = false,
  }) =>
      DropdownButtonFormField<String>(
        value: value,
        isExpanded: true,
        isDense: isDense,
        decoration: _inputDec(label, icon),
        // menuMaxHeight limite la hauteur du menu déroulant
        menuMaxHeight: 240,
        // selectedItemBuilder : affichage fixe de la valeur sélectionnée (pas de redimensionnement)
        selectedItemBuilder: (context) => items.entries
            .map((e) => Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    e.value,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: const TextStyle(fontSize: 14),
                  ),
                ))
            .toList(),
        items: items.entries
            .map((e) => DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis, maxLines: 1)))
            .toList(),
        onChanged: onChanged,
      );

  Widget _mediaBtn({
    required IconData icon,
    required String label,
    required bool active,
    required Color color,
    required VoidCallback onTap,
  }) =>
      Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active
                  ? color.withValues(alpha: 0.1)
                  : Colors.grey[50],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? color : Colors.grey[300]!,
                width: active ? 1.5 : 0.8,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    color: active ? color : Colors.grey[500], size: 22),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        color: active ? color : Colors.grey[500],
                        fontWeight: active
                            ? FontWeight.w600
                            : FontWeight.normal)),
              ],
            ),
          ),
        ),
      );

  Widget _imagePreview(String path,
          {required VoidCallback onRemove}) =>
      Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(File(path),
              height: 110,
              width: double.infinity,
              fit: BoxFit.cover),
        ),
        Positioned(
          top: 6,
          right: 6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20)),
              child: const Icon(Icons.close,
                  color: Colors.white, size: 16),
            ),
          ),
        ),
      ]);

  Widget _mediaChip(IconData icon, String label, Color color,
          {VoidCallback? onRemove}) =>
      Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child:
                  Text(label, style: TextStyle(color: color, fontSize: 13))),
          if (onRemove != null)
            GestureDetector(
              onTap: onRemove,
              child: Icon(Icons.close, color: color, size: 16),
            ),
        ]),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Waveform animée
// ─────────────────────────────────────────────────────────────────────────────
class _WaveformAnimation extends StatelessWidget {
  final AnimationController controller;
  const _WaveformAnimation({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, __) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: List.generate(12, (i) {
            final h = 6.0 +
                14.0 *
                    ((i % 3 == 0)
                        ? controller.value
                        : (i % 3 == 1)
                            ? (1 - controller.value)
                            : 0.5);
            return Container(
              width: 3,
              height: h,
              decoration: BoxDecoration(
                color: _green.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Chip lecture audio (formulaire)
// ─────────────────────────────────────────────────────────────────────────────
class _AudioPlaybackChip extends StatefulWidget {
  final String path;
  final VoidCallback onRemove;
  const _AudioPlaybackChip({required this.path, required this.onRemove});

  @override
  State<_AudioPlaybackChip> createState() => _AudioPlaybackChipState();
}

class _AudioPlaybackChipState extends State<_AudioPlaybackChip> {
  final _player = AudioPlayer();
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() => _playing = false);
        _player.seek(Duration.zero);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      setState(() => _playing = false);
    } else {
      try {
        if (widget.path.startsWith('http')) {
          await _player.setUrl(widget.path);
        } else {
          await _player.setFilePath(widget.path);
        }
        await _player.play();
        setState(() => _playing = true);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _green.withValues(alpha: 0.3)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
                color: _green, shape: BoxShape.circle),
            child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Audio enregistré',
              style: TextStyle(
                  color: _green, fontWeight: FontWeight.w500)),
        ),
        GestureDetector(
          onTap: widget.onRemove,
          child: const Icon(Icons.close, color: _green, size: 18),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Carte de tâche
// ─────────────────────────────────────────────────────────────────────────────
class _TaskCard extends StatelessWidget {
  final Task task;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCopy;
  final VoidCallback? onTranscribeAudio;
  final bool transcribing;
  final Color priorityColor;
  final Color statusColor;
  final String statusLabel;

  const _TaskCard({
    required this.task,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onCopy,
    required this.onTranscribeAudio,
    this.transcribing = false,
    required this.priorityColor,
    required this.statusColor,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border(left: BorderSide(color: priorityColor, width: 4)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(task.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              _StatusBadge(label: statusLabel, color: statusColor),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onCopy,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.copy_outlined,
                      color: _primary, size: 16),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _blue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.edit_outlined,
                      color: _blue, size: 16),
                ),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onDelete,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.delete_outline,
                      color: _red, size: 16),
                ),
              ),
            ]),
            // ── Labels ──────────────────────────────────────────────────────
            Builder(builder: (_) {
              final labels = _TaskListPageState._parseLabels(task.labelsJson);
              if (labels.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 5,
                  runSpacing: 4,
                  children: labels.map((l) {
                    final color = _labelPalette[l['c'] as int];
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(l['t'] as String,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w600)),
                    );
                  }).toList(),
                ),
              );
            }),
            if (task.description != null &&
                task.description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(task.description!,
                  style:
                      TextStyle(color: Colors.grey[600], fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
            if (task.imagePath != null &&
                task.imagePath!.isNotEmpty) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: task.imagePath!.startsWith('http')
                    ? Image.network(task.imagePath!,
                        height: 100,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image, size: 40))
                    : Image.file(File(task.imagePath!),
                        height: 100,
                        width: double.infinity,
                        fit: BoxFit.cover),
              ),
            ],
            if (task.videoPath != null &&
                task.videoPath!.isNotEmpty) ...[
              const SizedBox(height: 10),
              _VideoPreviewWidget(videoPath: task.videoPath!),
            ],
            if (task.audioPath != null &&
                task.audioPath!.isNotEmpty) ...[
              const SizedBox(height: 10),
              _AudioBubble(path: task.audioPath!),
              if (onTranscribeAudio != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed:
                        transcribing ? null : onTranscribeAudio,
                    icon: transcribing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          )
                        : const Icon(Icons.subtitles_outlined,
                            size: 18),
                    label: Text(transcribing
                        ? 'Transcription...'
                        : 'Transcrire cet audio'),
                  ),
                ),
              ],
              if (task.description != null &&
                  task.description!.contains(
                      _TaskListPageState._transcriptMarker)) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _blue.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: _blue.withValues(alpha: 0.25)),
                  ),
                  child: Text(
                    task.description!
                        .split(_TaskListPageState._transcriptMarker)
                        .last
                        .trim(),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ],
            // ── Checklist en lecture ─────────────────────────────────────
            Builder(builder: (_) {
              final cl = _TaskListPageState._parseChecklist(task.checklistJson);
              if (cl.isEmpty) return const SizedBox.shrink();
              final done = cl.where((i) => i['d'] == true).length;
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.checklist_rounded,
                          size: 14, color: _primary),
                      const SizedBox(width: 4),
                      Text('$done/${cl.length}',
                          style: const TextStyle(
                              fontSize: 11,
                              color: _primary,
                              fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: cl.isEmpty ? 0 : done / cl.length,
                        backgroundColor: _primary.withValues(alpha: 0.12),
                        valueColor:
                            const AlwaysStoppedAnimation(_primary),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 10),
            // ── Tags priorité + date + indicateurs ──────────────────────────
            Row(children: [
              if (task.priority != null)
                _Tag(
                  label: task.priority == 'high'
                      ? 'Haute'
                      : task.priority == 'medium'
                          ? 'Moyenne'
                          : 'Basse',
                  color: priorityColor,
                ),
              if (task.deadline != null && task.deadline!.isNotEmpty) ...[
                const SizedBox(width: 6),
                _Tag(label: '📅 ${task.deadline!}', color: _grey),
              ],
              const Spacer(),
              // ── Icônes indicateurs ────────────────────────────────────────
              if (task.description != null && task.description!.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.notes_rounded,
                      size: 15, color: Colors.grey[400]),
                ),
              if (task.audioPath != null && task.audioPath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.mic_rounded,
                      size: 15, color: Colors.grey[400]),
                ),
              if (task.imagePath != null && task.imagePath!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.image_outlined,
                      size: 15, color: Colors.grey[400]),
                ),
              Builder(builder: (_) {
                final att = _TaskListPageState._parseAttachments(task.attachmentsJson);
                if (att.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.attach_file_rounded, size: 13, color: Colors.grey[400]),
                    Text('${att.length}',
                        style: TextStyle(fontSize: 10, color: Colors.grey[400])),
                  ]),
                );
              }),
              if (task.scheduledNotification != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(Icons.notifications_outlined,
                      size: 13, color: _primary.withValues(alpha: 0.6)),
                ),
              if (task.assignedTo != null)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: 'Assigné à ${task.assignedTo}',
                    child: CircleAvatar(
                      radius: 8,
                      backgroundColor: _primary.withValues(alpha: 0.15),
                      child: Text(
                        task.assignedTo![0].toUpperCase(),
                        style: TextStyle(fontSize: 9, color: _primary, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
            ]),
          ],
        ),
      ),
    ), // Container
    ); // GestureDetector
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bulle audio style WhatsApp
// ─────────────────────────────────────────────────────────────────────────────
class _AudioBubble extends StatefulWidget {
  final String path;
  const _AudioBubble({required this.path});

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final _player = AudioPlayer();
  bool _playing = false;
  Duration _total = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    final load = widget.path.startsWith('http')
        ? _player.setUrl(widget.path)
        : _player.setFilePath(widget.path);
    load.then((_) {
      if (mounted)
        setState(() => _total = _player.duration ?? Duration.zero);
    }).catchError((_) {});
    _player.positionStream
        .listen((p) { if (mounted) setState(() => _position = p); });
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
        _player.seek(Duration.zero);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    setState(() => _playing = !_playing);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total.inMilliseconds > 0
        ? _position.inMilliseconds / _total.inMilliseconds
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _green.withValues(alpha: 0.2)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
                color: _green, shape: BoxShape.circle),
            child: Icon(
              _playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: _green.withValues(alpha: 0.15),
                  valueColor: const AlwaysStoppedAnimation(_green),
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_fmt(_position)} / ${_fmt(_total)}',
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                    fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.mic, color: _green, size: 16),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Lecteur vidéo
// ─────────────────────────────────────────────────────────────────────────────
class _VideoPreviewWidget extends StatefulWidget {
  final String videoPath;
  const _VideoPreviewWidget({required this.videoPath});

  @override
  State<_VideoPreviewWidget> createState() => _VideoPreviewWidgetState();
}

class _VideoPreviewWidgetState extends State<_VideoPreviewWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.videoPath.startsWith('http')
        ? VideoPlayerController.networkUrl(Uri.parse(widget.videoPath))
        : VideoPlayerController.file(File(widget.videoPath));
    _controller.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return Container(
        height: 110,
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: VideoPlayer(_controller),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: GestureDetector(
              onTap: () => setState(() {
                _controller.value.isPlaying
                    ? _controller.pause()
                    : _controller.play();
              }),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: Icon(
                  _controller.value.isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Widgets utilitaires
// ─────────────────────────────────────────────────────────────────────────────
class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600)),
      );
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w500)),
      );
}

class _BoardTaskTile extends StatelessWidget {
  final Task task;
  const _BoardTaskTile({required this.task});

  Color _priorityColor(String? p) {
    switch (p) {
      case 'high':
        return _red;
      case 'medium':
        return _amber;
      case 'low':
        return _green;
      default:
        return _grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final priorityColor = _priorityColor(task.priority);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(12),
        border: Border(left: BorderSide(color: priorityColor, width: 4)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.title,
            style: const TextStyle(
                fontWeight: FontWeight.w700, fontSize: 14),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.description != null &&
              task.description!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              task.description!.trim(),
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          // ── Labels ────────────────────────────────────────────────────
          Builder(builder: (_) {
            final labels =
                _TaskListPageState._parseLabels(task.labelsJson);
            if (labels.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: labels.map((l) {
                  final color = _labelPalette[l['c'] as int];
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(l['t'] as String,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w600)),
                  );
                }).toList(),
              ),
            );
          }),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (task.priority != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: priorityColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    task.priority == 'high'
                        ? 'Haute'
                        : task.priority == 'medium'
                            ? 'Moyenne'
                            : 'Basse',
                    style: TextStyle(
                      color: priorityColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              if (task.deadline != null && task.deadline!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _grey.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('📅 ${task.deadline!}',
                      style: const TextStyle(fontSize: 11)),
                ),
            ],
          ),
          // ── Icônes indicateurs ─────────────────────────────────────────
          Builder(builder: (_) {
            final cl =
                _TaskListPageState._parseChecklist(task.checklistJson);
            final hasDesc = task.description != null &&
                task.description!.trim().isNotEmpty;
            final hasAudio =
                task.audioPath != null && task.audioPath!.isNotEmpty;
            final hasImg =
                task.imagePath != null && task.imagePath!.isNotEmpty;
            if (!hasDesc && cl.isEmpty && !hasAudio && !hasImg) {
              return const SizedBox.shrink();
            }
            final done = cl.where((i) => i['d'] == true).length;
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [
                if (hasDesc)
                  Icon(Icons.notes_rounded,
                      size: 13, color: Colors.grey[400]),
                if (cl.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.checklist_rounded,
                      size: 13, color: Colors.grey[400]),
                  const SizedBox(width: 2),
                  Text('$done/${cl.length}',
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey[400])),
                ],
                if (hasAudio) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.mic_rounded,
                      size: 13, color: Colors.grey[400]),
                ],
                if (hasImg) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.image_outlined,
                      size: 13, color: Colors.grey[400]),
                ],
              ]),
            );
          }),
        ],
      ),
    );
  }
}