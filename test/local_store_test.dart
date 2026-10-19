import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meal_budget_mobile/core/local_store.dart';
import 'package:meal_budget_mobile/features/generation/operation.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

void main() {
  test(
    'SQLite v1 survives close/reopen, offline names and money; local deletion',
    () async {
      sqfliteFfiInit();
      final parent = await Directory('/tmp/opencode').create(recursive: true);
      final dir = await parent.createTemp('meal10-sqlite-');
      final path = '${dir.path}/test.db';
      final store = await LocalStore.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      expect(await store.database.getVersion(), 1);
      await store.saveDraft(draft());
      final now = DateTime.utc(2026, 10, 18);
      final operation = Operation(
        server: 'https://example.com',
        key: 'key',
        snapshot: '{}',
        installationId: 'installation',
        firstSentAt: now,
        jobId: jobId,
      );
      await store.saveOperation(operation);
      await store.complete(
        operation,
        MenuResult.fromJson(object(completed()['result'])),
        now,
      );
      await store.complete(
        operation,
        MenuResult.fromJson(object(completed()['result'])),
        now,
      );
      await store.close();
      final reopened = await LocalStore.open(
        factory: databaseFactoryFfi,
        path: path,
      );
      expect(await reopened.loadDraft(), draft());
      expect(
        (await reopened.loadOperation(operation.server))!.phase,
        'completed',
      );
      final menus = await reopened.menus();
      expect(menus.length, 1);
      expect(menus.single.result.productNames['oats'], 'Овсяные хлопья');
      expect(rubles(menus.single.result.calculation['total_cost']), '89,90 ₽');
      await reopened.clearOperation(operation.server);
      expect((await reopened.menus()).length, 1);
      await reopened.deleteMenu(menus.single);
      expect(await reopened.menus(), isEmpty);
      await reopened.close();
      // Only our uniquely-created synthetic test file is removed.
      await File(path).delete();
      await dir.delete();
    },
  );

  test('Failed pre-POST transaction cannot persist a partial snapshot', () async {
    sqfliteFfiInit();
    final store = await LocalStore.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    await store.database.execute(
      "CREATE TRIGGER reject_operation BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'test'); END",
    );
    final op = Operation(
      server: 'https://example.com',
      key: 'key',
      snapshot: '{}',
      installationId: 'installation',
      firstSentAt: DateTime.utc(2026),
    );
    await expectLater(
      store.saveOperation(op),
      throwsA(isA<DatabaseException>()),
    );
    expect(await store.loadOperation(op.server), isNull);
    await store.close();
  });
}
