/// Decimal input is kept as text. No monetary arithmetic uses binary floats.
String? decimalInput(String input, {required int max, int? places}) {
  final text = input.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final fraction = parts.length == 2
      ? parts[1].replaceFirst(RegExp(r'0+$'), '')
      : '';
  if (places != null && fraction.length > places) return null;
  final whole = BigInt.parse(parts[0]);
  if ((whole == BigInt.zero && fraction.isEmpty) ||
      whole > BigInt.from(max) ||
      (whole == BigInt.from(max) && fraction.isNotEmpty)) {
    return null;
  }
  return fraction.isEmpty ? '$whole' : '$whole.$fraction';
}

class Questionnaire {
  Questionnaire._(this.json);
  final Map<String, dynamic> json;

  static const fields = [
    'budget',
    'calories_kcal',
    'protein_g',
    'fat_g',
    'carbs_g',
    'meals_per_day',
    'max_cooking_minutes',
    'price_region',
    'wishes',
  ];

  static Map<String, String> emptyDraft() => {
    'days': '3',
    for (final key in fields) key: '',
  };

  static String? validate(String key, String value) {
    if (key == 'wishes') {
      return value.trim().runes.length <= 2000
          ? null
          : 'Не более 2000 символов';
    }
    if (key == 'price_region') {
      return value.trim().isNotEmpty && value.trim().runes.length <= 120
          ? null
          : 'Введите регион, до 120 символов';
    }
    if (key == 'meals_per_day' || key == 'max_cooking_minutes') {
      final n = RegExp(r'^\d+$').hasMatch(value.trim())
          ? int.tryParse(value.trim())
          : null;
      final max = key == 'meals_per_day' ? 10 : 240;
      return n != null && n >= 1 && n <= max
          ? null
          : 'Целое число от 1 до $max';
    }
    final money = key == 'budget';
    return decimalInput(
              value,
              max: money ? 1000000 : 100000,
              places: money ? 2 : null,
            ) !=
            null
        ? null
        : money
        ? 'Больше 0, до 1 000 000 ₽; максимум 2 знака'
        : 'Больше 0, до 100 000';
  }

  factory Questionnaire.fromDraft(Map<String, String> draft) {
    for (final field in fields) {
      if (validate(field, draft[field] ?? '') != null) {
        throw const FormatException('Проверьте поля анкеты.');
      }
    }
    final days = int.tryParse(draft['days'] ?? '');
    if (days != 3 && days != 7) {
      throw const FormatException('Выберите 3 или 7 дней.');
    }
    return Questionnaire._(
      Map.unmodifiable({
        'days': days,
        'budget': decimalInput(draft['budget']!, max: 1000000, places: 2),
        'daily_targets': {
          for (final key in ['calories_kcal', 'protein_g', 'fat_g', 'carbs_g'])
            key: decimalInput(draft[key]!, max: 100000),
        },
        'excluded_product_ids': <String>[],
        'disliked_product_ids': <String>[],
        'max_cooking_minutes': int.parse(draft['max_cooking_minutes']!.trim()),
        'meals_per_day': int.parse(draft['meals_per_day']!.trim()),
        'price_region': draft['price_region']!.trim(),
        'wishes': draft['wishes']!.trim(),
      }),
    );
  }
}
