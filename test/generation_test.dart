import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/local_store.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/connection/installation_service.dart';
import 'package:meal_budget_mobile/features/generation/generation_controller.dart';
import 'package:meal_budget_mobile/features/generation/operation.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late MemoryCredentials credentials;
  late DateTime now;
  final controllers = <GenerationController>[];
  final config = ServerConfig(
    'https://example.com',
    minimumRetention: const Duration(hours: 24),
  );

  GenerationController controller(
    Future<http.Response> Function(http.Request) handler, {
    ServerConfig? server,
    Duration interval = const Duration(hours: 1),
  }) {
    final api = ApiClient(server ?? config, MockClient(handler));
    final result = GenerationController(
      api: api,
      installations: InstallationService(api, credentials),
      store: store,
      clock: () => now,
      pollInterval: interval,
    );
    controllers.add(result);
    return result;
  }

  Future<void> seed({String? id, DateTime? first, DateTime? until}) async {
    credentials.values[config.storageKey] = jsonEncode(issued);
    await store.saveOperation(
      Operation(
        server: config.baseUrl,
        key: 'original-key',
        snapshot: jsonEncode(questionnaire().json),
        installationId: issued['installation_id']!,
        firstSentAt: first ?? now,
        retryUntil: until ?? now.add(const Duration(hours: 23)),
        jobId: id,
        phase: id == null ? 'unknown' : 'queued',
      ),
    );
  }

  setUp(() async {
    sqfliteFfiInit();
    store = await LocalStore.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    credentials = MemoryCredentials();
    now = DateTime.utc(2026, 10, 18, 12);
  });
  tearDown(() async {
    for (final c in controllers) {
      c.dispose();
    }
    controllers.clear();
    await store.close();
  });

  for (final withJob in [false, true]) {
    test(
      'Secure decrypt error reaches controller ${withJob ? 'polling' : 'create'} without registration, deletion or POST',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        if (withJob) await seed(id: jobId);
        const channel = MethodChannel(
          'plugins.it_nomads.com/flutter_secure_storage',
        );
        final methods = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              methods.add(call.method);
              throw PlatformException(
                code: 'Exception encountered',
                message: 'synthetic-private-error',
                details: 'synthetic-private-details',
              );
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null),
        );
        var requests = 0;
        final api = ApiClient(
          config,
          MockClient((_) async {
            requests++;
            return jsonResponse(issued, 201);
          }),
        );
        final c = GenerationController(
          api: api,
          installations: InstallationService(
            api,
            SecureCredentials(
              FlutterSecureStorage(
                aOptions: AndroidOptions(
                  resetOnError: false,
                  storageNamespace: 'p1_mock_$withJob',
                ),
              ),
            ),
          ),
          store: store,
        );
        controllers.add(c);
        c.setForeground(false);
        await c.initialize();
        if (withJob) {
          c.setForeground(true);
          await c.refresh();
        } else {
          await c.create(questionnaire());
        }
        expect(c.message, contains('Не удалось прочитать токен'));
        expect(c.message, isNot(contains('synthetic-private')));
        if (withJob) {
          await c.refresh();
        } else {
          await c.create(questionnaire());
        }
        expect(requests, 0);
        expect(methods, ['read']);
        expect((await store.menus()), isEmpty);
      },
    );
  }

  test(
    'Initialization storage error fails closed before registration or POST',
    () async {
      await store.database.execute('DROP TABLE operations');
      var calls = 0;
      final c = controller((_) async {
        calls++;
        return jsonResponse(issued, 201);
      });
      await c.initialize();
      await c.create(questionnaire());
      expect(calls, 0);
      expect(c.message, contains('локальные данные'));
    },
  );

  test('Pre-POST SQLite failure prevents HTTP job creation', () async {
    await store.database.execute(
      "CREATE TRIGGER reject_operation BEFORE INSERT ON operations BEGIN SELECT RAISE(ABORT, 'test'); END",
    );
    var posts = 0;
    final c = controller((request) async {
      if (request.url.path == '/v1/installations') {
        return jsonResponse(issued, 201);
      }
      posts++;
      return jsonResponse({'id': jobId, 'state': 'queued'}, 202);
    });
    await c.initialize();
    await c.create(questionnaire());
    expect(posts, 0);
    expect(await store.loadOperation(config.baseUrl), isNull);
  });

  test('Retry-After deadline survives controller restart', () async {
    await seed();
    var calls = 0;
    Future<http.Response> handler(http.Request _) async {
      calls++;
      return failure(429, 'app_daily_quota_exceeded', retry: '60');
    }

    final c = controller(handler);
    await c.initialize();
    await c.recover();
    final restarted = controller(handler);
    await restarted.initialize();
    await restarted.recover();
    expect(calls, 1);
    expect(restarted.coolingDown, true);
    now = now.add(const Duration(seconds: 61));
    await restarted.recover();
    expect(calls, 2);
  });

  test(
    '202 job_id write failure keeps ID in memory and never retries POST',
    () async {
      await store.database.execute(
        "CREATE TRIGGER reject_job_id BEFORE INSERT ON operations WHEN NEW.job_id IS NOT NULL BEGIN SELECT RAISE(ABORT, 'test'); END",
      );
      var posts = 0;
      var gets = 0;
      final c = controller((request) async {
        if (request.url.path == '/v1/installations') {
          return jsonResponse(issued, 201);
        }
        if (request.method == 'GET') {
          gets++;
          return jsonResponse(completed());
        }
        posts++;
        return jsonResponse({'id': jobId, 'state': 'queued'}, 202);
      });
      c.setForeground(false);
      await c.initialize();
      await c.create(questionnaire());
      expect(c.operation!.jobId, jobId);
      expect((await store.loadOperation(config.baseUrl))!.jobId, isNull);
      await c.recover();
      expect(posts, 1);
      await store.database.execute('DROP TRIGGER reject_job_id');
      c.setForeground(true);
      await c.refresh();
      expect(posts, 1);
      expect(gets, 1);
      expect(c.operation!.phase, 'completed');
    },
  );

  test(
    'dispose prevents subsequent polling and explicit failed recreation has a new key',
    () async {
      await seed(id: jobId);
      final keys = <String>[];
      var gets = 0;
      final c = controller((request) async {
        if (request.method == 'GET') {
          gets++;
          return jsonResponse({
            ...completed(),
            'state': 'failed',
            'error_code': 'attempts_exhausted',
            'result': null,
          });
        }
        keys.add(request.headers['Idempotency-Key']!);
        return jsonResponse({'id': jobId, 'state': 'queued'}, 202);
      }, interval: const Duration(milliseconds: 5));
      c.setForeground(false);
      await c.initialize();
      c.setForeground(true);
      await c.refresh();
      expect(c.operation!.phase, 'failed');
      c.setForeground(false);
      await c.create(questionnaire());
      expect(keys.single, isNot('original-key'));
      expect(gets, 1);
      c.dispose();
      controllers.remove(c);
      c.setForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(gets, 1);
    },
  );

  test(
    'Double tap: single immutable operation committed before POST; unknown outcome preserved',
    () async {
      final gate = Completer<http.Response>();
      final entered = Completer<void>();
      var posts = 0;
      var registrations = 0;
      String? key;
      String? body;
      final c = controller((request) async {
        if (request.url.path == '/v1/installations') {
          registrations++;
          return jsonResponse(issued, 201);
        }
        posts++;
        key = request.headers['Idempotency-Key'];
        body = request.body;
        final persisted = await store.loadOperation(config.baseUrl);
        expect(persisted!.key, key);
        expect(persisted.snapshot, body);
        expect(persisted.phase, 'unknown');
        expect(persisted.firstSentAt, now);
        entered.complete();
        return gate.future;
      });
      await c.initialize();
      c.setForeground(false);
      final first = c.create(questionnaire());
      final second = c.create(questionnaire());
      await entered.future.timeout(const Duration(seconds: 5));
      expect(posts, 1);
      gate.completeError(http.ClientException('response lost'));
      await Future.wait([first, second]);
      expect(registrations, 1);
      expect(c.operation!.phase, 'unknown');
      expect(c.operation!.snapshot, body);
      expect(c.message, contains('не означает'));
      await c.create(questionnaire());
      expect(posts, 1);
      expect((await store.loadOperation(config.baseUrl))!.key, key);
    },
  );

  test(
    'Restart with unknown outcome: never auto-POST, explicit recovery uses exact key/snapshot',
    () async {
      await seed();
      final snapshot = (await store.loadOperation(config.baseUrl))!.snapshot;
      var posts = 0;
      final c = controller((request) async {
        expect(request.method, 'POST');
        expect(request.headers['Idempotency-Key'], 'original-key');
        expect(request.body, snapshot);
        expect(request.headers['Authorization'], 'Bearer ${issued['token']}');
        posts++;
        return jsonResponse({'id': jobId, 'state': 'queued'}, 202);
      });
      c.setForeground(false);
      await c.initialize();
      expect(posts, 0);
      await store.saveDraft({...draft(), 'budget': '999'});
      await c.recover();
      expect(posts, 1);
      expect((await store.loadOperation(config.baseUrl))!.jobId, jobId);
    },
  );

  test(
    'Expired, missing or backwards-clock retention blocks POST even on explicit recovery',
    () async {
      await seed(until: now.subtract(const Duration(seconds: 1)));
      var posts = 0;
      final c = controller((_) async {
        posts++;
        return jsonResponse({}, 202);
      });
      await c.initialize();
      await c.recover();
      expect(posts, 0);
      expect(c.message, contains('заблокирован'));
      final original = c.operation!;
      await store.saveOperation(
        Operation(
          server: original.server,
          key: original.key,
          snapshot: original.snapshot,
          installationId: original.installationId,
          firstSentAt: now,
        ),
      );
      await c.initialize();
      await c.recover();
      expect(posts, 0);
      await seed(first: now.add(const Duration(hours: 1)));
      await c.initialize();
      await c.recover();
      expect(posts, 0);
    },
  );

  test(
    'Secure write failure stops before operation POST and does not retry installation',
    () async {
      credentials.failWrite = true;
      var posts = 0;
      final c = controller((request) async {
        if (request.url.path == '/v1/installations') {
          return jsonResponse(issued, 201);
        }
        posts++;
        return jsonResponse({}, 202);
      });
      await c.initialize();
      await c.create(questionnaire());
      expect(posts, 0);
      expect(await store.loadOperation(config.baseUrl), isNull);
      expect(c.message, contains('сохранить токен'));
    },
  );

  test(
    'Restart with job_id: only GET; completed result persisted atomically and read offline',
    () async {
      await seed(id: jobId);
      var calls = 0;
      final c = controller((request) async {
        calls++;
        expect(request.method, 'GET');
        return jsonResponse(completed());
      });
      c.setForeground(false);
      await c.initialize();
      c.setForeground(true);
      await c.refresh();
      expect(c.operation!.phase, 'completed');
      expect(calls, 1);
      expect(c.saved.single.result.productNames['oats'], 'Овсяные хлопья');
      final offline = controller(
        (_) async => throw StateError('network forbidden'),
      );
      await offline.initialize();
      expect(offline.saved.single.result.calculation['total_cost'], 89.9);
      expect(offline.operation!.phase, 'completed');
      await offline.refresh();
      expect(calls, 1);
    },
  );

  test(
    'Polling cannot overlap; pauses in background and resumes once',
    () async {
      await seed(id: jobId);
      var calls = 0;
      var active = 0;
      var maxActive = 0;
      final firstGet = Completer<http.Response>();
      final c = controller((_) async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        final response = calls == 1
            ? await firstGet.future
            : jsonResponse({
                ...completed(),
                'state': 'running',
                'result': null,
              });
        active--;
        return response;
      }, interval: const Duration(milliseconds: 15));
      c.setForeground(false);
      await c.initialize();
      c.setForeground(true);
      final get = c.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await c.refresh();
      c.setForeground(false);
      firstGet.complete(
        jsonResponse({...completed(), 'state': 'running', 'result': null}),
      );
      await get;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      c.setForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      c.setForeground(false);
      expect(calls, 2);
      expect(maxActive, 1);
    },
  );

  test(
    'worker_unavailable is nonterminal; GET error never causes POST; backoff',
    () async {
      await seed(id: jobId);
      var gets = 0;
      final c = controller((request) async {
        expect(request.method, 'GET');
        gets++;
        return failure(503, 'worker_unavailable');
      }, interval: const Duration(milliseconds: 1));
      c.setForeground(false);
      await c.initialize();
      c.setForeground(true);
      await c.refresh();
      expect(c.operation!.phase, 'queued');
      expect(c.message, contains('не failed'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gets, 1);
    },
  );

  test(
    '401 does not re-register; 404 does not POST; failed requires explicit new operation',
    () async {
      await seed(id: jobId);
      var status = 401;
      final requests = <String>[];
      final c = controller((request) async {
        requests.add(request.method);
        return status == 200
            ? jsonResponse({
                ...completed(),
                'state': 'failed',
                'error_code': 'interrupted',
                'result': null,
              })
            : failure(status, status == 401 ? 'unauthorized' : 'job_not_found');
      });
      c.setForeground(false);
      await c.initialize();
      c.setForeground(true);
      await c.refresh();
      expect(
        c.message,
        contains('Новая установка автоматически не создаётся'),
        reason: 'No auto registration',
      );
      status = 200;
      await c.refresh();
      expect(c.operation!.phase, 'failed');
      expect(requests, ['GET', 'GET']);
      await seed(id: jobId);
      c.setForeground(false);
      await c.initialize();
      status = 404;
      c.setForeground(true);
      await c.refresh();
      expect(c.operation!.phase, 'missing');
      expect(requests, ['GET', 'GET', 'GET']);
    },
  );

  test(
    '429 honors Retry-After before explicit replay; other POST failures retain key',
    () async {
      var calls = 0;
      final keys = <String>[];
      final c = controller((request) async {
        if (request.url.path == '/v1/installations') {
          return jsonResponse(issued, 201);
        }
        calls++;
        keys.add(request.headers['Idempotency-Key']!);
        return calls == 1
            ? failure(429, 'generation_queue_full', retry: '30')
            : failure(409, 'idempotency_conflict');
      });
      await c.initialize();
      await c.create(questionnaire());
      await c.recover();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 31));
      await c.recover();
      expect(calls, 2);
      expect(keys.toSet().length, 1);
      expect(c.message, contains('другой анкетой'));
    },
  );

  test(
    'Reset is explicit, keeps saved menu and never sends old operation to another server',
    () async {
      await seed(id: jobId);
      final op = (await store.loadOperation(config.baseUrl))!;
      await store.complete(
        op,
        MenuResult.fromJson(object(completed()['result'])),
        now,
      );
      final c = controller((_) async => throw StateError('must not request'));
      await c.initialize();
      await c.resetConnection();
      expect(credentials.values, isEmpty);
      expect(c.saved.length, 1);
      expect(await store.loadOperation(config.baseUrl), isNull);
      final other = controller(
        (_) async => throw StateError('must not request'),
        server: ServerConfig('https://other.example.com'),
      );
      await other.initialize();
      expect(other.operation, isNull);
      expect(other.saved.length, 1);
    },
  );
}
