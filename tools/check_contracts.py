"""Проверка синтетических Dart fixtures реальными Pydantic-схемами backend, без .env."""

import argparse
from decimal import Decimal
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--backend", type=Path, default=Path("/home/crew/PycharmProjects/meal-budget"))
args = parser.parse_args()
sys.dont_write_bytecode = True
sys.path.insert(0, str(args.backend.resolve()))

from meal_budget.schemas.generation import GenerationRequest
from meal_budget.schemas.jobs import JobStatus
from meal_budget.catalog import load_catalog
from meal_budget.services.menu_generation import validate_plan

root = Path(__file__).resolve().parents[1] / "test/fixtures"
request = GenerationRequest.model_validate_json((root / "request.json").read_text())
job = JobStatus.model_validate_json((root / "completed.json").read_text())
catalog = load_catalog(args.backend / "tests/fixtures/products.json")
result = job.result
assert result is not None and job.state == "completed"
calculation, violations = validate_plan(result.plan, request, catalog, result.nutrition_tolerance)
assert not violations, "План fixtures не проходит ограничения исходной анкеты"
assert calculation == result.calculation, "Расчёт fixture отличается от точного расчёта backend"
assert result.catalog_version == catalog.catalog_version == job.catalog_version
assert len(result.plan.days) == request.days
assert result.calculation.budget == request.budget

# Ensure this checks scenario constraints, not merely independent JSON schemas.
for changed in [
    request.model_copy(update={"days": 7}),
    request.model_copy(update={"budget": Decimal("1")}),
    request.model_copy(update={"daily_targets": request.daily_targets.model_copy(update={"protein_g": Decimal("100")})}),
]:
    _, violations = validate_plan(result.plan, changed, catalog, result.nutrition_tolerance)
    assert violations, "Негативная проверка ограничений не сработала"
print("Fixtures одного сценария: схемы, validate_plan, точный расчёт и негативные проверки пройдены.")
