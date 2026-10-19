import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/connection/installation_service.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Secure wrappers share a physical namespace, not an object or cipher/reset identity',
    () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final first = SecureCredentials();
      expect(
        first.coordinationNamespace,
        SecureCredentials().coordinationNamespace,
      );
      expect(
        first.coordinationNamespace,
        SecureCredentials(const FlutterSecureStorage()).coordinationNamespace,
      );
      expect(
        first.coordinationNamespace,
        SecureCredentials(
          const FlutterSecureStorage(
            aOptions: AndroidOptions(
              storageNamespace: 'FlutterSecureStorage',
              preferencesKeyPrefix: 'other-prefix',
            ),
          ),
        ).coordinationNamespace,
      );
      expect(
        first.coordinationNamespace,
        isNot(
          SecureCredentials(
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                storageNamespace: 'another-test-namespace',
              ),
            ),
          ).coordinationNamespace,
        ),
      );
    },
  );

  test(
    'Every credential operation disables Android auto-reset, including injected storage',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final methods = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            methods.add(call.method);
            final options = (call.arguments as Map)['options'] as Map;
            expect(options['resetOnError'], 'false');
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      expect(
        SecureCredentials().storage.aOptions.toMap()['resetOnError'],
        'false',
      );
      for (final credentials in [
        SecureCredentials(),
        SecureCredentials(const FlutterSecureStorage()),
      ]) {
        await credentials.read('synthetic-key');
        await credentials.write('synthetic-key', 'synthetic-value');
        await credentials.delete('synthetic-key');
      }
      expect(methods, ['read', 'write', 'delete', 'read', 'write', 'delete']);
    },
  );

  test(
    'Lazy registration, parallel ensure deduplicated, reuse across restart',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final api = ApiClient(
        ServerConfig('https://example.com'),
        MockClient((request) async {
          calls++;
          expect(request.url.path, '/v1/installations');
          await gate.future;
          return jsonResponse(issued, 201);
        }),
      );
      final storage = MemoryCredentials();
      final service = InstallationService(api, storage);
      expect(calls, 0);
      final a = service.ensure();
      final b = service.ensure();
      gate.complete();
      expect((await a).id, (await b).id);
      await service.ensure();
      await InstallationService(api, storage).ensure();
      expect(calls, 1);
    },
  );

  for (final readFailure in [true, false]) {
    test(
      'Secure storage ${readFailure ? 'read' : 'write'} error blocks registration/generation retries',
      () async {
        var calls = 0;
        final api = ApiClient(
          ServerConfig('https://example.com'),
          MockClient((_) async {
            calls++;
            return jsonResponse(issued, 201);
          }),
        );
        final storage = MemoryCredentials()
          ..failRead = readFailure
          ..failWrite = !readFailure;
        final service = InstallationService(api, storage);
        await expectLater(service.ensure(), throwsA(isA<ConnectionFailure>()));
        await expectLater(service.ensure(), throwsA(isA<ConnectionFailure>()));
        expect(calls, readFailure ? 0 : 1);
      },
    );
  }

  test(
    'SecureCredentials uses platform storage, platform exception is fail-closed',
    () async {
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (_) async => throw PlatformException(code: 'locked'),
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final api = ApiClient(
        ServerConfig('https://example.com'),
        MockClient((_) async => throw StateError('must not register')),
      );
      await expectLater(
        InstallationService(api, SecureCredentials()).ensure(),
        throwsA(isA<ConnectionFailure>()),
      );
    },
  );

  test('Changing servers cannot send previous credentials', () async {
    final storage = MemoryCredentials();
    final firstApi = ApiClient(
      ServerConfig('https://first.example.com'),
      MockClient((_) async => jsonResponse(issued, 201)),
    );
    await InstallationService(firstApi, storage).ensure();
    final secondApi = ApiClient(
      ServerConfig('https://second.example.com'),
      MockClient((request) async {
        expect(request.headers, isNot(contains('Authorization')));
        return jsonResponse({...issued, 'token': 'other-test-token'}, 201);
      }),
    );
    final second = InstallationService(secondApi, storage);
    expect(await second.existing(), isNull);
    expect((await second.ensure()).token, 'other-test-token');
    expect(storage.values.length, 2);
  });
}
