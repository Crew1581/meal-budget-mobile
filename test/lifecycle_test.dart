import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meal_budget_mobile/app.dart';
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/local_store.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/connection/installation_service.dart';
import 'package:meal_budget_mobile/features/generation/generation_controller.dart';
import 'package:meal_budget_mobile/features/generation/operation.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:sqflite/sqflite.dart';

import 'support.dart';

class _UnusedDatabase extends Fake implements Database {}

class _Store extends LocalStore {
  _Store() : super(_UnusedDatabase());
  Operation? current;
  int writes = 0;
  int completeStarts = 0;
  int commits = 0;
  int menuReads = 0;
  Completer<void>? commitGate;
  final saved = <SavedMenu>[];
  @override
  Future<Map<String, String>?> loadDraft() async => null;
  @override
  Future<Operation?> loadOperation(String server) async => current;
  @override
  Future<void> saveOperation(Operation operation) async {
    writes++;
    current = operation;
  }

  @override
  Future<List<SavedMenu>> menus() async {
    menuReads++;
    return List.of(saved);
  }

  @override
  Future<void> complete(
    Operation operation,
    MenuResult result,
    DateTime now,
  ) async {
    completeStarts++;
    await commitGate?.future;
    commits++;
    current = operation.copy(phase: 'completed');
    saved.add(
      SavedMenu(
        id: operation.key,
        server: operation.server,
        createdAt: now,
        result: result,
      ),
    );
  }
}

class _Transport extends http.BaseClient {
  int gets = 0;
  int aborts = 0;
  Completer<http.Response>? responseGate;
  http.Response response = jsonResponse({
    ...completed(),
    'state': 'running',
    'result': null,
  });
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method != 'GET') throw StateError('Expected GET');
    gets++;
    unawaited(
      (request as http.Abortable).abortTrigger!.then((_) {
        aborts++;
      }),
    );
    // Deliberately ignore cancellation to reproduce delivery by an uncooperative transport.
    final result = await (responseGate?.future ?? Future.value(response));
    return http.StreamedResponse(
      Stream.value(result.bodyBytes),
      result.statusCode,
      headers: result.headers,
    );
  }
}

class _Controller extends GenerationController {
  _Controller({
    required super.api,
    required super.installations,
    required super.store,
  }) : super(pollInterval: const Duration(seconds: 1));
  int disposals = 0;
  @override
  void dispose() {
    disposals++;
    super.dispose();
  }
}

Future<(_Controller, _Store, _Transport)> _scenario() async {
  final config = ServerConfig('https://example.com');
  final store = _Store()
    ..current = Operation(
      server: config.baseUrl,
      key: 'lifecycle-key',
      snapshot: jsonEncode(questionnaire().json),
      installationId: issued['installation_id']!,
      firstSentAt: DateTime.utc(2026),
      jobId: jobId,
      phase: 'queued',
    );
  final transport = _Transport();
  final api = ApiClient(config, transport);
  final credentials = MemoryCredentials()
    ..values[config.storageKey] = jsonEncode(issued);
  final controller = _Controller(
    api: api,
    installations: InstallationService(api, credentials),
    store: store,
  );
  controller.setForeground(false);
  await controller.initialize();
  return (controller, store, transport);
}

void main() {
  for (final root in [true, false]) {
    testWidgets(
      'Removing ${root ? 'application' : 'HomeScreen owner'} stops polling without manual dispose',
      (tester) async {
        final (controller, _, transport) = await _scenario();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(
          root
              ? MealBudgetApp(controller: controller)
              : MaterialApp(home: HomeScreen(controller: controller)),
        );
        await tester.pump(const Duration(milliseconds: 1));
        expect(transport.gets, 1, reason: controller.message);
        await tester.pumpWidget(
          root ? const SizedBox() : const MaterialApp(home: SizedBox()),
        );
        expect(controller.disposals, 1);
        await tester.pump(const Duration(seconds: 10));
        expect(transport.gets, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final late in ['running', 'completed', 'error']) {
    testWidgets(
      'Owner removal aborts GET and ignores late $late without writes or notifications',
      (tester) async {
        final (controller, store, transport) = await _scenario();
        transport.responseGate = Completer<http.Response>();
        var notifications = 0;
        controller.addListener(() {
          notifications++;
        });
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(MealBudgetApp(controller: controller));
        await tester.pump(const Duration(milliseconds: 1));
        expect(transport.gets, 1, reason: controller.message);
        expect(controller.getting, true);
        await tester.pumpWidget(const SizedBox());
        expect(controller.disposals, 1);
        expect(transport.aborts, 1);
        final writes = store.writes;
        final reads = store.menuReads;
        final changes = notifications;
        transport.responseGate!.complete(
          late == 'error'
              ? failure(429, 'generation_queue_full', retry: '30')
              : jsonResponse({
                  ...completed(),
                  'state': late,
                  if (late == 'running') 'result': null,
                }),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 40));
        expect(transport.gets, 1);
        expect(store.writes, writes);
        expect(store.menuReads, reads);
        expect(store.completeStarts, 0);
        expect(notifications, changes);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Owner removal does not undo an already-started completion transaction',
    (tester) async {
      final (controller, store, transport) = await _scenario();
      store.commitGate = Completer<void>();
      transport.response = jsonResponse(completed());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      await tester.pump(const Duration(milliseconds: 1));
      expect(store.completeStarts, 1);
      await tester.pumpWidget(const SizedBox());
      final reads = store.menuReads;
      store.commitGate!.complete();
      await tester.pump(const Duration(milliseconds: 1));
      expect(store.commits, 1);
      expect(store.current!.phase, 'completed');
      expect(store.saved.length, 1);
      expect(store.menuReads, reads);
      expect(transport.gets, 1);
      expect(controller.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Rebuild and navigation retain ownership; background/resume still works',
    (tester) async {
      final (controller, _, transport) = await _scenario();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.getting, false, reason: controller.message);
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      expect(controller.disposals, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 10));
      expect(transport.gets, 1);
      expect(controller.disposals, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
      expect(transport.gets, 2, reason: controller.message);
      final navigator = Navigator.of(tester.element(find.byType(HomeScreen)));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Другой экран')),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(controller.disposals, 0);
      expect(transport.gets, greaterThan(2));
      navigator.pop();
      await tester.pump(const Duration(seconds: 1));
      expect(controller.disposals, 0);
      await tester.pumpWidget(const SizedBox());
      expect(controller.disposals, 1);
    },
  );

  testWidgets(
    'Replacing the injected controller disposes the old one exactly once',
    (tester) async {
      final (first, _, _) = await _scenario();
      final (second, _, _) = await _scenario();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(MealBudgetApp(controller: first));
      await tester.pumpWidget(MealBudgetApp(controller: second));
      expect(first.disposals, 1);
      expect(second.disposals, 0);
      await tester.pumpWidget(const SizedBox());
      expect(first.disposals, 1);
      expect(second.disposals, 1);
    },
  );
}
