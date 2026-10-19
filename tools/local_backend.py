"""Без .env и DeepSeek: launcher read-only backend и адаптер его demo-провайдера."""

import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("migrate", "api", "provider"))
    parser.add_argument("--backend", type=Path, default=Path("/home/crew/PycharmProjects/meal-budget"))
    parser.add_argument("--days", type=int, choices=(3, 7), default=3)
    parser.add_argument("--host", choices=("127.0.0.1", "0.0.0.0"), default="127.0.0.1")
    args = parser.parse_args()
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(args.backend.resolve()))

    import uvicorn

    if args.mode == "provider":
        # Reuse the existing fixed provider, not another model implementation.
        spec = importlib.util.spec_from_file_location("synthetic_provider", args.backend / "tools/local_generation_provider.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        from fastapi import FastAPI

        app = FastAPI()

        @app.post("/chat/completions")
        async def completion():
            response = await module.completion()
            content = response["choices"][0]["message"]["content"]
            plan = json.loads(content)
            day = plan["days"][0]
            plan["days"] = [dict(copy.deepcopy(day), day=i) for i in range(1, args.days + 1)]
            response["choices"][0]["message"]["content"] = json.dumps(plan)
            return response

        uvicorn.run(app, host="127.0.0.1", port=9001, access_log=False)
        return

    # Only an explicitly named, separate loopback test DB. No .env/settings dumps.
    url = os.environ.get("GENERATION_JOBS_DATABASE_URL", "")
    parsed = urlparse(url)
    if parsed.hostname not in ("127.0.0.1", "localhost") or parsed.path != "/meal10_test":
        raise SystemExit("Нужен loopback URL отдельной БД meal10_test через окружение.")
    if args.mode == "migrate":
        from meal_budget.migrate_jobs import migrate
        migrate(url)
        print("Тестовые миграции применены.")
        return

    from meal_budget.core.config import Settings
    from main import create_app
    settings = Settings(
        _env_file=None,
        app_environment="test",
        catalog_path=args.backend / "data/products.json",
        generation_http_enabled=True,
        generation_app_enabled=True,
        generation_access_token="local-test-only",
        generation_jobs_database_url=url,
        generation_jobs_retention_seconds=86400,
        deepseek_api_key="local-fake-key",
        deepseek_model="local-test",
        deepseek_base_url="http://127.0.0.1:9001",
        deepseek_thinking="disabled",
    )
    uvicorn.run(create_app(settings), host=args.host, port=8000, workers=1, access_log=False)


if __name__ == "__main__":
    main()
