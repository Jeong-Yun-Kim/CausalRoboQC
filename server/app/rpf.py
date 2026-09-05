import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .database import Database, utc_now


def generate_product_id(sequence: int) -> str:
    """Temporary product identity provider; replace here when camera IDs arrive."""
    return f"P-{sequence:03d}"


@dataclass(frozen=True)
class GradeResult:
    grade: str
    reasons: list[str]
    retry_count: int
    error_count: int
    operator_interventions: int


class RpfRules:
    def __init__(self, path: Path):
        with path.open("r", encoding="utf-8") as file:
            rules = json.load(file)
        self.retry_events: dict[str, str] = rules.get("retry_events", {})
        self.review_events: dict[str, str] = rules.get("review_events", {})
        self.priority_events: dict[str, str] = rules.get("priority_events", {})
        self.error_events: set[str] = set(rules.get("error_events", []))
        self.operator_events: set[str] = set(
            rules.get("operator_intervention_events", [])
        )
        self.failed_reason = str(rules.get("failed_reason", "사이클 실행 실패"))

    @staticmethod
    def _append_once(values: list[str], value: str) -> None:
        if value and value not in values:
            values.append(value)

    def evaluate(self, status: str, events: list[dict[str, Any]]) -> GradeResult:
        names = [str(event.get("name", "")) for event in events]
        retry_count = sum(name in self.retry_events for name in names)
        error_count = sum(name in self.error_events for name in names)
        operator_interventions = sum(name in self.operator_events for name in names)
        if status != "completed" and error_count == 0:
            error_count = 1

        review_reasons: list[str] = []
        priority_reasons: list[str] = []
        if retry_count == 1:
            self._append_once(review_reasons, "집기 재시도 1회")
        elif retry_count >= 2:
            self._append_once(priority_reasons, f"집기 재시도 {retry_count}회")

        for name in names:
            if name in self.review_events:
                self._append_once(review_reasons, self.review_events[name])
            if name in self.priority_events:
                self._append_once(priority_reasons, self.priority_events[name])

        if operator_interventions:
            self._append_once(priority_reasons, "작업자 수동 개입")
        if status != "completed":
            self._append_once(priority_reasons, self.failed_reason)

        reasons = priority_reasons + [
            reason for reason in review_reasons if reason not in priority_reasons
        ]
        grade = (
            "priority"
            if priority_reasons
            else "review"
            if review_reasons
            else "normal"
        )
        return GradeResult(
            grade=grade,
            reasons=reasons,
            retry_count=retry_count,
            error_count=error_count,
            operator_interventions=operator_interventions,
        )


class RpfPipeline:
    def __init__(self, database: Database, rules_path: Path):
        self.database = database
        self.rules = RpfRules(rules_path)
        self._next_product_sequence = database.next_rpf_sequence()

    def start_cycle(self, run_id: int, cycle_index: int) -> dict[str, Any]:
        product_id = generate_product_id(self._next_product_sequence)
        self._next_product_sequence += 1
        return self.database.create_rpf(run_id, cycle_index, product_id)

    @staticmethod
    def _elapsed_from_timestamp(started_at: str) -> int:
        try:
            started = datetime.fromisoformat(started_at.replace("Z", "+00:00"))
            elapsed = datetime.now(timezone.utc) - started
            return max(0, round(elapsed.total_seconds() * 1000))
        except (TypeError, ValueError):
            return 0

    def finish_cycle(
        self,
        rpf_id: int,
        status: str,
        elapsed_ms: int | None,
    ) -> dict[str, Any] | None:
        record = self.database.get_rpf(rpf_id)
        if record is None or record["status"] != "running":
            return record
        events = self.database.list_rpf_events(rpf_id)
        result = self.rules.evaluate(status, events)
        work_time_ms = (
            max(0, elapsed_ms)
            if elapsed_ms is not None
            else self._elapsed_from_timestamp(str(record["started_at"]))
        )
        return self.database.finish_rpf(
            rpf_id,
            status=status,
            finished_at=utc_now(),
            work_time_ms=work_time_ms,
            retry_count=result.retry_count,
            error_count=result.error_count,
            operator_interventions=result.operator_interventions,
            grade=result.grade,
            grade_reasons=result.reasons,
        )
