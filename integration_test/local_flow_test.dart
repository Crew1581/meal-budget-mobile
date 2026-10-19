import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:meal_budget_mobile/app.dart';
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/local_store.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/connection/installation_service.dart';
import 'package:meal_budget_mobile/features/generation/generation_controller.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:meal_budget_mobile/features/menus/menu_view.dart';
import 'package:sqflite/sqflite.dart';

class _TestCredentials implements CredentialStore {
  _TestCredentials(this.prefix);
  final String prefix;
  final delegate = SecureCredentials();
  @override
  Object get coordinationNamespace => (delegate.coordinationNamespace, prefix);
  @override
  Future<String?> read(String key) => delegate.read('$prefix$key');
  @override
  Future<void> write(String key, String value) =>
      delegate.write('$prefix$key', value);
  @override
  Future<void> delete(String key) => delegate.delete('$prefix$key');
}

class _RecordingClient extends http.BaseClient {
  final delegate = http.Client();
  bool offline = false;
  int registrations = 0;
  int posts = 0;
  int gets = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (offline) throw const SocketException('Synthetic offline test');
    if (request.url.path == '/v1/installations') registrations++;
    if (request.url.path.startsWith('/v1/app/generation-jobs')) {
      if (request.method == 'POST') posts++;
      if (request.method == 'GET') gets++;
    }
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Local provider: form → installation → POST → GET → SQLite → offline reopen → delete',
    (tester) async {
      if (!const bool.fromEnvironment('LOCAL_E2E')) {
        fail(
          'Только явный LOCAL_E2E=true с локальным синтетическим провайдером.',
        );
      }
      final config = ServerConfig(
        const String.fromEnvironment(
          'API_BASE_URL',
          defaultValue: 'http://10.0.2.2:8000',
        ),
        minimumRetention: const Duration(hours: 24),
      );
      if (![
        '10.0.2.2',
        '127.0.0.1',
        'localhost',
      ].contains(Uri.parse(config.baseUrl).host)) {
        fail('E2E запрещён для внешнего сервера.');
      }
      final run = DateTime.now().microsecondsSinceEpoch;
      final credentials = _TestCredentials('meal10_e2e_${run}_');
      final path = '${await getDatabasesPath()}/meal10_e2e_$run.db';
      var store = await LocalStore.open(path: path);
      final transport = _RecordingClient();
      final api = ApiClient(config, transport);
      var controller = GenerationController(
        api: api,
        installations: InstallationService(api, credentials),
        store: store,
        pollInterval: const Duration(milliseconds: 250),
      );
      await controller.initialize();
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      await tester.pumpAndSettle();

      final inputs = {
        'budget': '200,50',
        'calories_kcal': '370',
        'protein_g': '13',
        'fat_g': '7',
        'carbs_g': '62',
        'meals_per_day': '1',
        'max_cooking_minutes': '20',
        'price_region': 'Москва',
        'wishes': 'Технический синтетический тест, не рекомендация.',
      };
      for (final entry in inputs.entries) {
        final field = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(field);
        await tester.enterText(field, entry.value);
        await tester.pump();
      }
      FocusManager.instance.primaryFocus?.unfocus();
      final submit = find.widgetWithText(FilledButton, 'Создать меню');
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      // Real platform storage, HTTP and backend worker. No fixed successful response.
      for (var i = 0; i < 120 && controller.saved.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (controller.operation?.phase == 'failed') {
          fail(
            'Локальный провайдер не прошёл проверки: ${controller.operation?.errorCode}',
          );
        }
      }
      expect(controller.saved.length, 1, reason: controller.message);
      expect(transport.registrations, 1);
      expect(transport.posts, 1);
      expect(transport.gets, greaterThan(0));
      expect(controller.saved.single.result.days.length, 3);
      expect(
        rubles(controller.saved.single.result.calculation['total_cost']),
        '89,90 ₽',
      );
      expect(
        controller.saved.single.result.calculation['budget_remaining'],
        110.6,
      );
      final installation = await controller.installations.existing();

      await tester.tap(find.text('Сохранённые'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Меню на 3 дн.'));
      await tester.pumpAndSettle();
      expect(find.byType(MenuView), findsOneWidget);
      expect(find.textContaining('demo_unverified'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await store.close();

      // Simulate app reconstruction with all further network access rejected.
      transport.offline = true;
      store = await LocalStore.open(path: path);
      controller = GenerationController(
        api: api,
        installations: InstallationService(api, credentials),
        store: store,
      );
      await controller.initialize();
      expect((await controller.installations.existing())!.id, installation!.id);
      expect(
        controller.saved.single.result.productNames.values,
        contains('Овсяные хлопья'),
      );
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранённые'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Меню на 3 дн.'));
      await tester.pumpAndSettle();
      expect(find.text('Покупки: 89,90 ₽'), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить с устройства'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подтвердить'));
      await tester.pumpAndSettle();
      expect(controller.saved, isEmpty);
      expect(transport.posts, 1);
      await tester.pumpWidget(const SizedBox());
      await store.close();
      transport.close();
      await credentials.delete(config.storageKey);
      await deleteDatabase(
        path,
      ); // Only this test's unique database, never user storage.
    },
  );
}
