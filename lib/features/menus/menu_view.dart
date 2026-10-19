import 'package:flutter/material.dart';

import 'menu.dart';

String nutritionText(Json nutrition) =>
    '${quantity(nutrition['calories_kcal'])} ккал · '
    'Б ${quantity(nutrition['protein_g'])} г · '
    'Ж ${quantity(nutrition['fat_g'])} г · '
    'У ${quantity(nutrition['carbs_g'])} г';

class MenuView extends StatelessWidget {
  const MenuView({super.key, required this.menu});
  final SavedMenu menu;

  @override
  Widget build(BuildContext context) {
    final result = menu.result;
    final calculation = result.calculation;
    return Scaffold(
      appBar: AppBar(title: const Text('Сохранённое меню')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Покупки: ${rubles(calculation['total_cost'])}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text('Бюджет периода: ${rubles(calculation['budget'])}'),
                  Text(
                    'Остаток бюджета: ${rubles(calculation['budget_remaining'])}',
                  ),
                  if (calculation['within_budget'] == false)
                    Text(
                      'Превышение: ${rubles(calculation['over_budget_by'])}',
                    ),
                  const SizedBox(height: 8),
                  const Text(
                    'Наблюдаемая стоимость, не гарантированная цена магазина. Все товары покупаются с нуля.',
                  ),
                ],
              ),
            ),
          ),
          Card(
            color: Theme.of(context).colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Достоверность каталога: ${calculation['data_status']}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(calculation['warning'] as String),
                  for (final warning in result.warnings.toSet())
                    if (warning != calculation['warning']) Text(warning),
                  const Text(
                    'Время приготовления заявлено, не проверено. Меню не является медицинской рекомендацией; безопасность при аллергии не гарантируется.',
                  ),
                ],
              ),
            ),
          ),
          for (final day in result.days) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'День ${day['day']}',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            Text('Итого за день: ${nutritionText(object(day['nutrition']))}'),
            for (final (index, meal) in objects(day['meals']).indexed)
              _MealCard(index: index, meal: meal, result: result),
          ],
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Список покупок',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          for (final item in result.shopping)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['name'] as String,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '${item['packages']} уп. × ${quantity(item['package_size_g'])} г · ${rubles(item['cost'])}',
                    ),
                    Text('Наблюдаемая цена упаковки: ${rubles(item['price'])}'),
                    Text(
                      'Нужно: ${quantity(item['required_grams'])} г; куплено: ${quantity(item['purchased_grams'])} г',
                    ),
                    Text(
                      'Остаток продукта: ${quantity(item['remaining_grams'])} г',
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MealCard extends StatelessWidget {
  const _MealCard({
    required this.index,
    required this.meal,
    required this.result,
  });
  final int index;
  final Json meal;
  final MenuResult result;

  @override
  Widget build(BuildContext context) {
    final recipe = result.recipe(meal['recipe_id'] as String);
    return Card(
      child: ExpansionTile(
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text('Приём ${index + 1}: ${recipe['name']}'),
        subtitle: Text(
          'В этом приёме: ${quantity(meal['servings'])} порц. из ${recipe['servings']} порц. полного рецепта\n${nutritionText(object(meal['nutrition']))}',
        ),
        childrenPadding: const EdgeInsets.all(16),
        children: [
          Text(
            'Полный рецепт — выход ${recipe['servings']} порц.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Ингредиенты ниже — на весь рецепт, не на один приём. При повторных приёмах это не учёт приготовленной партии.',
          ),
          Text(
            'Заявленное время: ${recipe['cooking_minutes']} мин (не проверено)',
          ),
          const SizedBox(height: 8),
          for (final ingredient in objects(recipe['ingredients']))
            Text(
              '${result.productNames[ingredient['product_id']]} — ${quantity(ingredient['grams'])} г',
            ),
          const SizedBox(height: 8),
          for (final (step, text) in List<String>.from(
            recipe['steps'] as List,
          ).indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('${step + 1}. $text'),
            ),
        ],
      ),
    );
  }
}
