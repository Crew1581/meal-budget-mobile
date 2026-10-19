import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app.dart';
import 'core/api_client.dart';
import 'core/local_store.dart';
import 'core/server_config.dart';
import 'features/connection/installation_service.dart';
import 'features/generation/generation_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GenerationController? controller;
  try {
    const retention = int.fromEnvironment('API_MIN_RETENTION_SECONDS');
    final config = ServerConfig(
      const String.fromEnvironment(
        'API_BASE_URL',
        defaultValue: 'http://10.0.2.2:8000',
      ),
      minimumRetention: retention > 0
          ? const Duration(seconds: retention)
          : null,
    );
    final api = ApiClient(config, http.Client());
    final store = await LocalStore.open();
    controller = GenerationController(
      api: api,
      installations: InstallationService(api, SecureCredentials()),
      store: store,
    );
    controller.setForeground(
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    await controller.initialize();
    runApp(MealBudgetApp(controller: controller));
  } catch (_) {
    // Before mounting there is no HomeScreen to take ownership.
    controller?.dispose();
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Не удалось открыть приложение. Проверьте локальное хранилище и API_BASE_URL. Для release требуется HTTPS; HTTP доступен только локально в debug. Данные автоматически не удаляются.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
