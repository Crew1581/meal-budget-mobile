# Контракт backend для мобильного клиента

Сверено с backend `docs/API.md`, `schemas/{generation,jobs,installations,common,menu}.py`
и `api/app_jobs.py` в рамках MEAL-10. Backend не изменён.

Базовый URL — `--dart-define=API_BASE_URL=...`, включая optional proxy base path.
Никаких credentials в URL или dart-define. Redirect не выполняется автоматически.

## Установка

`POST /v1/installations`, без Bearer и обязательного тела → **201**:

```json
{"installation_id":"00000000-0000-4000-8000-000000000001","token":"<opaque secret>","token_type":"Bearer"}
```

Placeholder не является валидным токеном. ID и Bearer сохраняются в secure storage
под ключом данного URL. Сервер выдаёт секрет только один раз. Нет refresh/recovery/
revoke API; регистрация неидемпотентна, потерянный 201 может оставить установку
без известного клиенту токена. Автоматически на старте не вызывается.

## Создание задания

`POST /v1/app/generation-jobs`, installation Bearer и один `Idempotency-Key`
(1–64 ASCII `[A-Za-z0-9_-]`, регистр значим). Тело ≤65536 байт.
Пример сериализации приложения (синтетические числа, не рекомендация):

```json
{
  "days": 3,
  "budget": "200.5",
  "daily_targets": {"calories_kcal":"370","protein_g":"13","fat_g":"7","carbs_g":"62"},
  "excluded_product_ids": [],
  "disliked_product_ids": [],
  "max_cooking_minutes": 20,
  "meals_per_day": 1,
  "price_region": "Москва",
  "wishes": "Технический тест"
}
```

Decimal принимает числа и десятичные строки. Строго целые поля — JSON integers.
Backend days=1–31, UI сознательно 3/7. budget >0 и ≤1 000 000 ₽, максимум 2 значащих
десятичных знака после запятой; дневные цели >0 и ≤100000; meals=1–10,
minutes=1–240; region после trim непустой, ≤120 символов; wishes ≤2000.
Неизвестные поля запрещены. ID-списки пока пустые, выбор отложен.

**202** `{"id":"<UUID>","state":"queued"}` — подтверждение приёма, не текущий
статус. Идемпотентный повтор возвращает ту же форму и ID даже после завершения.
Ключ и валидированная анкета уникальны в установке; изменение снимка → 409.
Ключ живёт вместе с job: активный без срока, terminal — retention от finished_at
(на сервере default 24 часа, **конфигурируется и не сообщается API**). После TTL
тот же ключ может создать новое задание. Потеря POST-ответа/503 во время COMMIT
не доказывает отсутствие задания. Повтор только явный и в подтверждённом сроке.

## Чтение задания

`GET /v1/app/generation-jobs/{job_id}` с тем же Bearer → **200**:
`id`, `state`, `created_at`, nullable `started_at`/`finished_at`, `catalog_version`,
nullable `result`/`error_code`. Состояния только queued/running/completed/failed.

- completed: `result` = GenerationResult (`plan`, `calculation`, `catalog_version`,
  `warnings`, `nutrition_tolerance`, `metadata`). Метаданные модели не нужны UI.
- failed: безопасный `error_code`, непроверенного меню нет. Среди кодов:
  attempts_exhausted, interrupted, catalog_version_mismatch, internal_error,
  catalog_unavailable и прежние GenerationError. Новый запуск только явный.
- 404 одинаков для чужого/неизвестного/истёкшего задания. Доступ к удалённому
  server job не нужен для сохранённого локального меню.

`plan.recipes`: id/name/servings/ingredients(product_id, grams)/steps/cooking_minutes.
Граммы — **на весь рецепт**; `recipe.servings` — полный выход, `meal.servings` —
съедаемые порции. `calculation.days[].meals[]` содержит рассчитанные сервером
порции/КБЖУ; nutrition дня независим от суммы округлённых приёмов.
`calculation.shopping_list` содержит product_id/name/required_grams/package_size_g/
packages/purchased_grams/remaining_grams/price/cost. Остаток — продукт, не готовое блюдо.
Серверные budget/total_cost/budget_remaining/over_budget_by не пересчитываются.
`data_status=demo_unverified`, warning и warnings отображаются, не скрываются.
Названия в shopping_list сохраняются вместе с меню, GET `/v1/products` не требуется.

## Ошибки

Реальная форма: `{"detail":{"code":"...","message":"...","metadata":null}}`.
Клиент использует безопасные русские тексты по коду, не отражает произвольное тело.

| HTTP | Коды / поведение |
| --- | --- |
| 401 | unauthorized; стоп, без автоматической регистрации |
| 404 | job_not_found для GET; app API также может быть выключен |
| 409 | idempotency_conflict; снимок с этим ключом не менять |
| 413 | request_too_large |
| 422 | invalid_request, invalid_idempotency_key |
| 429 | generation_queue_full, app_daily_quota_exceeded, installation_daily_job_quota_exceeded, installation_daily_quota_exceeded, installation_capacity_reached |
| 503 | job_storage_unavailable, worker_unavailable |

Retry-After: у полной очереди 1 секунда; у суточных квот — секунды до UTC-полуночи;
capacity — 86400 и требуется оператор, ёмкость через сутки не обещана.
Клиент принимает секунды и HTTP-date, соблюдает паузу (для текущей операции
сохраняет её в SQLite), не делает POST retry автоматически. GET 503 worker_unavailable
не является failed и не разрешает новый POST. Неизвестные HTTP-ошибки безопасно
показываются без сырых данных. Квоты не являются денежным лимитом; серверная
генерация может обращаться к провайдеру до трёх раз.

Developer API `/v1/generation-jobs` и `/v1/menu-generations` не используется.
Серверный developer Bearer и ключ DeepSeek в приложение не передаются.
