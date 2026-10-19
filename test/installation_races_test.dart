import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/local_store.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/connection/installation_service.dart';
import 'package:meal_budget_mobile/features/generation/generation_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

const _old = {
  'installation_id': '00000000-0000-4000-8000-000000000010',
  'token': 'synthetic-old-token',
  'token_type': 'Bearer',
};
const _new = {
  'installation_id': '00000000-0000-4000-8000-000000000020',
  'token': 'synthetic-new-token',
  'token_type': 'Bearer',
};

class _StorageState {
  final values = <String, String>{};
  final events = <String>[];
  int writes = 0;
  int deletes = 0;
  int reads = 0;
  int overlappingAccesses = 0;
  final _active = <String, int>{};
  void enter(String key) {
    final active = _active[key] ?? 0;
    if (active != 0) overlappingAccesses++;
    _active[key] = active + 1;
  }

  void leave(String key) {
    final active = _active[key]! - 1;
    if (active == 0) {
      _active.remove(key);
    } else {
      _active[key] = active;
    }
  }

  bool failRead = false;
  bool failDelete = false;
  bool pauseWrite = false;
  bool pauseVerification = false;
  final writeEntered = Completer<void>();
  final writeReleased = Completer<void>();
  final verificationEntered = Completer<void>();
  final verificationReleased = Completer<void>();
}

// Different wrapper objects intentionally expose the same backing namespace.
class _Credentials extends MemoryCredentials {
  _Credentials(this.state) : super(values: state.values);
  final _StorageState state;
  @override
  Future<String?> read(String key) async {
    state.enter(key);
    try {
      state.reads++;
      if (state.failRead) throw StateError('synthetic storage failure');
      if (state.pauseVerification && state.reads == 2) {
        state.verificationEntered.complete();
        await state.verificationReleased.future;
      }
      return await super.read(key);
    } finally {
      state.leave(key);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    state.enter(key);
    try {
      final sequence = ++state.writes;
      state.events.add('write-start-$sequence');
      if (state.pauseWrite && sequence == 1) {
        state.writeEntered.complete();
        await state.writeReleased.future;
      }
      await super.write(key, value);
      state.events.add('write-commit-$sequence');
    } finally {
      state.leave(key);
    }
  }

  @override
  Future<void> delete(String key) async {
    state.enter(key);
    try {
      if (state.failDelete) throw StateError('synthetic deletion failure');
      state.deletes++;
      state.events.add('delete');
      await super.delete(key);
    } finally {
      state.leave(key);
    }
  }
}

class _RegistrationCall {
  final entered = Completer<void>();
  final aborted = Completer<void>();
  final response = Completer<http.Response>();
}

class _Transport extends http.BaseClient {
  final calls = List.generate(4, (_) => _RegistrationCall());
  int registrations = 0;
  final jobTokens = <String?>[];
  final getTokens = <String?>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    http.Response response;
    if (request.url.path == '/v1/installations') {
      final call = calls[registrations++];
      unawaited(
        (request as http.Abortable).abortTrigger!.then((_) {
          if (!call.aborted.isCompleted) call.aborted.complete();
        }),
      );
      call.entered.complete();
      // Deliberately deliver a response even after the abort trigger completes.
      response = await call.response.future;
    } else if (request.method == 'POST') {
      jobTokens.add(request.headers['Authorization']);
      response = jsonResponse({'id': jobId, 'state': 'queued'}, 202);
    } else {
      getTokens.add(request.headers['Authorization']);
      response = request.headers['Authorization'] == 'Bearer ${_new['token']}'
          ? jsonResponse(completed())
          : failure(401, 'unauthorized');
    }
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

class _ResetBarrierStore extends LocalStore {
  _ResetBarrierStore(super.database);
  final clearEntered = Completer<void>();
  final clearReleased = Completer<void>();
  @override
  Future<void> clearOperation(String server) async {
    clearEntered.complete();
    await clearReleased.future;
    await super.clearOperation(server);
  }
}

void main() {
  late LocalStore store;
  late _StorageState state;
  late _Transport transport;
  final config = ServerConfig('https://race.example.com');
  final controllers = <GenerationController>[];
  final disposed = <GenerationController>{};

  GenerationController owner({ServerConfig? server}) {
    final api = ApiClient(server ?? config, transport);
    final controller = GenerationController(
      api: api,
      installations: InstallationService(api, _Credentials(state)),
      store: store,
    );
    controller.setForeground(false);
    controllers.add(controller);
    return controller;
  }

  void remove(GenerationController controller) {
    controller.dispose();
    disposed.add(controller);
  }

  Map<String, dynamic>? savedCredentials([ServerConfig? server]) {
    final value = state.values[(server ?? config).storageKey];
    return value == null ? null : jsonDecode(value) as Map<String, dynamic>;
  }

  Future<void> assertConsistent(GenerationController current) async {
    final op = await store.loadOperation(current.api.config.baseUrl);
    expect(savedCredentials(current.api.config), _new);
    expect(op!.installationId, _new['installation_id']);
    expect(op.jobId, jobId);
    expect(transport.jobTokens, ['Bearer ${_new['token']}']);
    remove(current);
    final restarted = owner(server: current.api.config);
    await restarted.initialize();
    restarted.setForeground(true);
    await restarted.refresh();
    expect(restarted.operation!.phase, 'completed');
    expect(transport.getTokens, ['Bearer ${_new['token']}']);
    expect(savedCredentials(current.api.config), _new);
    expect(state.overlappingAccesses, 0);
  }

  setUp(() async {
    sqfliteFfiInit();
    store = await LocalStore.open(
      factory: databaseFactoryFfi,
      path: inMemoryDatabasePath,
    );
    state = _StorageState();
    transport = _Transport();
  });
  tearDown(() async {
    for (final controller in controllers) {
      if (!disposed.contains(controller)) controller.dispose();
    }
    controllers.clear();
    disposed.clear();
    await store.close();
  });

  test(
    'Review reproduction: late old 201 cannot overwrite a new owner, operation or restarted GET token',
    () async {
      final first = owner();
      await first.initialize();
      final oldCreate = first.create(questionnaire());
      await transport.calls[0].entered.future;
      remove(first);
      await transport.calls[0].aborted.future;
      final second = owner();
      await second.initialize();
      final newCreate = second.create(questionnaire());
      await transport.calls[1].entered.future;
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await newCreate;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await oldCreate;
      expect(state.writes, 1);
      expect(state.deletes, 0);
      expect(transport.registrations, 2);
      await assertConsistent(second);
    },
  );

  test(
    'Late 201 after disposal without a new owner performs no storage write or generation POST',
    () async {
      final first = owner();
      await first.initialize();
      final pending = first.create(questionnaire());
      await transport.calls[0].entered.future;
      remove(first);
      await transport.calls[0].aborted.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await pending;
      expect(state.values, isEmpty);
      expect(state.writes, 0);
      expect(state.deletes, 0);
      expect(transport.jobTokens, isEmpty);
      expect(await store.loadOperation(config.baseUrl), isNull);
    },
  );

  test(
    'Abort without disposing the service fences a transport ignoring cancellation before write',
    () async {
      final api = ApiClient(config, transport);
      final service = InstallationService(api, _Credentials(state));
      final abort = Completer<void>();
      final pending = service.ensure(abort: abort.future);
      final rejected = expectLater(pending, throwsA(isA<ConnectionFailure>()));
      await transport.calls[0].entered.future;
      abort.complete();
      await transport.calls[0].aborted.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await rejected;
      expect(state.values, isEmpty);
      expect(state.writes, 0);
    },
  );

  test(
    'Owner replacement while an uncancellable secure write is in progress is ordered before new admission',
    () async {
      state.pauseWrite = true;
      final first = owner();
      await first.initialize();
      final oldCreate = first.create(questionnaire());
      await transport.calls[0].entered.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await state.writeEntered.future;
      remove(first);
      final second = owner();
      await second.initialize();
      final newCreate = second.create(questionnaire());
      expect(transport.registrations, 1);
      state.writeReleased.complete();
      await transport.calls[1].entered.future;
      expect(state.values, isEmpty);
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await Future.wait([oldCreate, newCreate]);
      expect(state.events, [
        'write-start-1',
        'write-commit-1',
        'delete',
        'write-start-2',
        'write-commit-2',
      ]);
      await assertConsistent(second);
    },
  );

  test(
    'Cancellation during verification is fenced inside the same storage critical section',
    () async {
      state.pauseVerification = true;
      final first = owner();
      await first.initialize();
      final oldCreate = first.create(questionnaire());
      await transport.calls[0].entered.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await state.verificationEntered.future;
      remove(first);
      final second = owner();
      await second.initialize();
      final newCreate = second.create(questionnaire());
      state.verificationReleased.complete();
      await transport.calls[1].entered.future;
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await Future.wait([oldCreate, newCreate]);
      expect(state.deletes, 1);
      await assertConsistent(second);
    },
  );

  test(
    'Explicit reset during registration revokes the old flight without clearing a newer flight or busy state',
    () async {
      final current = owner();
      await current.initialize();
      final oldCreate = current.create(questionnaire());
      await transport.calls[0].entered.future;
      await current.resetConnection();
      expect(current.busy, false);
      expect(state.values, isEmpty);
      final newCreate = current.create(questionnaire());
      await transport.calls[1].entered.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await oldCreate;
      expect(current.busy, true);
      final joined = current.installations.ensure();
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await newCreate;
      expect((await joined).id, _new['installation_id']);
      expect(transport.registrations, 2);
      expect(state.writes, 1);
      await assertConsistent(current);
    },
  );

  test(
    'Explicit reset and SQLite cleanup stay ahead of a new owner after delayed storage write',
    () async {
      final barrierStore = _ResetBarrierStore(store.database);
      store = barrierStore;
      state.pauseWrite = true;
      final first = owner();
      await first.initialize();
      final oldCreate = first.create(questionnaire());
      await transport.calls[0].entered.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await state.writeEntered.future;
      final reset = first.resetConnection();
      final second = owner();
      await second.initialize();
      final newCreate = second.create(questionnaire());
      state.writeReleased.complete();
      await barrierStore.clearEntered.future;
      expect(transport.registrations, 1);
      expect(state.values, isEmpty);
      remove(first);
      barrierStore.clearReleased.complete();
      await reset;
      await transport.calls[1].entered.future;
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await Future.wait([oldCreate, newCreate]);
      await assertConsistent(second);
    },
  );

  test(
    'Reset by another service invalidates the old registration, not only local instance counters',
    () async {
      final api = ApiClient(config, transport);
      final oldService = InstallationService(api, _Credentials(state));
      final pending = oldService.ensure();
      final rejected = expectLater(pending, throwsA(isA<ConnectionFailure>()));
      await transport.calls[0].entered.future;
      await InstallationService(api, _Credentials(state)).reset();
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await rejected;
      expect(state.values, isEmpty);
      expect(state.writes, 0);
    },
  );

  test(
    'Different backend addresses do not share fences, storage barriers or cleanup keys',
    () async {
      state.pauseWrite = true;
      final other = ServerConfig('https://other-race.example.com');
      final first = owner();
      await first.initialize();
      final oldCreate = first.create(questionnaire());
      await transport.calls[0].entered.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await state.writeEntered.future;
      remove(first);
      final second = owner(server: other);
      await second.initialize();
      final newCreate = second.create(questionnaire());
      await transport.calls[1].entered.future;
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await newCreate; // Must not wait for the old backend's blocked write.
      expect(savedCredentials(other), _new);
      state.writeReleased.complete();
      await oldCreate;
      expect(savedCredentials(), isNull);
      await assertConsistent(second);
    },
  );

  test(
    'Normal registration is durable across owners and reuses the stored installation without registration',
    () async {
      final first = owner();
      await first.initialize();
      final create = first.create(questionnaire());
      await transport.calls[0].entered.future;
      transport.calls[0].response.complete(jsonResponse(_new, 201));
      await create;
      await assertConsistent(first);
      expect(transport.registrations, 1);
      expect(state.writes, 1);
      expect(state.deletes, 0);
    },
  );

  test(
    'A read failure blocks other instances too without automatic deletion or re-registration',
    () async {
      state.failRead = true;
      final api = ApiClient(config, transport);
      await expectLater(
        InstallationService(api, _Credentials(state)).ensure(),
        throwsA(isA<ConnectionFailure>()),
      );
      state.failRead = false;
      await expectLater(
        InstallationService(api, _Credentials(state)).ensure(),
        throwsA(isA<ConnectionFailure>()),
      );
      expect(transport.registrations, 0);
      expect(state.deletes, 0);
      expect(state.writes, 0);
    },
  );

  test(
    'Failed cleanup of an uncommitted cancelled write blocks all owners until explicit reset succeeds',
    () async {
      state.pauseWrite = true;
      state.failDelete = true;
      final first = owner();
      await first.initialize();
      final oldCreate = first.create(questionnaire());
      await transport.calls[0].entered.future;
      transport.calls[0].response.complete(jsonResponse(_old, 201));
      await state.writeEntered.future;
      remove(first);
      final second = owner();
      await second.initialize();
      final newCreate = second.create(questionnaire());
      state.writeReleased.complete();
      await Future.wait([oldCreate, newCreate]);
      expect(transport.registrations, 1);
      expect(transport.jobTokens, isEmpty);
      expect(second.message, contains('Защищённое хранилище недоступно'));
      state.failDelete = false;
      await second.resetConnection();
      final retried = second.create(questionnaire());
      await transport.calls[1].entered.future;
      transport.calls[1].response.complete(jsonResponse(_new, 201));
      await retried;
      await assertConsistent(second);
    },
  );
}
