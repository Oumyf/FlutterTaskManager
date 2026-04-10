import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_whisper_kit/flutter_whisper_kit.dart';
import 'package:whisper_kit/whisper_kit.dart' as wk;
import '../models/task.dart';
import '../services/isar_service.dart';
import '../services/notification_serve.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Couleurs globales
// ─────────────────────────────────────────────────────────────────────────────
const _primary   = Color(0xFF6366F1);
const _surface   = Color(0xFFF4F4FF);
const _cardBg    = Colors.white;
const _green     = Color(0xFF10B981);
const _blue      = Color(0xFF3B82F6);
const _red       = Color(0xFFEF4444);
const _amber     = Color(0xFFF59E0B);

// ─────────────────────────────────────────────────────────────────────────────
// Widget principal
// ─────────────────────────────────────────────────────────────────────────────
class TaskListPage extends StatefulWidget {
  const TaskListPage({super.key});
  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

class _TaskListPageState extends State<TaskListPage> with SingleTickerProviderStateMixin {
  int _currentPage = 0; // 0: liste, 1: ajout/modification, 2: board
  String _statusFilter = 'all';
  Task? _editingTask;
  int? _transcribingTaskId;
  static const String _transcriptMarker = '\n\n[TRANSCRIPTION_AUDIO]\n';
  final TextEditingController _searchController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autoValidateMode = AutovalidateMode.disabled;

  // Services
  final IsarService isarService = IsarService();
  final ImagePicker _picker = ImagePicker();
  final FlutterWhisperKit _whisperKit = FlutterWhisperKit();
  final wk.Whisper _androidWhisper = const wk.Whisper(model: wk.WhisperModel.base);
  bool _isTranscribingAudio = false;
  bool _whisperModelLoaded = false;

  // Formulaire
  final titleController       = TextEditingController();
  final descriptionController = TextEditingController();
  final deadlineController    = TextEditingController();
  String  status   = 'pending';
  String? priority;
  String? imagePath;
  String? videoPath;
  String? audioPath;

  // Audio WhatsApp
  final Record _recorder = Record();
  bool  _isRecording     = false;
  bool  _hasAudioDraft   = false;
  Duration _recordDuration = Duration.zero;
  late AnimationController _pulseController;

  // Données
  List<Task> tasks = [];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    loadTasks();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _recorder.dispose();
    _searchController.dispose();
    titleController.dispose();
    descriptionController.dispose();
    deadlineController.dispose();
    super.dispose();
  }

  // ── Données ──────────────────────────────────────────────────────────────

  Future<void> loadTasks() async {
    final loaded = await isarService.getAllTasks();
    setState(() => tasks = loaded);
  }

  Future<void> addTask() async {
    final hasTitle = titleController.text.trim().isNotEmpty;
    final hasAudio = audioPath != null;
    if (!hasTitle && !hasAudio) {
      _showSnack('Écrivez un titre ou enregistrez un audio', isError: true);
      return;
    }
    final task = Task()
      ..title       = hasTitle ? titleController.text.trim() : '🎤 Note vocale'
      ..description = descriptionController.text
      ..status      = status
      ..priority    = priority
      ..deadline    = deadlineController.text
      ..imagePath   = imagePath
      ..videoPath   = videoPath
      ..audioPath   = audioPath;
    await isarService.addTask(task);
    // Notification locale à la création
    await NotificationService.instance.notifyTaskCreated(
      task.title,
      deadline: task.deadline,
    );
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

    current
      ..title = hasTitle ? titleController.text.trim() : '🎤 Note vocale'
      ..description = descriptionController.text
      ..status = status
      ..priority = priority
      ..deadline = deadlineController.text
      ..imagePath = imagePath
      ..videoPath = videoPath
      ..audioPath = audioPath;

    await isarService.updateTask(current);
    await NotificationService.instance.notifyTaskUpdated(current.title, current.status);
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
    });
  }

  Future<void> _transcribeDraftAudio() async {
    if (audioPath == null || audioPath!.isEmpty) {
      _showSnack('Aucun audio à transcrire', isError: true);
      return;
    }
    if (Platform.isAndroid) {
      await _transcribeOnAndroid();
      return;
    }
    if (!(Platform.isIOS || Platform.isMacOS)) {
      _showSnack('Transcription non supportée sur cette plateforme', isError: true);
      return;
    }

    setState(() => _isTranscribingAudio = true);
    try {
      if (!_whisperModelLoaded) {
        await _whisperKit.loadModel('base');
        _whisperModelLoaded = true;
      }

      final result = await _whisperKit.transcribeFromFile(audioPath!);
      final text = result?.text.trim() ?? '';
      if (text.isEmpty) {
        _showSnack('Transcription vide', isError: true);
        return;
      }

      _appendTranscription(text);
      _showSnack('Transcription ajoutée à la description');
    } catch (e) {
      _showSnack('Erreur transcription: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isTranscribingAudio = false);
      }
    }
  }

  Future<void> _transcribeOnAndroid() async {
    setState(() => _isTranscribingAudio = true);
    try {
      if (audioPath == null || !audioPath!.toLowerCase().endsWith('.wav')) {
        _showSnack('Enregistrez un nouvel audio WAV 16 kHz pour Android', isError: true);
        return;
      }

      final result = await _androidWhisper.transcribe(
        transcribeRequest: wk.TranscribeRequest(
          audio: audioPath!,
          language: 'fr',
          isNoTimestamps: true,
          isTranslate: false,
          threads: 4,
          nProcessors: 2,
        ),
      );

      final text = result.text.trim();
      if (text.isEmpty) {
        _showSnack('Transcription vide, réessayez', isError: true);
        return;
      }

      _appendTranscription(text);
      _showSnack('Transcription Android ajoutée');
    } catch (e) {
      _showSnack('Erreur Whisper Android: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() => _isTranscribingAudio = false);
      }
    }
  }

  void _appendTranscription(String text) {
    final existing = descriptionController.text;
    descriptionController.text = _upsertTranscript(existing, text);
    if (mounted) {
      setState(() {});
    }
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
    final text = description.substring(idx + _transcriptMarker.length).trim();
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
      String text = '';

      if (Platform.isAndroid) {
        if (!path.toLowerCase().endsWith('.wav')) {
          _showSnack('Audio non compatible Android (WAV 16 kHz requis)', isError: true);
          return;
        }
        final res = await _androidWhisper.transcribe(
          transcribeRequest: wk.TranscribeRequest(
            audio: path,
            language: 'fr',
            isNoTimestamps: true,
            isTranslate: false,
            threads: 4,
            nProcessors: 2,
          ),
        );
        text = res.text.trim();
      } else if (Platform.isIOS || Platform.isMacOS) {
        if (!_whisperModelLoaded) {
          await _whisperKit.loadModel('base');
          _whisperModelLoaded = true;
        }
        final res = await _whisperKit.transcribeFromFile(path);
        text = res?.text.trim() ?? '';
      } else {
        _showSnack('Transcription non supportée sur cette plateforme', isError: true);
        return;
      }

      if (text.isEmpty) {
        _showSnack('Transcription vide', isError: true);
        return;
      }

      task.description = _upsertTranscript(task.description ?? '', text);
      await isarService.updateTask(task);
      await loadTasks();
      _showSnack('Transcription ajoutée à la tâche');
    } catch (e) {
      _showSnack('Erreur transcription tâche: $e', isError: true);
    } finally {
      if (mounted) setState(() => _transcribingTaskId = null);
    }
  }

  Future<void> deleteTask(int id) async {
    await isarService.deleteTask(id);
    loadTasks();
  }

  void _resetForm() {
    titleController.clear();
    descriptionController.clear();
    deadlineController.clear();
    _formKey.currentState?.reset();
    setState(() {
      status         = 'pending';
      priority       = null;
      imagePath      = null;
      videoPath      = null;
      audioPath      = null;
      _editingTask   = null;
      _hasAudioDraft = false;
      _isRecording   = false;
      _recordDuration = Duration.zero;
      _autoValidateMode = AutovalidateMode.disabled;
    });
  }

  // ── Audio WhatsApp ────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _showSnack('Permission micro refusée', isError: true);
      return;
    }
    final isAndroid = Platform.isAndroid;
    final dir  = await getApplicationDocumentsDirectory();
    final ext = isAndroid ? 'wav' : 'm4a';
    final path = '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.$ext';
    if (isAndroid) {
      await _recorder.start(
        path: path,
        encoder: AudioEncoder.wav,
        samplingRate: 16000,
        numChannels: 1,
      );
    } else {
      await _recorder.start(
        path: path,
        encoder: AudioEncoder.aacLc,
        bitRate: 128000,
      );
    }
    setState(() {
      _isRecording    = true;
      _recordDuration = Duration.zero;
      audioPath       = path;
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
      _isRecording   = false;
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
      _isRecording    = false;
      _hasAudioDraft  = false;
      audioPath       = null;
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

  void _showSnack(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? _red : _primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ));
  }

  // ── Couleurs helpers ─────────────────────────────────────────────────────

  Color _priorityColor(String? p) {
    switch (p) {
      case 'high':   return _red;
      case 'medium': return _amber;
      case 'low':    return _green;
      default:       return Colors.grey;
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'in_progress': return _blue;
      case 'completed': return _green;
      case 'archived':  return Colors.grey;
      default:          return _primary;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'in_progress': return 'En cours';
      case 'completed': return 'Terminée';
      case 'archived':  return 'Archivée';
      default:          return 'À faire';
    }
  }

  String? _validateTitle(String? value) {
    final text = (value ?? '').trim();
    final hasAudio = audioPath != null;
    if (text.isEmpty && !hasAudio) {
      return 'Titre requis si aucun audio';
    }
    if (text.length > 80) {
      return 'Maximum 80 caractères';
    }
    return null;
  }

  String? _validateDescription(String? value) {
    final text = (value ?? '').trim();
    if (text.length > 500) {
      return 'Maximum 500 caractères';
    }
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

  List<Task> _filteredTasks() {
    final query = _searchController.text.trim().toLowerCase();
    return tasks.where((t) {
      final byStatus = _statusFilter == 'all' || t.status == _statusFilter;
      final byText = query.isEmpty ||
          t.title.toLowerCase().contains(query) ||
          (t.description ?? '').toLowerCase().contains(query);
      return byStatus && byText;
    }).toList();
  }

  Future<void> _moveTaskToStatus(Task task, String newStatus) async {
    if (task.status == newStatus) return;
    task.status = newStatus;
    await isarService.updateTask(task);
    await NotificationService.instance.notifyTaskUpdated(task.title, newStatus);
    await loadTasks();
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
        onDestinationSelected: (i) => setState(() => _currentPage = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.checklist_rounded),
            label: 'Liste',
          ),
          NavigationDestination(
            icon: Icon(Icons.post_add_rounded),
            label: 'Ajouter',
          ),
          NavigationDestination(
            icon: Icon(Icons.view_kanban_outlined),
            label: 'Board',
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentPage() {
    if (_currentPage == 1) {
      return SafeArea(
        child: SingleChildScrollView(
          child: _buildForm(),
        ),
      );
    }
    if (_currentPage == 2) {
      return _buildKanbanBoard();
    }
    return Column(
      children: [
        _buildSearchBar(),
        _buildListFilters(),
        _buildList(),
      ],
    );
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
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 20),
      ),
      actions: [
        Padding(
          padding: const EdgeInsets.only(right: 16),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${tasks.length} tâche${tasks.length > 1 ? 's' : ''}',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildListFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
        children: [
          _filterChip('Tout', 'all'),
          const SizedBox(width: 8),
          _filterChip('À faire', 'pending'),
          const SizedBox(width: 8),
          _filterChip('En cours', 'in_progress'),
          const SizedBox(width: 8),
          _filterChip('Terminées', 'completed'),
        ],
        ),
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
      selectedColor: _primary.withOpacity(0.2),
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
        shadowColor: _primary.withOpacity(0.3),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        color: _cardBg,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            autovalidateMode: _autoValidateMode,
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Titre
              _input(
                titleController,
                'Titre de la tâche',
                Icons.edit_note_rounded,
                validator: _validateTitle,
                maxLength: 80,
              ),
              const SizedBox(height: 10),

              // Description
              _input(
                descriptionController,
                'Description (optionnelle)',
                Icons.notes_rounded,
                maxLines: 2,
                validator: _validateDescription,
                maxLength: 500,
              ),
              const SizedBox(height: 10),

              // Statut & Priorité
              Row(children: [
                Flexible(child: _dropdown(
                  value: status,
                  label: 'Statut',
                  icon: Icons.flag_outlined,
                  items: const {
                    'pending': 'À faire',
                    'in_progress': 'En cours',
                    'completed': 'Terminée',
                    'archived': 'Archivée',
                  },
                  onChanged: (v) => setState(() => status = v ?? 'pending'),
                  isDense: true,
                )),
                const SizedBox(width: 8),
                Flexible(child: _dropdown(
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

              // Échéance
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
                              onPressed: () =>
                                  setState(() => deadlineController.clear()),
                            )
                          : const Icon(Icons.calendar_today_rounded, size: 18),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Boutons médias (image + vidéo)
              Row(children: [
                _mediaBtn(
                  icon: Icons.image_outlined,
                  label: 'Image',
                  active: imagePath != null,
                  color: _primary,
                  onTap: _pickImage,
                ),
                const SizedBox(width: 8),
                _mediaBtn(
                  icon: Icons.videocam_outlined,
                  label: 'Vidéo',
                  active: videoPath != null,
                  color: _blue,
                  onTap: _pickVideo,
                ),
              ]),

              // Aperçus
              if (imagePath != null) ...[
                const SizedBox(height: 10),
                _imagePreview(imagePath!, onRemove: () => setState(() => imagePath = null)),
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
                    audioPath      = null;
                    _hasAudioDraft = false;
                  }),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _isTranscribingAudio ? null : _transcribeDraftAudio,
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
                if (_extractTranscript(descriptionController.text) != null) ...[
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _blue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _blue.withOpacity(0.25)),
                    ),
                    child: Text(
                      _extractTranscript(descriptionController.text)!,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ],

              const SizedBox(height: 14),

              // Barre inférieure : audio WhatsApp + bouton Ajouter
              _buildBottomBar(),
            ],
            ),
          ),
        ),
      ),
    );
  }

  // Barre audio style WhatsApp
  Widget _buildBottomBar() {
    if (_isRecording) {
      return _buildRecordingBar();
    }
    return Row(
      children: [
        // Bouton micro
        GestureDetector(
          onLongPressStart: (_) => _startRecording(),
          onLongPressEnd:   (_) => _stopRecording(),
          child: AnimatedBuilder(
            animation: _pulseController,
            builder: (_, __) => Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: _green.withOpacity(0.1),
                shape: BoxShape.circle,
                border: Border.all(color: _green, width: 1.5),
              ),
              child: const Icon(Icons.mic_rounded, color: _green, size: 26),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Hint
        Expanded(
          child: Text(
            'Maintenir pour enregistrer',
            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
          ),
        ),
        // Bouton Ajouter
        ElevatedButton(
          onPressed: _submitTask,
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
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
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecordingBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _green.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          // Annuler
          GestureDetector(
            onTap: _cancelRecording,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: _red.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.delete_outline, color: _red, size: 20),
            ),
          ),
          const SizedBox(width: 10),
          // Onde animée (simulation)
          Expanded(
            child: Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (_, __) => Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: _red.withOpacity(
                          0.5 + 0.5 * _pulseController.value),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDuration(_recordDuration),
                  style: const TextStyle(
                      color: _red, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _WaveformAnimation(controller: _pulseController),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Valider
          GestureDetector(
            onTap: _stopRecording,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: const BoxDecoration(
                color: _green,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send_rounded,
                  color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImage() async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.photo_library_outlined, color: _primary),
              ),
              title: const Text('Galerie'),
              onTap: () async {
                final f = await _picker.pickImage(source: ImageSource.gallery);
                Navigator.pop(context);
                if (f != null) setState(() => imagePath = f.path);
              },
            ),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                    color: _blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.camera_alt_outlined, color: _blue),
              ),
              title: const Text('Appareil photo'),
              onTap: () async {
                final f = await _picker.pickImage(source: ImageSource.camera);
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
                onEdit: () => _startEditing(filteredTasks[i]),
                onDelete: () => deleteTask(filteredTasks[i].id),
                onTranscribeAudio: filteredTasks[i].audioPath != null && filteredTasks[i].audioPath!.isNotEmpty
                    ? () => _transcribeTaskAudio(filteredTasks[i])
                    : null,
                transcribing: _transcribingTaskId == filteredTasks[i].id,
                priorityColor: _priorityColor(filteredTasks[i].priority),
                statusColor: _statusColor(filteredTasks[i].status),
                statusLabel: _statusLabel(filteredTasks[i].status),
              ),
            ),
    );
  }

  Widget _buildKanbanBoard() {
    final source = _filteredTasks();
    final pending = source.where((t) => t.status == 'pending').toList();
    final inProgress = source.where((t) => t.status == 'in_progress').toList();
    final completed = source.where((t) => t.status == 'completed').toList();

    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFEEF2FF), Color(0xFFF8FAFF)],
        ),
      ),
      child: Column(
        children: [
          _buildSearchBar(),
          const SizedBox(height: 10),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              children: [
                _buildBoardColumn(
                  title: 'À faire',
                  statusKey: 'pending',
                  color: _amber,
                  columnTasks: pending,
                ),
                const SizedBox(width: 12),
                _buildBoardColumn(
                  title: 'En cours',
                  statusKey: 'in_progress',
                  color: _blue,
                  columnTasks: inProgress,
                ),
                const SizedBox(width: 12),
                _buildBoardColumn(
                  title: 'Terminées',
                  statusKey: 'completed',
                  color: _green,
                  columnTasks: completed,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBoardColumn({
    required String title,
    required String statusKey,
    required Color color,
    required List<Task> columnTasks,
  }) {
    return Container(
      width: 320,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.circle, size: 10, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$title (${columnTasks.length})',
                    style: TextStyle(fontWeight: FontWeight.w700, color: color),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: DragTarget<Task>(
              onWillAccept: (task) => task != null,
              onAccept: (task) => _moveTaskToStatus(task, statusKey),
              builder: (context, _, __) {
                if (columnTasks.isEmpty) {
                  return Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F8FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.withOpacity(0.2)),
                    ),
                    alignment: Alignment.center,
                    child: const Text('Glissez une tâche ici'),
                  );
                }

                return ListView.separated(
                  itemCount: columnTasks.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final task = columnTasks[i];
                    return LongPressDraggable<Task>(
                      data: task,
                      feedback: Material(
                        color: Colors.transparent,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: _BoardTaskTile(task: task),
                        ),
                      ),
                      childWhenDragging: Opacity(
                        opacity: 0.4,
                        child: _BoardTaskTile(task: task),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _startEditing(task),
                        child: _BoardTaskTile(task: task),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
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
              color: _primary.withOpacity(0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.checklist_rounded,
                size: 56, color: _primary.withOpacity(0.3)),
          ),
          const SizedBox(height: 16),
          Text('Aucune tâche',
              style: TextStyle(
                  color: Colors.grey[500],
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          Text('Ajoutez votre première tâche ci-dessus',
              style: TextStyle(color: Colors.grey[400], fontSize: 13)),
        ],
      ),
    );
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  InputDecoration _inputDec(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20, color: _primary),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
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
        decoration: _inputDec(label, icon),
        items: items.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: onChanged,
        isDense: isDense,
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
              color: active ? color.withOpacity(0.1) : Colors.grey[50],
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
                        fontWeight:
                            active ? FontWeight.w600 : FontWeight.normal)),
              ],
            ),
          ),
        ),
      );

  Widget _imagePreview(String path, {required VoidCallback onRemove}) =>
      Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(File(path),
              height: 110, width: double.infinity, fit: BoxFit.cover),
        ),
        Positioned(
          top: 6, right: 6,
          child: GestureDetector(
            onTap: onRemove,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20)),
              child: const Icon(Icons.close, color: Colors.white, size: 16),
            ),
          ),
        ),
      ]);

  Widget _mediaChip(IconData icon, String label, Color color,
      {VoidCallback? onRemove}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.3)),
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
// Widget waveform animée pendant l'enregistrement
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
            final h = 6.0 + 14.0 * ((i % 3 == 0)
                ? controller.value
                : (i % 3 == 1)
                    ? (1 - controller.value)
                    : 0.5);
            return Container(
              width: 3,
              height: h,
              decoration: BoxDecoration(
                color: _green.withOpacity(0.7),
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
// Chip de lecture audio (draft dans le formulaire)
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
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.setFilePath(widget.path);
      await _player.play();
    }
    setState(() => _playing = !_playing);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _green.withOpacity(0.3)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
            child: Icon(_playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 10),
        const Expanded(
          child: Text('Audio enregistré',
              style: TextStyle(color: _green, fontWeight: FontWeight.w500)),
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
// Carte de tâche (extraite du build pour éviter les classes imbriquées)
// ─────────────────────────────────────────────────────────────────────────────
class _TaskCard extends StatelessWidget {
  final Task task;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onTranscribeAudio;
  final bool transcribing;
  final Color priorityColor;
  final Color statusColor;
  final String statusLabel;

  const _TaskCard({
    required this.task,
    required this.onEdit,
    required this.onDelete,
    required this.onTranscribeAudio,
    this.transcribing = false,
    required this.priorityColor,
    required this.statusColor,
    required this.statusLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
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
            // Titre + statut + supprimer
            Row(children: [
              Expanded(
                child: Text(task.title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15)),
              ),
              _StatusBadge(label: statusLabel, color: statusColor),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onEdit,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _blue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.edit_outlined, color: _blue, size: 18),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: onDelete,
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _red.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.delete_outline,
                      color: _red, size: 18),
                ),
              ),
            ]),

            // Description
            if (task.description != null &&
                task.description!.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(task.description!,
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],

            // Image
            if (task.imagePath != null && task.imagePath!.isNotEmpty) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(File(task.imagePath!),
                    height: 100, width: double.infinity, fit: BoxFit.cover),
              ),
            ],

            // Vidéo
            if (task.videoPath != null && task.videoPath!.isNotEmpty) ...[
              const SizedBox(height: 10),
              _VideoPreviewWidget(videoPath: task.videoPath!),
            ],

            // Audio WhatsApp style
            if (task.audioPath != null && task.audioPath!.isNotEmpty) ...[
              const SizedBox(height: 10),
              _AudioBubble(path: task.audioPath!),
              if (onTranscribeAudio != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: transcribing ? null : onTranscribeAudio,
                    icon: transcribing
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.subtitles_outlined, size: 18),
                    label: Text(transcribing ? 'Transcription...' : 'Transcrire cet audio'),
                  ),
                ),
              ],
              if (task.description != null &&
                  task.description!.contains(_TaskListPageState._transcriptMarker)) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _blue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _blue.withOpacity(0.25)),
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

            const SizedBox(height: 10),

            // Tags
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
                _Tag(label: '📅 ${task.deadline!}', color: Colors.grey),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bulle audio style WhatsApp dans la carte de tâche
// ─────────────────────────────────────────────────────────────────────────────
class _AudioBubble extends StatefulWidget {
  final String path;
  const _AudioBubble({required this.path});

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final _player = AudioPlayer();
  bool     _playing  = false;
  Duration _total    = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.setFilePath(widget.path).then((_) {
      setState(() => _total = _player.duration ?? Duration.zero);
    });
    _player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted) {
        setState(() {
          _playing  = false;
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
        color: _green.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _green.withOpacity(0.2)),
      ),
      child: Row(children: [
        // Bouton play/pause
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(color: _green, shape: BoxShape.circle),
            child: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // Progress + durée
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress.clamp(0.0, 1.0),
                  backgroundColor: _green.withOpacity(0.15),
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
// Lecteur vidéo dans la carte de tâche
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
    _controller = VideoPlayerController.file(File(widget.videoPath))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
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
// Petits widgets utilitaires
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
          color: color.withOpacity(0.1),
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
          color: color.withOpacity(0.1),
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
        return Colors.grey;
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
            color: Colors.black.withOpacity(0.05),
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
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (task.description != null && task.description!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              task.description!.trim(),
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (task.priority != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: priorityColor.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    task.priority!,
                    style: TextStyle(
                      color: priorityColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              if (task.deadline != null && task.deadline!.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.withOpacity(0.14),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '📅 ${task.deadline!}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}