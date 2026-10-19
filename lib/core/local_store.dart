import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../features/generation/operation.dart';
import '../features/menus/menu.dart';

class LocalStore {
  LocalStore(this.database);
  final Database database;
  static const schemaVersion = 1;

  static Future<LocalStore> open({
    DatabaseFactory? factory,
    String? path,
  }) async {
    final dbFactory = factory ?? databaseFactory;
    final dbPath =
        path ?? '${await dbFactory.getDatabasesPath()}/meal_budget.db';
    final db = await dbFactory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE draft (id INTEGER PRIMARY KEY CHECK(id=1), json TEXT NOT NULL)',
          );
          await db.execute(
            '''CREATE TABLE operations (
          server TEXT PRIMARY KEY, operation_key TEXT NOT NULL, snapshot TEXT NOT NULL,
          installation_id TEXT NOT NULL, first_sent_at TEXT NOT NULL, retry_until TEXT,
          job_id TEXT, phase TEXT NOT NULL, error_code TEXT, next_attempt_at TEXT)''',
          );
          await db.execute('''CREATE TABLE menus (
          id TEXT NOT NULL, server TEXT NOT NULL, created_at TEXT NOT NULL,
          result TEXT NOT NULL, PRIMARY KEY(server, id))''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // Future versions add explicit migrations here; never recreate user data.
          throw StateError('Не поддерживается миграция локальной БД.');
        },
      ),
    );
    return LocalStore(db);
  }

  Future<Map<String, String>?> loadDraft() async {
    final rows = await database.query('draft', where: 'id=1');
    return rows.isEmpty
        ? null
        : Map<String, String>.from(
            jsonDecode(rows.single['json'] as String) as Map,
          );
  }

  Future<void> saveDraft(Map<String, String> draft) async {
    await database.insert('draft', {
      'id': 1,
      'json': jsonEncode(draft),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Operation?> loadOperation(String server) async {
    final rows = await database.query(
      'operations',
      where: 'server=?',
      whereArgs: [server],
    );
    return rows.isEmpty ? null : Operation.fromRow(rows.single);
  }

  Future<void> saveOperation(Operation operation) async {
    await database.transaction((tx) async {
      await tx.insert(
        'operations',
        operation.toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<void> complete(
    Operation operation,
    MenuResult result,
    DateTime now,
  ) async {
    await database.transaction((tx) async {
      await tx.insert('menus', {
        'id': operation.key,
        'server': operation.server,
        'created_at': now.toIso8601String(),
        'result': jsonEncode(result.json),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.insert(
        'operations',
        operation.copy(phase: 'completed').toRow(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<List<SavedMenu>> menus() async => [
    for (final row in await database.query('menus', orderBy: 'created_at DESC'))
      SavedMenu(
        id: row['id'] as String,
        server: row['server'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        result: MenuResult.fromJson(
          object(jsonDecode(row['result'] as String)),
        ),
      ),
  ];

  Future<void> deleteMenu(SavedMenu menu) async {
    await database.delete(
      'menus',
      where: 'server=? AND id=?',
      whereArgs: [menu.server, menu.id],
    );
  }

  Future<void> clearOperation(String server) async {
    await database.delete('operations', where: 'server=?', whereArgs: [server]);
  }

  Future<void> close() => database.close();
}
