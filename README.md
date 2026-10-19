# Meal Budget

Первый мобильный сценарий MEAL-10: анкета → установка → фоновое задание →
проверенное сервером меню → локальное сохранение и offline-просмотр.
Flutter, Android/iOS, Material 3, русский интерфейс. Без аккаунта, аналитики,
рекламы, платежей и прямого подключения к DeepSeek.

Перед работой читать [STATUS](docs/STATUS.md) и [AGENTS](AGENTS.md).
[Продукт](docs/PRODUCT.md) · [архитектура](docs/ARCHITECTURE.md) ·
[решения](docs/DECISIONS.md) · [API](docs/API.md) · [roadmap](docs/ROADMAP.md).

MEAL-10 реализована, P1/P2 закрыты; последнее независимое ревью не обнаружило
новых подтверждённых регрессий. Предыдущие автоматические проверки: **55 тестов**,
analyze, format-check и debug APK — успешно. При финализации документации они
повторно не запускались.

Пользователь самостоятельно выполнил реальный Android/backend/DeepSeek E2E
2026-10-19 на **3 дня × 1 приём** и подтвердил результат скриншотами; детали и
границы — в STATUS отдельно от синтетических offline/native-проверок.
Далее запланированы оценка полноценного меню **3 дня × 3 приёма**, затем подготовка
**HTTPS-окружения закрытого пилота**. Эти этапы ещё не выполнены.

## Подготовка Flutter

Проверенная версия: **Flutter 3.44.8 stable / Dart 3.12.2**, Android SDK и JDK
из Android Studio. Установить Flutter по официальной инструкции, добавить его
`bin` в PATH; настроить Android SDK и принять лицензии. Не создавать проект заново.

```bash
cd /home/crew/development/meal-budget-mobile
flutter --version
flutter doctor -v
flutter doctor --android-licenses
flutter pub get --enforce-lockfile
```

`pubspec.lock` хранится в Git. Для iOS нужны macOS/Xcode, signing и доступный
iOS SDK; Linux не проверяет сборку iOS. Идентификаторы и release signing пока
унаследованы от каркаса, публикация в магазинах не подготовлена.

## Локальный backend без платных вызовов

Backend — **только для чтения**: `/home/crew/PycharmProjects/meal-budget`.
Нужны Docker, Python 3.13 и uv (backend lock подготовлен с uv 0.12.5).
Launcher `tools/local_backend.py` использует реальные `create_app`, Settings,
миграции и существующий `tools/local_generation_provider.py` из backend.
Он передаёт `Settings(_env_file=None)`, не читает `.env`, не пишет bytecode в backend,
жёстко задаёт loopback URL провайдера и фиктивный ключ. Реального DeepSeek нет.

**Важное ограничение:** исходный провайдер умеет только один demo-день. Наш
тестовый адаптер повторяет именно этот день 3 (либо 7) раза. Это не генератор
рецептов и не доказательство качества меню. Исходники backend не меняются.

Команды ниже — из мобильного репозитория, Bash. Терминал 1, подготовка отдельного
окружения **вне backend** и новой временной тестовой БД:

```bash
export BACKEND=/home/crew/PycharmProjects/meal-budget
export UV_PROJECT_ENVIRONMENT=/tmp/opencode/meal10-backend-venv
uv sync --project "$BACKEND" --frozen --no-env-file
export PYTHON="$UV_PROJECT_ENVIRONMENT/bin/python"
export PYTHONDONTWRITEBYTECODE=1
export MEAL10_DB_CONTAINER="meal10-mobile-$(date +%s)-$$"
docker run --rm -d --name "$MEAL10_DB_CONTAINER" \
  -p 127.0.0.1:55440:5432 \
  -e POSTGRES_USER=meal10 -e POSTGRES_DB=meal10_test \
  -e POSTGRES_HOST_AUTH_METHOD=trust \
  --tmpfs /var/lib/postgresql/data postgres:17-alpine \
  -c log_statement=none -c log_min_error_statement=panic -c log_error_verbosity=terse
until docker exec "$MEAL10_DB_CONTAINER" pg_isready -U meal10 -d meal10_test; do sleep 1; done
export GENERATION_JOBS_DATABASE_URL=postgresql://meal10@127.0.0.1:55440/meal10_test
"$PYTHON" tools/local_backend.py migrate --backend "$BACKEND"
"$PYTHON" tools/local_backend.py provider --backend "$BACKEND" --days 3
```

Trust разрешён **только для этой временной локальной тестовой БД**. Не использовать
такие настройки в production, не открывать порт БД наружу. Если порт занят — не
останавливать чужие контейнеры: выбрать другой порт и изменить URL во всех командах.
Миграции выполняются до API, не одновременно с ним.

Терминал 2, реальный API с app-маршрутами, сроком хранения 86400 секунд и без access log:

```bash
export PYTHONDONTWRITEBYTECODE=1
export GENERATION_JOBS_DATABASE_URL=postgresql://meal10@127.0.0.1:55440/meal10_test
/tmp/opencode/meal10-backend-venv/bin/python tools/local_backend.py api \
  --backend /home/crew/PycharmProjects/meal-budget
```

Терминал 3, проверка процесса (не вызывает генерацию):

```bash
curl --disable --noproxy '*' --fail http://127.0.0.1:8000/health
```

После остановки обоих Python-процессов через Ctrl-C в терминале 1 можно остановить
**только созданный вами тестовый контейнер**: `docker stop "$MEAL10_DB_CONTAINER"`.
Его tmpfs-БД исчезнет. Не применять эту команду к рабочим БД/контейнерам.
В данной реализации для проверки использовался уже установленный backend runtime
`.venv/bin/python` (без изменения окружения); команды создания внешнего uv-окружения
даны для воспроизведения на чистой машине.

## Запуск Android

```bash
flutter emulators
flutter emulators --launch Pixel_8
flutter devices
flutter run -d emulator-5554 \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000 \
  --dart-define=API_MIN_RETENTION_SECONDS=86400
```

ID AVD/устройства заменить значением из списка. Для headless Linux:
`$HOME/Android/Sdk/emulator/emulator -avd Pixel_8 -no-window -no-snapshot -gpu swiftshader`.

Анкета **только для локального синтетического теста**, не рекомендация на день:
3 дня, бюджет 200,50 ₽, дневные цели 370 ккал / Б 13 / Ж 7 / У 62,
1 приём пищи, максимум 20 минут, регион Москва, произвольные пожелания.
Результат: 3 одинаковых demo-дня; покупки 89,90 ₽, остаток бюджета 110,60 ₽.
Для 7 дней перезапустить **адаптер** с `--days 7` и выбрать 7 дней в анкете.
Другие параметры могут дать failed — фиксированный провайдер их не подбирает.

### Физическое устройство и release

- `10.0.2.2` — адрес хоста только для Android Emulator, не телефона.
- Телефон и компьютер — в доверенной локальной Wi-Fi сети. API запустить с
  `tools/local_backend.py api --host 0.0.0.0`; передать
  `--dart-define=API_BASE_URL=http://192.168.1.10:8000` с реальным LAN-адресом ПК.
  Разрешить порт 8000 в firewall только для нужного устройства. БД/провайдер
  остаются на loopback. Не открывать этот тестовый API в интернет.
- Альтернатива по USB Android: `adb reverse tcp:8000 tcp:8000`, затем
  `API_BASE_URL=http://127.0.0.1:8000`.
- iOS Simulator использует `http://127.0.0.1:8000`; для физического iOS — LAN-адрес
  и разрешение Local Network. Отдельный debug Info.plist разрешает HTTP.
- HTTP разрешён лишь в **debug** и лишь для loopback/private IPv4/`.local` на
  уровне Dart. Android release/profile запрещают cleartext, iOS release/profile
  используют обычный ATS без исключения. Для release обязателен HTTPS URL с
  доверенным сертификатом. Проверка сертификатов не отключается.
- **Не передавайте секреты в dart-define.** `API_BASE_URL` и подтверждённый нижний
  предел retention публичны. Токен создаётся сервером и хранится в OS secure storage.

## Восстановление и данные

Установка создаётся только при первом создании меню; при 401 автоматически не
заменяется. Сброс в настройках требует подтверждения, теряет доступ к старым
серверным заданиям, но не удаляет локальные меню. Поведение токена при
переустановке/backup зависит от ОС, гарантии удаления или восстановления нет.
На Android явно задан `AndroidOptions(resetOnError: false)` и в конструкторе,
и при операциях с credentials, включая внедрённый экземпляр storage. Повреждение
или ошибка расшифровки — ошибка подключения, не «токен отсутствует»: нет удаления,
новой установки и POST генерации. Плагин оставлен на версии 10.3.4 из lock-файла.

До POST SQLite атомарно фиксирует снимок, ключ, время и состояние операции.
При известном job_id перезапуск продолжает только GET. При неизвестном исходе
POST **не повторяется автоматически**, форма уже не меняет снимок.

Backend не сообщает настроенный retention через API. Поэтому по умолчанию
повтор неизвестного POST заблокирован. `API_MIN_RETENTION_SECONDS` — **не поле API**,
а подтверждённая оператором минимальная длительность хранения данного deployment
на протяжении операции. Указывать её можно только при такой гарантии. Локальный
launcher фиксирует 86400; для произвольного сервера default 24 часа не является
доказательством. Клиент сохраняет deadline до POST, вычитает 60 секунд запаса,
блокирует повтор после deadline и при часах раньше первой отправки. Нужны корректные
часы устройства; произвольные изменения времени не покрыты абсолютной гарантией.
При смене политики хранения неизвестную операцию надо разбирать с оператором,
не «чинить» новым ключом. Отвязка операции подтверждаема и объясняет риск дубликата.

Меню сохраняются с названиями продуктов из серверного списка покупок; каталог
для просмотра не нужен. Удаление server job/смена каталога не удаляют локальную
копию. SQLite не шифруется: содержит анкету и меню в sandbox приложения, токена
там нет. Android Auto Backup отключён; политика ОС/MDM/backup требует отдельной
проверки. Локальное удаление не обещает физического стирания из backup/носителя.

## Проверки

```bash
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
flutter build apk --debug
PYTHONDONTWRITEBYTECODE=1 /tmp/opencode/meal10-backend-venv/bin/python tools/check_contracts.py \
  --backend /home/crew/PycharmProjects/meal-budget
```

APK: `build/app/outputs/flutter-apk/app-debug.apk`.
Дополнительный `check_contracts.py` проверяет синтетические fixtures реальными
Pydantic-схемами backend, затем проверяет их как **один сценарий** через серверный
`validate_plan` и точное равенство расчёта. Есть негативные проверки числа дней,
бюджета и целей. Без `.env`, сети и DeepSeek; требуется Python-окружение backend.
Эта пара fixtures — 3 дня, 200,50 ₽, по половине двухпорционного рецепта в день
(185/6,5/3,5/31), а не отдельный demo-сценарий провайдера из раздела запуска.
Unit/widget-тесты используют MockClient, подменённый secure storage и отдельную
SQLite через FFI, без API/DeepSeek. GitHub Actions выполняет format/analyze/test.

С запущенными **локальными** тестовыми БД/API/адаптером и Android Emulator:

```bash
flutter test integration_test/local_flow_test.dart -d emulator-5554 \
  --dart-define=LOCAL_E2E=true \
  --dart-define=API_BASE_URL=http://10.0.2.2:8000 \
  --dart-define=API_MIN_RETENTION_SECONDS=86400
```

E2E создаёт отдельные тестовые secure-storage keys и файл SQLite; через UI
заполняет анкету, получает результат от реального backend, пересоздаёт клиент
и открывает меню с запрещённым HTTP, затем удаляет локальную копию. Это не
перезагрузка Android/OS-crash, не ручная оценка рецептов и не тест реального DeepSeek.
Фактически выполненные проверки и ограничения — в [STATUS](docs/STATUS.md).

### Native Android-регрессия повреждённых credentials (P1)

Только **новый отдельный AVD**, без пользовательских приложений/данных. Runner
проверяет префикс имени `MEAL10StorageRegression` и отсутствие установленного
приложения; чужой эмулятор или повторный запуск на непустом AVD отвергаются.
Для каждого полного запуска создайте новый AVD. На этой машине установлен образ
Android 37.1; путь пакета замените при использовании другого установленного образа.

Терминал 1:

```bash
export SDK="$HOME/Android/Sdk"
export AVD="MEAL10StorageRegression$(date +%s)"
"$SDK/cmdline-tools/latest/bin/avdmanager" create avd --name "$AVD" \
  --path "/tmp/opencode/$AVD" \
  --package 'system-images;android-37.1;google_apis_playstore_ps16k;x86_64' --device pixel_8
"$SDK/emulator/emulator" -avd "$AVD" -no-window -no-snapshot -gpu swiftshader \
  -feature -Vulkan -no-audio -camera-back none -camera-front none \
  -cores 2 -skin 720x1280 -dpi-device 320 -port 5580
```

Терминал 2, после завершения загрузки Android:

```bash
python3 tools/native_storage_regression.py --device emulator-5580
"$HOME/Android/Sdk/platform-tools/adb" -s emulator-5580 emu kill
flutter build apk --debug
```

Runner сам запускает локальный synthetic HTTP-recorder на `127.0.0.1:8765`.
Ни backend, ни PostgreSQL/контейнеры, ни провайдер ему не нужны. Первая native-
фаза сохраняет одну синтетическую установку реальным плагином; затем `force-stop`,
повреждение AES-GCM tag только её записи через `run-as`, повторный запуск и
проверка ошибки до контроллера/UI. Счётчики должны остаться 1 регистрация / 0 POST
генерации, запись — неизменной. `--no-uninstall` внутри runner обязателен: Flutter
3.44 по умолчанию удаляет test app после integration test и уничтожает состояние.
После проверки AVD остаётся с синтетическими данными, runner его не очищает.
Последняя команда снова собирает обычный APK, не native test entrypoint.

Приложение не копирует сырые исключения или storage в UI/логи. **Граница версии
10.3.4:** её native `handleStorageError` сам пишет диагностический stack trace в
Android logcat; публичной опции отключения этих сообщений нет. Runner не сохраняет
и не выводит сырой вывод Flutter/plugin или содержимое SharedPreferences. Плагин
не форкался, гарантия отсутствия любых native-диагностик не заявляется.

### Lifecycle-регрессии (P2)

`HomeScreen` — единственный UI-владелец внедрённого `GenerationController`.
Передача контроллера экрану передаёт владение; после удаления экрана вызывающий
код **не вызывает dispose повторно**. Rebuild с тем же контроллером, переходы
между вкладками и push/pop других экранов его не уничтожают. Замена внедрённого
контроллера освобождает прежний ровно один раз. В тестах без UI контроллером
по-прежнему владеет сам тест.

```bash
flutter test test/installation_test.dart test/generation_test.dart test/lifecycle_test.dart
```

Widget-тесты без ручного dispose удаляют приложение/владельца во время polling,
доставляют поздние running/completed/error даже вопреки abort, проверяют отсутствие
новых GET/записей/уведомлений, background/resume и сохранение уже начатой транзакции.

### Поздняя регистрация и смена владельца (оставшийся P2)

Разные `InstallationService`, обращающиеся к одному storage namespace/backend,
используют общую ревизию попыток и очередь побочных эффектов. Прежний 201 не может
перезаписать credentials нового владельца, даже если транспорт игнорирует abort.
Проверка выполняется **до write** в сервисе, не только после ensure в контроллере.
Кэша токена отдельного сервиса нет: восстановление читает актуальное хранилище.

Если отмена пришла во время уже начатой неотменяемой записи, новый владелец ждёт
завершения write и очистки именно этой неопубликованной записи. Чужие новые
credentials при такой очистке не удаляются; успешно подтверждённый токен при dispose
сохраняется для следующего запуска. Подтверждённый сброс допускается
во время регистрации: сразу отзывает старые попытки, затем упорядоченно удаляет
credentials и старую SQLite-операцию **до** допуска новой регистрации. При ошибке
storage пара namespace/backend блокируется до успешного явного сброса, без
автоматического удаления/регистрации при ошибке чтения. P1 `resetOnError: false`
и разделение адресов backend сохранены.

```bash
flutter test test/installation_races_test.dart
```

12 детерминированных регрессий с Completer-барьерами (без sleep): точный сценарий
ревью, поздний 201 без нового владельца, отмена через abort, смена владельца во время
write/контрольного read, reset во время регистрации/записи/очистки SQLite, reset из
другого экземпляра, независимость адресов, обычное восстановление и storage-errors.
Проверяются вместе credentials, installation_id операции и job_id; пересозданный
клиент делает GET с правильным Bearer. HTTP/platform storage подменены, SQLite
в этих регрессиях настоящий (FFI); это не native Android или backend E2E.

Порядок гарантируется в одном isolate приложения, если весь доступ к credentials
идёт через сервис и адаптеры сообщают одинаковый namespace. Уже начатый write может
временно физически записать прежний токен; новые владельцы не читают его до очистки.
Зависший storage не освобождает очередь по таймауту. OS-crash до завершения reset,
нарушение контракта Future storage, другие процессы/isolate и прямые записи в обход
coordinator не покрыты. Не обещается отмена серверной регистрации или возврат квоты.
Подробный порядок и границы — [ARCHITECTURE](docs/ARCHITECTURE.md).
