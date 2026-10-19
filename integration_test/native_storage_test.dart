import 'dart:convert';
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
import 'package:meal_budget_mobile/features/questionnaire/questionnaire.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Native credential corruption survives process restart without registration',
    (tester) async {
      if (!Platform.isAndroid ||
          !const bool.fromEnvironment('NATIVE_STORAGE_REGRESSION')) {
        fail(
          'Только Android в отдельном синтетическом AVD через native_storage_regression.py.',
        );
      }
      final path = '${await getDatabasesPath()}/meal10_native_regression';
      final marker = File('$path.phase');
      final verify = await marker.exists();
      final config = ServerConfig('http://10.0.2.2:8765');
      final client = http.Client();
      final api = ApiClient(config, client);
      final store = await LocalStore.open(path: '$path.db');
      final installations = InstallationService(api, SecureCredentials());
      final controller = GenerationController(
        api: api,
        installations: installations,
        store: store,
      );
      await controller.initialize();
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      await tester.pumpAndSettle();
      if (!verify) {
        await installations.ensure();
        await marker.writeAsString('synthetic-seeded', flush: true);
      } else {
        final request = Questionnaire.fromDraft({
          'days': '3',
          'budget': '200,50',
          'calories_kcal': '185',
          'protein_g': '6,5',
          'fat_g': '3,5',
          'carbs_g': '31',
          'meals_per_day': '1',
          'max_cooking_minutes': '20',
          'price_region': 'Тестовый регион',
          'wishes': '',
        });
        await controller.create(request);
        await tester.pumpAndSettle();
        expect(
          controller.message,
          'Не удалось прочитать токен из защищённого хранилища. Новая установка не создана.',
        );
        expect(
          find.textContaining('Не удалось прочитать токен'),
          findsOneWidget,
        );
        await controller.create(request);
        expect(controller.operation, isNull);
      }
      final stats =
          jsonDecode((await client.get(config.endpoint('/test/stats'))).body)
              as Map;
      expect(stats['registrations'], 1);
      expect(stats['generation_posts'], 0);
      await tester.pumpWidget(
        const SizedBox(),
      ); // The owner disposes the controller.
      await store.close();
      client.close();
    },
  );
}
