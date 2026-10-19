import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/local_store.dart';
import '../generation/generation_controller.dart';
import 'questionnaire.dart';

class QuestionnaireForm extends StatefulWidget {
  const QuestionnaireForm({
    super.key,
    required this.store,
    required this.controller,
  });
  final LocalStore store;
  final GenerationController controller;
  @override
  State<QuestionnaireForm> createState() => _QuestionnaireFormState();
}

class _QuestionnaireFormState extends State<QuestionnaireForm> {
  final _form = GlobalKey<FormState>();
  final _fields = {
    for (final key in Questionnaire.fields) key: TextEditingController(),
  };
  int _days = 3;
  bool _loaded = false;
  String? _storageError;
  Future<void> _writes = Future.value();

  static const _labels = {
    'budget': 'Бюджет на выбранный период, ₽',
    'calories_kcal': 'Калории в день, ккал',
    'protein_g': 'Белки в день, г',
    'fat_g': 'Жиры в день, г',
    'carbs_g': 'Углеводы в день, г',
    'meals_per_day': 'Приёмов пищи в день (1–10)',
    'max_cooking_minutes': 'Максимум заявленного времени, мин (1–240)',
    'price_region': 'Регион цен (пожелание)',
    'wishes': 'Пожелания (необязательно)',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final draft =
          await widget.store.loadDraft() ?? Questionnaire.emptyDraft();
      if (!mounted) return;
      _days = draft['days'] == '7' ? 7 : 3;
      for (final key in _fields.keys) {
        _fields[key]!.text = draft[key] ?? '';
      }
      setState(() => _loaded = true);
    } catch (_) {
      if (mounted) {
        setState(
          () => _storageError =
              'Не удалось прочитать анкету. Закройте и откройте приложение после восстановления хранилища.',
        );
      }
    }
  }

  Map<String, String> _draft() => {
    'days': '$_days',
    for (final entry in _fields.entries) entry.key: entry.value.text,
  };

  Future<void> _save() {
    final draft = _draft();
    // Serialize writes so an older keystroke cannot overwrite a newer draft.
    return _writes = _writes
        .then((_) => widget.store.saveDraft(draft))
        .then((_) {
          if (mounted && _storageError != null) {
            setState(() => _storageError = null);
          }
        })
        .catchError((Object _) {
          if (mounted) {
            setState(
              () => _storageError =
                  'Не удалось сохранить анкету. Генерация остановлена; попробуйте ещё раз.',
            );
          }
        });
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final questionnaire = Questionnaire.fromDraft(_draft());
    await _save();
    if (_storageError == null) await widget.controller.create(questionnaire);
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_storageError ?? 'Загрузка анкеты…'),
      );
    }
    final controller = widget.controller;
    final blocked =
        controller.busy ||
        (controller.operation != null && !controller.operation!.terminal);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Задайте собственные дневные цели. Приложение не рассчитывает медицинские рекомендации. Выбор исключений пока не реализован; безопасность при аллергии не гарантируется.',
          ),
          const SizedBox(height: 16),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 3, label: Text('3 дня')),
              ButtonSegment(value: 7, label: Text('7 дней')),
            ],
            selected: {_days},
            onSelectionChanged: (value) {
              setState(() => _days = value.single);
              unawaited(_save());
            },
          ),
          const SizedBox(height: 12),
          for (final key in Questionnaire.fields)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextFormField(
                key: ValueKey(key),
                controller: _fields[key],
                decoration: InputDecoration(
                  labelText: _labels[key],
                  border: const OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                keyboardType: key == 'wishes'
                    ? TextInputType.multiline
                    : key == 'price_region'
                    ? TextInputType.text
                    : const TextInputType.numberWithOptions(decimal: true),
                textInputAction: key == 'wishes'
                    ? TextInputAction.newline
                    : TextInputAction.next,
                minLines: key == 'wishes' ? 2 : 1,
                maxLines: key == 'wishes' ? 5 : 1,
                validator: (value) => Questionnaire.validate(key, value ?? ''),
                onChanged: (_) => unawaited(_save()),
              ),
            ),
          if (_storageError != null)
            Text(
              _storageError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (blocked)
            const Text(
              'Анкету можно редактировать для следующего меню. Снимок текущей операции не изменяется.',
            ),
          FilledButton.icon(
            onPressed: blocked ? null : _submit,
            icon: const Icon(Icons.restaurant_menu),
            label: const Text('Создать меню'),
          ),
          const Text(
            'Это новая серверная операция; генерация может расходовать платный ресурс провайдера. Сохранённые меню доступны без сети.',
          ),
        ],
      ),
    );
  }
}
