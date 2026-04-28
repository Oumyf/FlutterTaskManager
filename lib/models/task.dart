
import 'package:isar/isar.dart';

part 'task.g.dart';

@collection
class Task {
  Id id = Isar.autoIncrement;
  late String title;
  String? description;
  String status = 'pending'; // pending, in_progress, completed, archived
  String? priority; // low, medium, high
  String? deadline;
  String? audioPath;
  String? imagePath;
  String? videoPath;
  DateTime createdAt = DateTime.now();

  // JSON : [{"t":"Bug","c":0}, ...]  — t=texte, c=index couleur 0-7
  String? labelsJson;
  // JSON : [{"t":"Étape 1","d":false}, ...]  — t=texte, d=done
  String? checklistJson;
  // JSON : [{"n":"fichier.pdf","p":"/path/to/file"}, ...]  — n=nom, p=chemin
  String? attachmentsJson;
  // Date/heure de notification programmée (ISO8601)
  String? scheduledNotification;
  // Email de la personne assignée
  String? assignedTo;
}
