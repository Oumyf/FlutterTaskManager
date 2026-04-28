import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/task.dart';
import '../services/isar_service.dart';
import '../services/api_service.dart';

// Palette étiquettes (doit rester synchronisée avec task_list_page.dart)
const _labelPalette = [
  Color(0xFFEF4444),
  Color(0xFFF59E0B),
  Color(0xFF10B981),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
  Color(0xFFEC4899),
  Color(0xFF06B6D4),
  Color(0xFF64748B),
];

const _primary = Color(0xFF6366F1);
const _green  = Color(0xFF10B981);
const _blue   = Color(0xFF3B82F6);
const _red    = Color(0xFFEF4444);
const _amber  = Color(0xFFF59E0B);
const _grey   = Color(0xFF94A3B8);

class TaskDetailPage extends StatefulWidget {
  final Task task;
  final VoidCallback onTaskUpdated;

  const TaskDetailPage({
    super.key,
    required this.task,
    required this.onTaskUpdated,
  });

  @override
  State<TaskDetailPage> createState() => _TaskDetailPageState();
}

class _TaskDetailPageState extends State<TaskDetailPage> {
  late Task _task;
  final IsarService _isarService = IsarService();
  final ApiService _api = ApiService.instance;

  @override
  void initState() {
    super.initState();
    _task = widget.task;
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _labels {
    if (_task.labelsJson == null || _task.labelsJson!.isEmpty) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(_task.labelsJson!));
    } catch (_) { return []; }
  }

  List<Map<String, dynamic>> get _checklist {
    if (_task.checklistJson == null || _task.checklistJson!.isEmpty) return [];
    try {
      return List<Map<String, dynamic>>.from(jsonDecode(_task.checklistJson!));
    } catch (_) { return []; }
  }

  Future<void> _toggleChecklistItem(int index, bool value) async {
    final cl = _checklist;
    cl[index]['d'] = value;
    setState(() {
      _task.checklistJson = cl.isEmpty ? null : jsonEncode(cl);
    });
    try {
      await _api.updateTask(_task);
    } catch (_) {
      await _isarService.updateTask(_task);
    }
    widget.onTaskUpdated();
  }

  Future<void> _addToGoogleCalendar() async {
    final deadline = _task.deadline;
    if (deadline == null || deadline.isEmpty) return;

    // Tente de parser la date (format attendu : dd/MM/yyyy ou yyyy-MM-dd)
    DateTime? date;
    try {
      final parts = deadline.contains('/')
          ? deadline.split('/')
          : deadline.split('-');
      if (parts.length == 3) {
        if (deadline.contains('/')) {
          date = DateTime(int.parse(parts[2]), int.parse(parts[1]), int.parse(parts[0]));
        } else {
          date = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
        }
      }
    } catch (_) {}

    // Format Google Calendar : YYYYMMDDTHHmmSSZ
    final String dateStr;
    if (date != null) {
      final y = date.year.toString().padLeft(4, '0');
      final m = date.month.toString().padLeft(2, '0');
      final d = date.day.toString().padLeft(2, '0');
      dateStr = '${y}${m}${d}';
    } else {
      // Fallback : aujourd'hui
      final now = DateTime.now();
      dateStr = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    }

    final title = Uri.encodeComponent(_task.title);
    final desc = Uri.encodeComponent(_task.description ?? '');

    // URL Google Calendar pour créer un événement
    final url = Uri.parse(
      'https://calendar.google.com/calendar/render'
      '?action=TEMPLATE'
      '&text=$title'
      '&dates=${dateStr}T090000Z/${dateStr}T100000Z'
      '&details=$desc',
    );

    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Impossible d\'ouvrir Google Calendar'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'in_progress': return _blue;
      case 'completed':   return _green;
      case 'archived':    return _grey;
      default:            return _amber;
    }
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'in_progress': return 'En cours';
      case 'completed':   return 'Terminée';
      case 'archived':    return 'Archivée';
      default:            return 'À faire';
    }
  }

  Color _priorityColor(String? p) {
    switch (p) {
      case 'high':   return _red;
      case 'medium': return _amber;
      case 'low':    return _green;
      default:       return _grey;
    }
  }

  String _priorityLabel(String? p) {
    switch (p) {
      case 'high':   return 'Haute';
      case 'medium': return 'Moyenne';
      case 'low':    return 'Basse';
      default:       return '—';
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(_task.status);
    final cl = _checklist;
    final done = cl.where((i) => i['d'] == true).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF4F4FF),
      appBar: AppBar(
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Détails de la tâche',
            style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (_task.deadline != null && _task.deadline!.isNotEmpty)
            IconButton(
              tooltip: 'Ajouter à Google Calendar',
              icon: const Icon(Icons.calendar_month_rounded),
              onPressed: _addToGoogleCalendar,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Carte principale ─────────────────────────────────────────
            _card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Titre + statut
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _task.title,
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(_statusLabel(_task.status),
                            style: TextStyle(
                                color: statusColor,
                                fontWeight: FontWeight.w700,
                                fontSize: 12)),
                      ),
                    ],
                  ),

                  // Étiquettes
                  if (_labels.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _labels.map((l) {
                        final color = _labelPalette[l['c'] as int];
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(l['t'] as String,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600)),
                        );
                      }).toList(),
                    ),
                  ],

                  const SizedBox(height: 14),
                  const Divider(height: 1),
                  const SizedBox(height: 14),

                  // Métadonnées
                  _metaRow(Icons.flag_outlined, 'Priorité',
                      _priorityLabel(_task.priority),
                      _priorityColor(_task.priority)),
                  if (_task.deadline != null &&
                      _task.deadline!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _metaRow(Icons.event_rounded, 'Échéance',
                        _task.deadline!, _grey),
                  ],
                  const SizedBox(height: 10),
                  _metaRow(Icons.access_time_rounded, 'Créée le',
                      '${_task.createdAt.day.toString().padLeft(2, '0')}/'
                      '${_task.createdAt.month.toString().padLeft(2, '0')}/'
                      '${_task.createdAt.year}',
                      _grey),
                ],
              ),
            ),

            // ── Description ───────────────────────────────────────────────
            if (_task.description != null &&
                _task.description!.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionTitle(Icons.notes_rounded, 'Description'),
              _card(
                child: Text(
                  _task.description!.trim(),
                  style: const TextStyle(fontSize: 14, height: 1.5),
                ),
              ),
            ],

            // ── Checklist ────────────────────────────────────────────────
            if (cl.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionTitle(Icons.checklist_rounded,
                  'Checklist  $done/${cl.length}'),
              _card(
                child: Column(
                  children: [
                    // Barre de progression
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: cl.isEmpty ? 0 : done / cl.length,
                        backgroundColor: _primary.withValues(alpha: 0.12),
                        valueColor:
                            const AlwaysStoppedAnimation(_primary),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...cl.asMap().entries.map((e) {
                      final isDone = e.value['d'] as bool;
                      return InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () =>
                            _toggleChecklistItem(e.key, !isDone),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 4),
                          child: Row(children: [
                            Checkbox(
                              value: isDone,
                              onChanged: (v) =>
                                  _toggleChecklistItem(e.key, v ?? false),
                              activeColor: _primary,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            Expanded(
                              child: Text(
                                e.value['t'] as String,
                                style: TextStyle(
                                  fontSize: 14,
                                  decoration: isDone
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: isDone
                                      ? Colors.grey[400]
                                      : Colors.black87,
                                ),
                              ),
                            ),
                          ]),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],

            // ── Image ─────────────────────────────────────────────────────
            if (_task.imagePath != null &&
                _task.imagePath!.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionTitle(Icons.image_outlined, 'Image'),
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.file(
                  File(_task.imagePath!),
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
              ),
            ],

            // ── Audio ─────────────────────────────────────────────────────
            if (_task.audioPath != null &&
                _task.audioPath!.isNotEmpty) ...[
              const SizedBox(height: 12),
              _sectionTitle(Icons.mic_rounded, 'Audio'),
              _card(
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                        color: _green, shape: BoxShape.circle),
                    child: const Icon(Icons.play_arrow_rounded,
                        color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Text('Fichier audio joint',
                      style: TextStyle(
                          color: Colors.grey[600], fontSize: 13)),
                ]),
              ),
            ],

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: child,
      );

  Widget _sectionTitle(IconData icon, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(children: [
          Icon(icon, size: 16, color: _primary),
          const SizedBox(width: 6),
          Text(title,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _primary)),
        ]),
      );

  Widget _metaRow(IconData icon, String label, String value, Color color) =>
      Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text('$label : ',
            style:
                TextStyle(fontSize: 13, color: Colors.grey[500])),
        Text(value,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: color)),
      ]);
}
