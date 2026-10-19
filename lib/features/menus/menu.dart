import 'dart:convert';

typedef Json = Map<String, dynamic>;

Json object(dynamic value) => Map<String, dynamic>.from(value as Map);
List<Json> objects(dynamic value) => (value as List).map(object).toList();

String quantity(dynamic value) => value.toString().replaceAll('.', ',');

/// Server money is already rounded to cents. Only decimal text formatting here.
String rubles(dynamic value) {
  final text = value.toString();
  if (!RegExp(r'^-?\d+(\.\d{1,2})?$').hasMatch(text)) {
    throw const FormatException('Некорректное денежное значение сервера.');
  }
  final parts = text.split('.');
  return '${parts[0]},${(parts.length == 2 ? parts[1] : '').padRight(2, '0')} ₽';
}

class MenuResult {
  MenuResult.fromJson(Json value)
    : json = object(jsonDecode(jsonEncode(value))) {
    // Metadata is deliberately not required for rendering or offline storage.
    json.remove('metadata');
    if (json['catalog_version'] != calculation['catalog_version']) {
      throw const FormatException('Версии каталога не совпадают.');
    }
    for (final key in [
      'budget',
      'total_cost',
      'budget_remaining',
      'over_budget_by',
    ]) {
      rubles(calculation[key]);
    }
    calculation['within_budget'] as bool;
    calculation['warning'] as String;
    calculation['data_status'] as String;
    warnings;
    for (final item in shopping) {
      item['product_id'] as String;
      item['name'] as String;
      item['packages'] as int;
      for (final key in [
        'required_grams',
        'package_size_g',
        'purchased_grams',
        'remaining_grams',
      ]) {
        _number(item[key]);
      }
      rubles(item['price']);
      rubles(item['cost']);
    }
    final names = productNames;
    final recipesById = {
      for (final recipe in recipes) recipe['id'] as String: recipe,
    };
    for (final recipe in recipes) {
      recipe['name'] as String;
      recipe['servings'] as int;
      recipe['cooking_minutes'] as int;
      List<String>.from(recipe['steps'] as List);
      for (final ingredient in objects(recipe['ingredients'])) {
        _number(ingredient['grams']);
        if (!names.containsKey(ingredient['product_id'])) {
          throw const FormatException(
            'В результате отсутствует название продукта.',
          );
        }
      }
    }
    for (final day in days) {
      day['day'] as int;
      _nutrition(object(day['nutrition']));
      for (final meal in objects(day['meals'])) {
        _number(meal['servings']);
        _nutrition(object(meal['nutrition']));
        if (!recipesById.containsKey(meal['recipe_id'])) {
          throw const FormatException('Отсутствует рецепт.');
        }
      }
    }
  }

  static void _number(dynamic value) {
    if (value is! num || !value.isFinite) {
      throw const FormatException('Ожидалось конечное JSON-число.');
    }
  }

  static void _nutrition(Json value) {
    for (final key in ['calories_kcal', 'protein_g', 'fat_g', 'carbs_g']) {
      _number(value[key]);
    }
  }

  final Json json;
  Json get calculation => object(json['calculation']);
  List<Json> get recipes => objects(object(json['plan'])['recipes']);
  List<Json> get days => objects(calculation['days']);
  List<Json> get shopping => objects(calculation['shopping_list']);
  List<String> get warnings => List<String>.from(json['warnings'] as List);
  Map<String, String> get productNames => {
    for (final item in shopping)
      item['product_id'] as String: item['name'] as String,
  };
  Json recipe(String id) => recipes.firstWhere((recipe) => recipe['id'] == id);
}

class SavedMenu {
  SavedMenu({
    required this.id,
    required this.server,
    required this.createdAt,
    required this.result,
  });
  final String id;
  final String server;
  final DateTime createdAt;
  final MenuResult result;
}
