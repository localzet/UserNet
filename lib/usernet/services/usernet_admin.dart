import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Admin controls are compiled only into operator builds. The operator token is
/// provisioned per device and held in platform secure storage, never in the APK.
const userNetAdminBuild = bool.fromEnvironment(
  'USERNET_ADMIN_BUILD',
  defaultValue: false,
);

class UserNetAdminException implements Exception {
  const UserNetAdminException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class UserNetAdminService {
  UserNetAdminService({
    http.Client? client,
    FlutterSecureStorage? storage,
    Uri? baseUri,
  }) : _client = client ?? http.Client(),
       _storage = storage ?? const FlutterSecureStorage(),
       _base = baseUri ?? _configuredBase;

  static const _tokenKey = 'usernet.admin.token';
  static final _configuredBase = Uri.parse(
    const String.fromEnvironment('USERNET_ADMIN_API_URL', defaultValue: ''),
  );

  final http.Client _client;
  final FlutterSecureStorage _storage;
  final Uri _base;

  Future<bool> get hasSession async =>
      (await _storage.read(key: _tokenKey))?.isNotEmpty == true;

  Future<void> provision(String token) async {
    final candidate = token.trim();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(candidate)) {
      throw const UserNetAdminException('Некорректный ключ устройства.');
    }
    await _storage.write(key: _tokenKey, value: candidate);
    try {
      await _request('GET', '/auth/validate');
    } catch (_) {
      await _storage.delete(key: _tokenKey);
      rethrow;
    }
  }

  Future<bool> validate() async {
    if (!await hasSession) return false;
    try {
      await _request('GET', '/auth/validate');
      return true;
    } on UserNetAdminException catch (error) {
      if (error.statusCode == 401) return false;
      rethrow;
    }
  }

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
  }

  Future<Map<String, dynamic>> stats() => _request('GET', '/stats');

  Future<Map<String, dynamic>> users({int page = 1, String search = ''}) =>
      _request(
        'GET',
        '/users',
        query: {
          'page': '$page',
          'limit': '20',
          if (search.trim().isNotEmpty) 'search': search.trim(),
        },
      );

  Future<Map<String, dynamic>> user(String id) =>
      _request('GET', '/users/${Uri.encodeComponent(id)}');

  Future<Map<String, dynamic>> updateUser(
    String id, {
    required String level,
    required int discount,
  }) => _request(
    'PUT',
    '/users/${Uri.encodeComponent(id)}',
    body: {'level': level, 'discount': discount},
  );

  Future<Map<String, dynamic>> purchases({int page = 1}) =>
      _request('GET', '/purchases', query: {'page': '$page', 'limit': '20'});

  Future<Map<String, dynamic>> networkNodes() =>
      _request('GET', '/network/nodes');

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    bool authenticated = true,
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (_base.scheme != 'https' ||
        _base.host.isEmpty ||
        _base.userInfo.isNotEmpty ||
        _base.hasQuery ||
        _base.hasFragment) {
      throw const UserNetAdminException(
        'Админский API не настроен для этой сборки.',
      );
    }
    final uri = _base.replace(
      path: '${_base.path.replaceFirst(RegExp(r'/$'), '')}$path',
      queryParameters: query,
    );
    final token = authenticated ? await _storage.read(key: _tokenKey) : null;
    if (authenticated && (token == null || token.isEmpty)) {
      throw const UserNetAdminException('Устройство не подключено.', 401);
    }
    final headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    try {
      final payload = body == null ? null : jsonEncode(body);
      final response = await switch (method) {
        'GET' => _client.get(uri, headers: headers),
        'POST' => _client.post(uri, headers: headers, body: payload),
        'PUT' => _client.put(uri, headers: headers, body: payload),
        _ => throw ArgumentError.value(method, 'method'),
      }.timeout(const Duration(seconds: 15));
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final error = decoded is Map ? decoded['message'] : null;
        throw UserNetAdminException(
          error is String ? error : 'Ошибка API (${response.statusCode}).',
          response.statusCode,
        );
      }
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      throw const UserNetAdminException('Некорректный ответ сервера.');
    } on UserNetAdminException {
      rethrow;
    } catch (_) {
      throw const UserNetAdminException('Админский API сейчас недоступен.');
    }
  }
}

final userNetAdminService = UserNetAdminService();
