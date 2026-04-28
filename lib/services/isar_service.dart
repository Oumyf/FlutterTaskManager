import 'dart:io';
import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';
import '../models/task.dart';

class IsarService {
  late Future<Isar> db;

  IsarService() {
    db = openDB();
  }

  Future<Isar> openDB() async {
    if (Isar.instanceNames.isNotEmpty) {
      return Isar.getInstance()!;
    }
    final dir = await getApplicationDocumentsDirectory();
    return await Isar.open(
      [TaskSchema],
      directory: dir.path,
    );
  }

  /// Efface la base Isar et la recrée (en cas de migration de schéma).
  Future<Isar> _resetDB() async {
    // Fermer l'instance si ouverte
    if (Isar.instanceNames.isNotEmpty) {
      final old = Isar.getInstance();
      await old?.close(deleteFromDisk: true);
    }
    final dir = await getApplicationDocumentsDirectory();
    // Supprimer les fichiers manuellement si nécessaire
    for (final name in ['default.isar', 'default.isar.lock']) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) await f.delete();
    }
    return await Isar.open([TaskSchema], directory: dir.path);
  }

  Future<void> addTask(Task task) async {
    final isar = await db;
    await isar.writeTxn(() async {
      await isar.tasks.put(task);
    });
  }

  Future<void> updateTask(Task task) async {
    final isar = await db;
    await isar.writeTxn(() async {
      await isar.tasks.put(task);
    });
  }

  Future<List<Task>> getAllTasks() async {
    try {
      final isar = await db;
      return await isar.tasks.where().findAll();
    } catch (e) {
      // Schéma incompatible avec les données sur disque → réinitialiser
      db = _resetDB();
      final isar = await db;
      return await isar.tasks.where().findAll();
    }
  }

  Future<void> deleteTask(int id) async {
    final isar = await db;
    await isar.writeTxn(() async {
      await isar.tasks.delete(id);
    });
  }
}
