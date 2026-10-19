import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import '../../core/local_store.dart';
import '../connection/installation_service.dart';
import '../menus/menu.dart';
import '../questionnaire/questionnaire.dart';
import 'operation.dart';

class GenerationController extends ChangeNotifier {
  GenerationController({
    required this.api,
    required this.installations,
    required this.store,
    DateTime Function()? clock,
    this.pollInterval = const Duration(seconds: 2),
  }) : clock = clock ?? (() => DateTime.now().toUtc());

  final ApiClient api;
  final InstallationService installations;
  final LocalStore store;
  final DateTime Function() clock;
  final Duration pollInterval;
  Operation? operation;
  List<SavedMenu> saved = [];
  String? message;
  DateTime? retryNotBefore;
  bool busy = false;
  bool _getting = false;
  bool _foreground = true;
  bool _disposed = false;
  bool _pollStopped = false;
  bool _storageReady = false;
  int _errors = 0;
  Timer? _timer;
  Completer<void>? _getAbort;
  var _lifetimeAbort = Completer<void>();
  int _connectionEpoch = 0;
  bool _registering = false;
  bool _resetting = false;

  bool _currentConnection(int epoch) => !_disposed && epoch == _connectionEpoch;

  bool get getting => _getting;
  bool get canRecover => operation?.canReplay(clock()) == true;
  bool get waiting =>
      operation?.jobId != null &&
      operation?.terminal == false &&
      operation?.phase != 'saving';
  bool get coolingDown =>
      retryNotBefore != null && clock().isBefore(retryNotBefore!);

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (_disposed) return;
    _storageReady = false;
    try {
      saved = await store.menus();
      if (_disposed) return;
      operation = await store.loadOperation(api.config.baseUrl);
      if (_disposed) return;
      retryNotBefore = operation?.nextAttemptAt;
      _storageReady = true;
      if (waiting) _schedule(Duration.zero);
      if (operation != null &&
          operation!.jobId == null &&
          !operation!.terminal) {
        message =
            'Исход прежней отправки неизвестен. Автоматический POST не выполняется. Восстановление использует прежние ключ и снимок.';
      }
    } catch (_) {
      if (_disposed) return;
      message =
          'Не удалось прочитать локальные данные. Новую генерацию не отправляйте до восстановления хранилища.';
    }
    _emit();
  }

  String _key() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> create(Questionnaire questionnaire) async {
    if (!_storageReady ||
        busy ||
        _disposed ||
        coolingDown ||
        (operation != null && !operation!.terminal)) {
      return;
    }
    busy = true;
    _registering = true;
    final epoch = _connectionEpoch;
    message = null;
    _emit();
    try {
      final installation = await installations.ensure(
        abort: _lifetimeAbort.future,
      );
      if (!_currentConnection(epoch)) return;
      _registering = false;
      final now = clock();
      final retention = api.config.minimumRetention;
      final candidate = Operation(
        server: api.config.baseUrl,
        key: _key(),
        snapshot: jsonEncode(questionnaire.json),
        installationId: installation.id,
        firstSentAt: now,
        // Deployment-confirmed lower bound, not the backend's undocumented default.
        retryUntil: retention != null && retention > const Duration(minutes: 1)
            ? now.add(retention - const Duration(minutes: 1))
            : null,
      );
      // One SQLite transaction commits the immutable snapshot, key and state before POST.
      await store.saveOperation(candidate);
      if (!_currentConnection(epoch)) return;
      operation = candidate;
      await _post(installation);
    } catch (error) {
      if (_currentConnection(epoch)) await _report(error);
    } finally {
      if (_currentConnection(epoch)) {
        _registering = false;
        busy = false;
        _emit();
        _schedule(Duration.zero);
      }
    }
  }

  Future<void> recover() async {
    if (busy || _disposed || coolingDown) return;
    if (!canRecover) {
      message =
          'Безопасный срок повтора неизвестен или истёк. POST заблокирован: даже прежний ключ может создать новое платное задание. Проверьте сервер у оператора; новое меню — только отдельным явным действием.';
      _emit();
      return;
    }
    busy = true;
    message = null;
    _emit();
    try {
      final installation = await _owner();
      if (_disposed) return;
      // Do not allow a storage/keychain delay to cross the replay deadline.
      if (!canRecover) {
        throw const ConnectionFailure(
          'Срок безопасного повтора истёк. POST не отправлен.',
        );
      }
      await _post(installation);
    } catch (error) {
      await _report(error);
    } finally {
      busy = false;
      _emit();
      _schedule(Duration.zero);
    }
  }

  Future<Installation> _owner() async {
    final installation = await installations.existing();
    if (installation == null ||
        installation.id != operation!.installationId ||
        operation!.server != api.config.baseUrl) {
      throw const ConnectionFailure(
        'Токен этой операции недоступен. Новая установка автоматически не создаётся.',
      );
    }
    return installation;
  }

  Future<void> _post(Installation installation) async {
    final current = operation!;
    final response = await api.request(
      'POST',
      '/v1/app/generation-jobs',
      token: installation.token,
      key: current.key,
      body: current.snapshot,
      abort: _lifetimeAbort.future,
      expected: 202,
    );
    if (_disposed) return;
    if (response['id'] is! String || response['state'] != 'queued') {
      throw const ApiFailure(0, 'protocol');
    }
    // Keep job_id in memory even if SQLite fails; never replace this with another POST.
    final accepted = current.copy(
      jobId: response['id'] as String,
      phase: 'queued',
    );
    operation = accepted.copy(phase: 'saving');
    await store.saveOperation(accepted);
    if (_disposed) return;
    operation = accepted;
    _pollStopped = false;
    _errors = 0;
  }

  Future<void> _report(Object error) async {
    if (_disposed) return;
    if (error is ApiFailure) {
      message = error.message;
      if (error.retryAfter != null) {
        retryNotBefore = clock().add(error.retryAfter!);
        if (operation != null) {
          operation = operation!.copy(nextAttemptAt: retryNotBefore);
          try {
            await store.saveOperation(operation!);
          } catch (_) {
            message = '${error.message} Не удалось сохранить паузу локально.';
          }
        }
      }
    } else if (error is ConnectionFailure) {
      message = error.message;
    } else {
      message =
          'Не удалось сохранить или прочитать данные. Операция сохранена, если транзакция успела завершиться. Не создавайте новое меню для обхода ошибки; попробуйте восстановление.';
    }
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (_disposed ||
        !_foreground ||
        !waiting ||
        _pollStopped ||
        _getting ||
        busy) {
      return;
    }
    _timer = Timer(delay, refresh);
  }

  Future<void> refresh() async {
    if (_disposed ||
        !_foreground ||
        (!waiting && operation?.phase != 'saving') ||
        _getting ||
        busy) {
      return;
    }
    _timer?.cancel();
    if (coolingDown) {
      _schedule(retryNotBefore!.difference(clock()));
      return;
    }
    _getting = true;
    _getAbort = Completer<void>();
    _pollStopped = false;
    _emit();
    var nextDelay = pollInterval;
    try {
      // Also retries saving a job_id received before a previous local write failure.
      final persisted = operation!.phase == 'saving'
          ? operation!.copy(phase: 'queued')
          : operation!;
      await store.saveOperation(persisted);
      if (_disposed) return;
      operation = persisted;
      final installation = await _owner();
      if (_disposed || !_foreground) return;
      final job = await api.request(
        'GET',
        '/v1/app/generation-jobs/${Uri.encodeComponent(operation!.jobId!)}',
        token: installation.token,
        abort: _getAbort!.future,
        expected: 200,
      );
      if (_disposed) return;
      final state = job['state'];
      if (job['id'] != operation!.jobId ||
          !['queued', 'running', 'completed', 'failed'].contains(state)) {
        throw const ApiFailure(0, 'protocol');
      }
      if (state == 'completed') {
        final result = MenuResult.fromJson(object(job['result']));
        await store.complete(operation!, result, clock());
        // An already-started transaction may commit; disposal does not undo it.
        if (_disposed) return;
        operation = operation!.copy(phase: 'completed');
        saved = await store.menus();
        if (_disposed) return;
        message = 'Меню сохранено на устройстве и доступно без сети.';
      } else {
        final updated = operation!.copy(
          phase: state as String,
          errorCode: job['error_code'] as String?,
        );
        await store.saveOperation(updated);
        if (_disposed) return;
        operation = updated;
        message = state == 'failed'
            ? 'Генерация завершилась без меню (${_failedMessage(updated.errorCode)}). Новая операция запускается только кнопкой «Создать меню».'
            : null;
      }
      _errors = 0;
      retryNotBefore = null;
    } catch (error) {
      if (_disposed) return;
      await _report(error);
      if (_disposed) return;
      if (error is ApiFailure && error.transient) {
        _errors = min(_errors + 1, 4);
        nextDelay = Duration(seconds: min(2 * (1 << _errors), 30));
        if (error.retryAfter != null && error.retryAfter! > nextDelay) {
          nextDelay = error.retryAfter!;
        }
      } else {
        _pollStopped = true;
        if (error is ApiFailure && error.status == 404) {
          final missing = operation!.copy(phase: 'missing');
          try {
            await store.saveOperation(missing);
            operation = missing;
          } catch (_) {
            /* Preserve original operation. */
          }
        }
      }
    } finally {
      _getAbort = null;
      _getting = false;
      _emit();
      _schedule(nextDelay);
    }
  }

  static String _failedMessage(String? code) => switch (code) {
    'attempts_exhausted' => 'не удалось подобрать меню с указанными условиями',
    'interrupted' => 'работа сервера прервана, расходы уже могли возникнуть',
    'catalog_version_mismatch' => 'каталог на сервере изменился',
    'provider_timeout' || 'generation_timeout' => 'истекло время ожидания',
    'catalog_unavailable' => 'каталог недоступен',
    _ => 'сервер сообщил об ошибке генерации',
  };

  void setForeground(bool foreground) {
    if (_disposed) return;
    _foreground = foreground;
    _timer?.cancel();
    if (!foreground) _abortGet();
    if (foreground && !_pollStopped) _schedule(Duration.zero);
  }

  void _abortGet() {
    if (_getAbort != null && !_getAbort!.isCompleted) _getAbort!.complete();
  }

  Future<void> forgetUnresolved() async {
    if (_disposed || busy || _getting) return;
    busy = true;
    _timer?.cancel();
    try {
      await store.clearOperation(api.config.baseUrl);
      operation = null;
      message =
          'Локальная связь с операцией удалена. Серверная генерация не отменена.';
    } catch (error) {
      await _report(error);
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> resetConnection() async {
    if (_disposed || _resetting || _getting || (busy && !_registering)) return;
    _resetting = true;
    _registering = false;
    final epoch = ++_connectionEpoch;
    _lifetimeAbort.complete();
    _lifetimeAbort = Completer<void>();
    busy = true;
    _timer?.cancel();
    _emit();
    try {
      await installations.reset(
        clearPendingOperation: () => store.clearOperation(api.config.baseUrl),
      );
      if (!_currentConnection(epoch)) return;
      operation = null;
      retryNotBefore = null;
      message =
          'Подключение сброшено. Сохранённые меню остались на устройстве.';
    } catch (error) {
      if (_currentConnection(epoch)) await _report(error);
    } finally {
      if (_currentConnection(epoch)) {
        _resetting = false;
        busy = false;
        _emit();
      }
    }
  }

  Future<void> deleteMenu(SavedMenu menu) async {
    if (_disposed) return;
    try {
      await store.deleteMenu(menu);
      if (_disposed) return;
      saved = await store.menus();
    } catch (_) {
      message = 'Не удалось удалить локальное меню.';
    }
    _emit();
  }

  @override
  void dispose() {
    _disposed = true;
    installations.dispose();
    _lifetimeAbort.complete();
    _timer?.cancel();
    _abortGet();
    super.dispose();
  }
}
