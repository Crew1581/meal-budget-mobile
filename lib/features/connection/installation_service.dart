import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/api_client.dart';

class Installation {
  const Installation(this.id, this.token);
  final String id;
  final String token;
  factory Installation.fromJson(Map<String, dynamic> json) {
    if (json['token_type'] != 'Bearer' ||
        json['installation_id'] is! String ||
        json['token'] is! String ||
        (json['token'] as String).isEmpty) {
      throw const FormatException('Некорректный ответ регистрации.');
    }
    return Installation(
      json['installation_id'] as String,
      json['token'] as String,
    );
  }
  Map<String, String> toJson() => {
    'installation_id': id,
    'token': token,
    'token_type': 'Bearer',
  };
}

abstract interface class CredentialStore {
  /// Equal for wrappers accessing the same physical storage namespace.
  /// This is not an object/owner identity and must not contain credentials.
  Object get coordinationNamespace;
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureCredentials implements CredentialStore {
  SecureCredentials([FlutterSecureStorage? storage])
    : storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: false),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.unlocked_this_device,
            ),
          );
  final FlutterSecureStorage storage;
  @override
  Object get coordinationNamespace {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final options = storage.aOptions.toMap();
      String? nonempty(String? value) =>
          value == null || value.isEmpty ? null : value;
      // Effective data-prefs namespace of pinned plugin 10.3.4. Conservatively
      // share the fence even across prefixes/cipher options of the same file.
      return (
        'android',
        nonempty(options['storageNamespace']) ??
            nonempty(options['sharedPreferencesName']) ??
            'FlutterSecureStorage',
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return ('ios', storage.iOptions.accountName, storage.iOptions.groupId);
    }
    return ('secure-credentials', defaultTargetPlatform);
  }

  AndroidOptions get _androidOptions =>
      storage.aOptions.copyWith(resetOnError: false);
  @override
  Future<String?> read(String key) =>
      storage.read(key: key, aOptions: _androidOptions);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value, aOptions: _androidOptions);
  @override
  Future<void> delete(String key) =>
      storage.delete(key: key, aOptions: _androidOptions);
}

class ConnectionFailure implements Exception {
  const ConnectionFailure(this.message);
  final String message;
  @override
  String toString() => 'ConnectionFailure';
}

class InstallationService {
  InstallationService(this.api, this.storage)
    : _slot = _slots.putIfAbsent((
        storage.coordinationNamespace,
        api.config.storageKey,
      ), _CredentialSlot.new);

  // One coordinator per storage namespace + backend, shared by service instances
  // in this isolate. It holds ordering/failure state, never a credential cache.
  static final _slots = <(Object, String), _CredentialSlot>{};
  final ApiClient api;
  final CredentialStore storage;
  final _CredentialSlot _slot;
  Future<Installation>? _flight;
  _Registration? _registration;
  bool _disposed = false;

  void _checkActive() {
    if (_disposed) {
      throw const ConnectionFailure('Подключение прежнего владельца закрыто.');
    }
  }

  Future<Installation?> existing() => _slot.ordered(() async {
    _checkActive();
    final installation = await _read();
    _checkActive();
    return installation;
  });

  // Called only inside the shared storage queue. No per-service stale cache.
  Future<Installation?> _read() async {
    _slot.checkStorage();
    try {
      final value = await storage.read(api.config.storageKey);
      return value == null
          ? null
          : Installation.fromJson(
              Map<String, dynamic>.from(jsonDecode(value) as Map),
            );
    } catch (_) {
      _slot.storageFailed = true;
      throw const ConnectionFailure(
        'Не удалось прочитать токен из защищённого хранилища. Новая установка не создана.',
      );
    }
  }

  Future<Installation> ensure({Future<void>? abort}) {
    _checkActive();
    if (_flight != null) return _flight!;
    final registration = _slot.begin();
    _registration = registration;
    if (abort != null) unawaited(abort.then((_) => registration.cancel()));
    late final Future<Installation> flight;
    flight = _ensure(registration, abort: abort).whenComplete(() {
      if (identical(_flight, flight)) _flight = null;
      if (identical(_registration, registration)) _registration = null;
    });
    return _flight = flight;
  }

  Future<Installation> _ensure(
    _Registration registration, {
    Future<void>? abort,
  }) async {
    final previous = await _slot.ordered(() async {
      registration.check();
      final installation = await _read();
      registration.check();
      return installation;
    });
    registration.check();
    if (previous != null) return previous;
    final issued = Installation.fromJson(
      await api.request(
        'POST',
        '/v1/installations',
        abort: abort,
        expected: 201,
      ),
    );
    return _slot.ordered(() async {
      // Abort is only advisory for HTTP. Fence before the storage side effect.
      registration.check();
      _slot.checkStorage();
      try {
        final encoded = jsonEncode(issued.toJson());
        await storage.write(api.config.storageKey, encoded);
        if (registration.valid) {
          if (await storage.read(api.config.storageKey) != encoded) {
            throw StateError('storage');
          }
        }
        if (!registration.valid) {
          // The write started while valid and cannot be physically cancelled.
          // Still holding the queue: no newer owner can have read/written yet.
          // This removes only our unpublished write, never newer credentials.
          await storage.delete(api.config.storageKey);
        }
      } catch (_) {
        // Unknown storage outcome: no automatic reset/re-registration, including
        // by another service instance. Only a successful explicit reset unblocks.
        _slot.storageFailed = true;
        throw const ConnectionFailure(
          'Не удалось сохранить токен. Генерация не отправлена. Для продолжения нужен явный сброс подключения.',
        );
      }
      registration.check();
      return issued;
    });
  }

  Future<void> reset({Future<void> Function()? clearPendingOperation}) {
    _checkActive();
    // Invalidate synchronously, including registrations in other instances.
    _slot.invalidate();
    _registration = null;
    _flight = null;
    return _slot.ordered(() async {
      try {
        await storage.delete(api.config.storageKey);
        // Hold the same barrier until old SQLite state is removed, so a late
        // reset continuation cannot erase an operation of the next owner.
        await clearPendingOperation?.call();
        _slot.storageFailed = false;
      } catch (_) {
        _slot.storageFailed = true;
        throw const ConnectionFailure(
          'Не удалось завершить сброс подключения. Новая генерация заблокирована; повторите явный сброс.',
        );
      }
    });
  }

  void dispose() {
    _disposed = true;
    _registration?.cancel();
  }
}

class _CredentialSlot {
  Future<void> _tail = Future.value();
  int revision = 0;
  bool storageFailed = false;

  _Registration begin() => _Registration(this, ++revision);
  void invalidate() {
    revision++;
  }

  void checkStorage() {
    if (storageFailed) {
      throw const ConnectionFailure(
        'Защищённое хранилище недоступно. Генерация остановлена; нужен явный сброс подключения.',
      );
    }
  }

  Future<T> ordered<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    // An operation's failure must not break the queue (notably explicit reset).
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class _Registration {
  _Registration(this.slot, this.revision);
  final _CredentialSlot slot;
  final int revision;
  bool _cancelled = false;
  bool get valid => !_cancelled && revision == slot.revision;
  void cancel() {
    _cancelled = true;
  }

  void check() {
    if (!valid) {
      throw const ConnectionFailure(
        'Прежняя регистрация остановлена. Её ответ не используется для генерации.',
      );
    }
  }
}
