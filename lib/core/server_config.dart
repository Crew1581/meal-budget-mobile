import 'dart:convert';

import 'package:flutter/foundation.dart';

class ServerConfig {
  ServerConfig(String value, {bool debug = kDebugMode, this.minimumRetention}) {
    final uri = Uri.parse(value.trim());
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(debug && uri.scheme == 'http' && _localHost(uri.host)))) {
      throw const FormatException(
        'Нужен HTTPS URL; локальный HTTP — только debug.',
      );
    }
    baseUrl = uri
        .replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
        .toString();
  }

  late final String baseUrl;
  final Duration? minimumRetention;
  String get storageKey =>
      'installation_${base64Url.encode(utf8.encode(baseUrl))}';
  Uri endpoint(String path) => Uri.parse('$baseUrl$path');

  static bool _localHost(String host) {
    if (host == 'localhost' || host == '::1' || host.endsWith('.local')) {
      return true;
    }
    final parts = host.split('.').map(int.tryParse).toList();
    if (parts.length != 4 || parts.any((p) => p == null || p < 0 || p > 255)) {
      return false;
    }
    return parts[0] == 127 ||
        parts[0] == 10 ||
        (parts[0] == 192 && parts[1] == 168) ||
        (parts[0] == 172 && parts[1]! >= 16 && parts[1]! <= 31);
  }
}
