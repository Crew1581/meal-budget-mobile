import 'dart:convert';
import 'dart:io';

import 'package:meal_budget_mobile/features/connection/installation_service.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:meal_budget_mobile/features/questionnaire/questionnaire.dart';
import 'package:http/http.dart' as http;

const jobId = '00000000-0000-4000-8000-000000000001';
const issued = {
  'installation_id': '00000000-0000-4000-8000-000000000002',
  'token': 'test-token-not-a-real-secret',
  'token_type': 'Bearer',
};

Map<String, String> draft() => {
  'days': '3',
  'budget': '200,50',
  'calories_kcal': '185',
  'protein_g': '6,5',
  'fat_g': '3,5',
  'carbs_g': '31',
  'meals_per_day': '1',
  'max_cooking_minutes': '20',
  'price_region': 'Москва',
  'wishes': 'Технический тест, не рекомендация',
};
Questionnaire questionnaire() => Questionnaire.fromDraft(draft());
Json completed() =>
    object(jsonDecode(File('test/fixtures/completed.json').readAsStringSync()));
http.Response jsonResponse(
  Object value, [
  int status = 200,
  Map<String, String>? headers,
]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
);
http.Response failure(int status, String code, {String? retry}) => jsonResponse(
  {
    'detail': {
      'code': code,
      'message': 'Не отражать произвольный текст',
      'metadata': null,
    },
  },
  status,
  retry == null ? null : {'retry-after': retry},
);

class MemoryCredentials implements CredentialStore {
  MemoryCredentials({Map<String, String>? values}) : values = values ?? {};
  final Map<String, String> values;
  @override
  Object get coordinationNamespace => values;
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('read');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('write');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('delete');
    values.remove(key);
  }
}
