import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:meal_budget_mobile/app.dart';
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/local_store.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/connection/installation_service.dart';
import 'package:meal_budget_mobile/features/generation/generation_controller.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:meal_budget_mobile/features/menus/menu_view.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support.dart';

void main() {
  testWidgets(
    'Russian questionnaire; no registration on build; readable with large font',
    (tester) async {
      sqfliteFfiInit();
      final store = await tester.runAsync(
        () => LocalStore.open(
          factory: databaseFactoryFfi,
          path: inMemoryDatabasePath,
        ),
      );
      var calls = 0;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final api = ApiClient(
        ServerConfig('https://example.com'),
        MockClient((_) async {
          calls++;
          return jsonResponse(issued, 201);
        }),
      );
      final controller = GenerationController(
        api: api,
        installations: InstallationService(api, MemoryCredentials()),
        store: store!,
      );
      await tester.runAsync(controller.initialize);
      await tester.pumpWidget(MealBudgetApp(controller: controller));
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(find.text('3 дня'), findsOneWidget);
      expect(find.text('7 дней'), findsOneWidget);
      expect(find.byKey(const ValueKey('budget')), findsOneWidget);
      expect(calls, 0);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(HomeScreen)),
        ).scale(10),
        20,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(store.close);
    },
  );

  testWidgets(
    'Offline result shows full recipe vs portion, server nutrition, cost and demo warning',
    (tester) async {
      final menu = SavedMenu(
        id: 'test',
        server: 'https://example.com',
        createdAt: DateTime.utc(2026),
        result: MenuResult.fromJson(object(completed()['result'])),
      );
      tester.view.physicalSize = const Size(1080, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: MenuView(menu: menu),
          ),
        ),
      );
      expect(find.text('Покупки: 89,90 ₽'), findsOneWidget);
      expect(find.textContaining('demo_unverified'), findsOneWidget);
      expect(
        find.textContaining('В этом приёме: 1 порц. из 2 порц.'),
        findsWidgets,
      );
      await tester.ensureVisible(find.byType(ExpansionTile).first);
      await tester.tap(find.byType(ExpansionTile).first);
      await tester.pumpAndSettle();
      expect(find.text('Полный рецепт — выход 2 порц.'), findsOneWidget);
      expect(find.text('Овсяные хлопья — 100 г'), findsOneWidget);
      expect(find.textContaining('Заявленное время: 10 мин'), findsOneWidget);
      expect(find.textContaining('185 ккал'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
