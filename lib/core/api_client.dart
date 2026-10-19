import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../features/menus/menu.dart';
import 'server_config.dart';

class ApiFailure implements Exception {
  const ApiFailure(this.status, this.code, {this.retryAfter});
  final int status;
  final String code;
  final Duration? retryAfter;
  bool get transient => status == 0 || status >= 500 || status == 429;

  String get message => switch (code) {
    'unauthorized' =>
      'Сервер не принимает токен. Новая установка автоматически не создаётся. Проверьте сервер или сбросьте подключение.',
    'job_not_found' =>
      'Задание недоступно: оно могло истечь или принадлежать другой установке. Новый POST не отправлен.',
    'idempotency_conflict' =>
      'Ключ уже связан с другой анкетой. Повтор остановлен; нужна проверка подключения.',
    'request_too_large' => 'Анкета превышает лимит сервера (64 КиБ).',
    'invalid_request' || 'invalid_idempotency_key' =>
      'Сервер отклонил параметры. Проверьте анкету и совместимость API.',
    'generation_queue_full' =>
      'Очередь заполнена. Повтор возможен только отдельным действием.',
    'app_daily_quota_exceeded' => 'Общая суточная квота заданий исчерпана.',
    'installation_daily_job_quota_exceeded' =>
      'Суточная квота заданий этой установки исчерпана.',
    'installation_daily_quota_exceeded' =>
      'Суточная квота регистрации установок исчерпана.',
    'installation_capacity_reached' =>
      'Регистрация недоступна: нужна проверка ёмкости оператором. Пауза не гарантирует освобождение.',
    'worker_unavailable' =>
      'Исполнитель недоступен. Это не failed: принятое задание может продолжиться после перезапуска сервера.',
    'job_storage_unavailable' =>
      'Хранилище заданий недоступно. Исход POST может быть неизвестен.',
    'network' => 'Нет ответа сервера. Это не означает, что POST не принят.',
    'protocol' =>
      'Не удалось прочитать ответ API. Исход POST может быть неизвестен.',
    _ => 'Сервер вернул ошибку HTTP $status. Автоматического повтора POST нет.',
  };

  @override
  String toString() => 'ApiFailure($status, $code)';
}

class ApiClient {
  ApiClient(
    this.config,
    this.client, {
    this.timeout = const Duration(seconds: 20),
  });
  final ServerConfig config;
  final http.Client client;
  final Duration timeout;

  Future<Json> request(
    String method,
    String path, {
    String? token,
    String? body,
    String? key,
    Future<void>? abort,
    required int expected,
  }) async {
    final cancelled = Completer<void>();
    void cancel() {
      if (!cancelled.isCompleted) cancelled.complete();
    }

    final deadline = Timer(timeout, cancel);
    if (abort != null) unawaited(abort.then((_) => cancel()));
    try {
      final request = http.AbortableRequest(
        method,
        config.endpoint(path),
        abortTrigger: cancelled.future,
      )..followRedirects = false;
      request.headers['Accept'] = 'application/json';
      if (token != null) request.headers['Authorization'] = 'Bearer $token';
      if (key != null) request.headers['Idempotency-Key'] = key;
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = body;
      }
      final response = await (() async {
        final stream = await client.send(request);
        return http.Response.fromStream(stream);
      })();
      if (response.statusCode != expected) {
        String? code;
        try {
          code =
              object(object(jsonDecode(response.body))['detail'])['code']
                  as String?;
        } catch (_) {
          /* Never reflect response bodies. */
        }
        throw ApiFailure(
          response.statusCode,
          code ?? 'http_error',
          retryAfter: retryAfter(
            response.headers['retry-after'],
            DateTime.now().toUtc(),
          ),
        );
      }
      return object(jsonDecode(utf8.decode(response.bodyBytes)));
    } on ApiFailure {
      rethrow;
    } on TimeoutException {
      throw const ApiFailure(0, 'network');
    } on SocketException {
      throw const ApiFailure(0, 'network');
    } on http.ClientException {
      throw const ApiFailure(0, 'network');
    } catch (_) {
      throw const ApiFailure(0, 'protocol');
    } finally {
      deadline.cancel();
    }
  }

  static Duration? retryAfter(String? value, DateTime now) {
    if (value == null) return null;
    final seconds = int.tryParse(value);
    if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
    try {
      final delay = HttpDate.parse(value).difference(now);
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {
      return null;
    }
  }
}
