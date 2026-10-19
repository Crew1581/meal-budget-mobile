import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'features/generation/generation_controller.dart';
import 'features/menus/menu.dart';
import 'features/menus/menu_view.dart';
import 'features/questionnaire/questionnaire_form.dart';

class MealBudgetApp extends StatelessWidget {
  /// Transfers ownership of [controller] to the root [HomeScreen].
  /// Callers must not dispose it after the screen has been mounted.
  const MealBudgetApp({super.key, required this.controller});
  final GenerationController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Meal Budget',
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff376a4f)),
    ),
    home: HomeScreen(controller: controller),
  );
}

class HomeScreen extends StatefulWidget {
  /// Owns [controller] until this screen is permanently removed from the tree.
  const HomeScreen({super.key, required this.controller});
  final GenerationController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int _tab = 0;
  GenerationController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncLifecycle();
  }

  void _syncLifecycle() {
    final state = WidgetsBinding.instance.lifecycleState;
    controller.setForeground(
      state == null || state == AppLifecycleState.resumed,
    );
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller)) {
      oldWidget.controller.dispose();
      _syncLifecycle();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      controller.setForeground(state == AppLifecycleState.resumed);

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(text)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Оставить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Подтвердить'),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Meal Budget'),
        actions: [
          IconButton(
            tooltip: 'Подключение',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () async {
              final confirmed = await _confirm(
                'Сбросить подключение?',
                'Сервер: ${controller.api.config.baseUrl}\n\nЛокальный токен и связь с незавершённым заданием будут удалены. Доступ к прежним серверным заданиям потеряется, но генерация на сервере не отменится. Локальные меню останутся.\n\nВосстановление или удаление токена после переустановки зависит от ОС и backup, гарантий нет.',
              );
              if (confirmed) await controller.resetConnection();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _tab,
          children: [
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _OperationCard(
                  controller: controller,
                  onForget: () async {
                    if (await _confirm(
                      'Отвязать прежнюю операцию?',
                      'Это не отменяет генерацию на сервере. При неизвестном исходе или истёкшем ключе новое создание может привести к дублирующему платному заданию. Сначала проверьте состояние у оператора. Прежняя операция не будет автоматически отправлена заново.',
                    )) {
                      await controller.forgetUnresolved();
                    }
                  },
                ),
                QuestionnaireForm(
                  store: controller.store,
                  controller: controller,
                ),
              ],
            ),
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (controller.saved.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Сохранённых меню пока нет. Успешный результат появится здесь автоматически.',
                    ),
                  ),
                for (final menu in controller.saved)
                  Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ListTile(
                          isThreeLine: true,
                          title: Text(
                            'Меню на ${menu.result.days.length} дн. · ${rubles(menu.result.calculation['total_cost'])}',
                          ),
                          subtitle: Text(
                            'Сохранено ${_date(menu.createdAt)}\nДоступно без сети',
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => MenuView(menu: menu),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Удалить с устройства'),
                            onPressed: () async {
                              if (await _confirm(
                                'Удалить локальное меню?',
                                'Удаляется только эта копия меню на устройстве. Серверное задание не меняется.',
                              )) {
                                await controller.deleteMenu(menu);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (value) => setState(() => _tab = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.edit_note),
            label: 'Новое меню',
          ),
          NavigationDestination(
            icon: Icon(Icons.bookmarks_outlined),
            label: 'Сохранённые',
          ),
        ],
      ),
    ),
  );

  static String _date(DateTime date) =>
      '${date.toLocal().day}.${date.toLocal().month}.${date.toLocal().year}';
}

class _OperationCard extends StatelessWidget {
  const _OperationCard({required this.controller, required this.onForget});
  final GenerationController controller;
  final VoidCallback onForget;
  @override
  Widget build(BuildContext context) {
    final operation = controller.operation;
    if (operation == null && controller.message == null && !controller.busy) {
      return const SizedBox.shrink();
    }
    final phase = operation?.phase;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              controller.busy
                  ? 'Отправка…'
                  : switch (phase) {
                      'queued' => 'В очереди',
                      'running' => 'Меню готовится',
                      'completed' => 'Меню сохранено',
                      'failed' => 'Генерация не завершилась успешно',
                      'missing' => 'Задание недоступно',
                      'unknown' => 'Исход отправки неизвестен',
                      'saving' => 'Подтверждение приёма ещё не сохранено',
                      _ => 'Подключение',
                    },
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (controller.message != null) Text(controller.message!),
            if (controller.retryNotBefore != null)
              Text(
                'Повтор не раньше ${controller.retryNotBefore!.toLocal()} (Retry-After сервера).',
              ),
            if (controller.waiting) ...[
              const Text(
                'Процент выполнения сервер не сообщает. Выход с экрана не отменяет серверное задание.',
              ),
              TextButton(
                onPressed: controller.getting || controller.busy
                    ? null
                    : controller.refresh,
                child: const Text('Проверить состояние'),
              ),
            ],
            if (phase == 'saving')
              TextButton(
                onPressed: controller.getting || controller.busy
                    ? null
                    : controller.refresh,
                child: const Text('Сохранить подтверждение и проверить'),
              ),
            if (phase == 'unknown') ...[
              Text(
                controller.canRecover
                    ? 'Доступно восстановление с прежними ключом и снимком в подтверждённом сроке.'
                    : 'Безопасный срок повтора не известен или истёк. POST для восстановления заблокирован; новый ключ может создать дубликат.',
              ),
              TextButton(
                onPressed: controller.busy ? null : controller.recover,
                child: const Text('Восстановить прежнюю отправку'),
              ),
              TextButton(
                onPressed: controller.busy ? null : onForget,
                child: const Text('Отвязать операцию для нового меню…'),
              ),
            ],
            if (phase == 'completed')
              const Text('Откройте меню на вкладке «Сохранённые».'),
          ],
        ),
      ),
    );
  }
}
