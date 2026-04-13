import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import '../models/task.dart';

class IsarService {
  late Future<Isar> db;

  IsarService() {
    db = openDB();
  }

  Future<Isar> openDB() async {
    final dir = await getApplicationDocumentsDirectory();
    return await Isar.open(
      [TaskSchema],
      directory: dir.path,
    );
  }

  Future<void> addTask(Task task) async {
    final isar = await db;
    await isar.writeTxn(() async {
      await isar.tasks.put(task);
    });
  }

  Future<void> updateTask(Task task) async {
    final isar = await db;
    print('[updateTask] id=${task.id}, title=${task.title}, status=${task.status}');
    await isar.writeTxn(() async {
      await isar.tasks.put(task);
    });
  }

  Future<List<Task>> getAllTasks() async {
    final isar = await db;
    return await isar.tasks.where().findAll();
  }

  Future<void> deleteTask(int id) async {
    final isar = await db;
    await isar.writeTxn(() async {
      await isar.tasks.delete(id);
    });
  }
}
