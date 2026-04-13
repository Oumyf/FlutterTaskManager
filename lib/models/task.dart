
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
}
