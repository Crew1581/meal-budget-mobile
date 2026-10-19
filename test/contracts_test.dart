import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meal_budget_mobile/core/api_client.dart';
import 'package:meal_budget_mobile/core/server_config.dart';
import 'package:meal_budget_mobile/features/menus/menu.dart';
import 'package:meal_budget_mobile/features/questionnaire/questionnaire.dart';

import 'support.dart';

class _AbortClient extends http.BaseClient {
  int active = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    active++;
    await (request as http.Abortable).abortTrigger;
    active--;
    throw http.RequestAbortedException(request.url);
  }
}

void main() {
  test(
    'HTTP deadline aborts and awaits transport termination, not just Future.timeout',
    () async {
      final transport = _AbortClient();
      final api = ApiClient(
        ServerConfig('https://example.com'),
        transport,
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        api.request('GET', '/test', expected: 200),
        throwsA(isA<ApiFailure>().having((e) => e.code, 'network', 'network')),
      );
      expect(transport.active, 0);
    },
  );
  test(
    'Request matches GenerationRequest: decimal strings and strict integer fields',
    () {
      final json = object(jsonDecode(jsonEncode(questionnaire().json)));
      expect(
        json,
        jsonDecode(File('test/fixtures/request.json').readAsStringSync()),
      );
      expect(json.keys.toSet(), {
        'days',
        'budget',
        'daily_targets',
        'excluded_product_ids',
        'disliked_product_ids',
        'max_cooking_minutes',
        'meals_per_day',
        'price_region',
        'wishes',
      });
      expect(json['budget'], '200.5');
      expect(json['days'], 3);
      expect(json['meals_per_day'], 1);
      expect(json['excluded_product_ids'], isEmpty);
      expect(json['daily_targets'], {
        'calories_kcal': '185',
        'protein_g': '6.5',
        'fat_g': '3.5',
        'carbs_g': '31',
      });
    },
  );

  test('Schema limits, comma, exact money, no inferred medical goals', () {
    expect(Questionnaire.validate('budget', '1000000,00'), isNull);
    for (final value in ['0', '-1', 'NaN', 'Infinity', '1000000.01', '0.001']) {
      expect(Questionnaire.validate('budget', value), isNotNull, reason: value);
    }
    expect(Questionnaire.validate('budget', '123.4500'), isNull);
    expect(Questionnaire.validate('protein_g', '100000.01'), isNotNull);
    expect(Questionnaire.validate('meals_per_day', '1.5'), isNotNull);
    expect(Questionnaire.validate('max_cooking_minutes', '241'), isNotNull);
    expect(Questionnaire.validate('price_region', '  '), isNotNull);
    expect(
      () => Questionnaire.fromDraft(Questionnaire.emptyDraft()),
      throwsFormatException,
    );
    expect(
      () => Questionnaire.fromDraft({...draft(), 'days': '1'}),
      throwsFormatException,
    );
  });

  test(
    'Real GenerationResult structure preserves portions, costs, warnings and names',
    () {
      final result = MenuResult.fromJson(object(completed()['result']));
      expect(result.recipes.single['servings'], 2);
      expect(result.days.length, 3);
      expect(objects(result.days.first['meals']).single['servings'], 1);
      expect(result.productNames['oats'], 'Овсяные хлопья');
      expect(rubles(result.calculation['total_cost']), '89,90 ₽');
      expect(rubles(result.calculation['budget_remaining']), '110,60 ₽');
      expect(result.shopping.single['remaining_grams'], 350);
      expect(result.calculation['data_status'], 'demo_unverified');
      expect(result.warnings, isNotEmpty);
      expect(result.json, isNot(contains('metadata')));
      final bad = object(completed()['result']);
      bad['calculation']['shopping_list'] = [];
      expect(() => MenuResult.fromJson(bad), throwsFormatException);
    },
  );

  test(
    'Connection normalization, server isolation and HTTPS outside debug',
    () {
      final first = ServerConfig('https://example.com/api///');
      expect(first.baseUrl, 'https://example.com/api');
      expect(
        first.storageKey,
        isNot(ServerConfig('https://other.example.com/api').storageKey),
      );
      expect(
        () => ServerConfig('http://10.0.2.2:8000', debug: false),
        throwsFormatException,
      );
      expect(
        () => ServerConfig('http://external.example.com', debug: true),
        throwsFormatException,
      );
      expect(
        () => ServerConfig('https://user:password@example.com'),
        throwsFormatException,
      );
      expect(
        ServerConfig('http://192.168.1.12:8000', debug: true).baseUrl,
        contains('192.168.1.12'),
      );
    },
  );

  test(
    'All documented HTTP failures and Retry-After are parsed without raw messages',
    () async {
      for (final entry in {
        401: 'unauthorized',
        404: 'job_not_found',
        409: 'idempotency_conflict',
        413: 'request_too_large',
        422: 'invalid_request',
        429: 'generation_queue_full',
        503: 'worker_unavailable',
      }.entries) {
        final api = ApiClient(
          ServerConfig('https://example.com'),
          MockClient((_) async => failure(entry.key, entry.value, retry: '12')),
        );
        await expectLater(
          api.request('GET', '/test', expected: 200),
          throwsA(
            isA<ApiFailure>()
                .having((e) => e.status, 'status', entry.key)
                .having((e) => e.code, 'code', entry.value)
                .having(
                  (e) => e.retryAfter,
                  'retry',
                  const Duration(seconds: 12),
                )
                .having(
                  (e) => e.message,
                  'safe message',
                  isNot(contains('произвольный')),
                ),
          ),
        );
      }
      final now = DateTime.utc(2026, 10, 18, 12);
      expect(
        ApiClient.retryAfter(
          HttpDate.format(now.add(const Duration(seconds: 15))),
          now,
        ),
        const Duration(seconds: 15),
      );
      expect(ApiClient.retryAfter('invalid', now), isNull);
      expect(ApiClient.retryAfter('-1', now), isNull);
    },
  );

  test('HTTP has no redirects or implicit retry', () async {
    var calls = 0;
    final api = ApiClient(
      ServerConfig('https://example.com'),
      MockClient((request) async {
        calls++;
        expect(request.followRedirects, false);
        return jsonResponse({}, 307, {'location': 'https://other.example.com'});
      }),
    );
    await expectLater(
      api.request('POST', '/test', expected: 202),
      throwsA(isA<ApiFailure>()),
    );
    expect(calls, 1);
  });
}
