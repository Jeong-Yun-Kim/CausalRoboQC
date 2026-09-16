"""Deterministic intent routing and read-only queries over existing RPF data."""

from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
import math
from pathlib import Path
import re

from .analysis_client import pose_sequence
from .database import Database
from .rpf_presentation import presentation


NO_DATA = "현재 데이터에서 확인할 수 없습니다."
GRADES = {"normal": "정상", "review": "확인 필요", "priority": "우선검사"}
METRICS = {
    "work_time_ms": ("작업시간", "s", 1000),
    "anomaly_score": ("공정 이상도", "", 1),
    "inspection_risk_score": ("검사 위험도", "", 1),
    "timeseries_anomaly_score": ("공정 단계 시간 이상도", "", 1),
}
KST = timezone(timedelta(hours=9))
KNOWLEDGE = Path(__file__).with_name("knowledge")


@dataclass
class Intent:
    name: str = "GENERAL"
    product_ids: list[str] = field(default_factory=list)
    groups: list[str] = field(default_factory=list)
    filters: dict = field(default_factory=dict)
    metric: str = "anomaly_score"
    limit: int = 20
    chart: bool = False
    by_group: bool = False
    grade_trend: bool = False
    abnormal: bool = False
    topic: str = ""
    clarification: str | None = None


def route(question: str, now: datetime | None = None) -> Intent:
    now = now or datetime.now(timezone.utc)
    q = question.strip()
    intent = Intent(chart=bool(re.search(r"그래프|차트", q)))
    if re.search(r"(변경|수정|삭제|재학습|실행|제어).*(해줘|해 줘|해$)|SQL", q, re.I):
        intent.clarification = "코파일럿은 저장된 데이터 설명과 사용법 안내만 제공합니다."
        return intent
    intent.product_ids = list(dict.fromkeys(re.findall(
        r"(?<![\w-])([A-Za-z가-힣][A-Za-z가-힣0-9]*(?:-[A-Za-z0-9]+)*-\d+)", q)))
    if len(intent.product_ids) > 5:
        intent.clarification = "한 번에 비교할 제품 ID를 5개 이하로 입력해주세요."
        return intent
    for key in ("timeseries_anomaly_score", "inspection_risk_score", "work_time_ms", "anomaly_score"):
        if METRICS[key][0].replace(" ", "") in q.replace(" ", ""):
            intent.metric = key
            break
    if "작업 시간" in q:
        intent.metric = "work_time_ms"
    if intent.chart and not re.search(r"작업\s*시간|이상도|공정\s*이상|위험도|등급", q):
        intent.clarification = "작업시간, 공정 이상도, 검사 위험도 또는 등급처럼 그래프로 볼 지표를 입력해주세요."
        return intent
    intent.groups = list(dict.fromkeys(re.findall(r"([\w-]+)\s+제품군(?!별)", q)))
    # Also allow the compact form 'A제품군'. Do not treat '제품군별' as a filter.
    if not intent.groups:
        intent.groups = list(dict.fromkeys(re.findall(r"([A-Za-z0-9_-]+)제품군(?!별)", q)))
    if len(intent.groups) == 1:
        intent.filters["product_group"] = intent.groups[0]
    intent.by_group = "제품군별" in q or len(intent.groups) >= 2
    for value, label in GRADES.items():
        if label.replace(" ", "") in q.replace(" ", ""):
            intent.filters["grade"] = value
    intent.abnormal = bool(re.search(r"이상\s*제품|공통점", q))
    limit = re.search(r"(\d+)\s*(?:개|건)", q)
    if limit:
        intent.limit = min(50, max(1, int(limit[1])))
    try:
        dates = re.findall(r"\d{4}-\d{2}-\d{2}", q)
        if dates:
            if len(dates) > 2:
                raise ValueError()
            start = datetime.fromisoformat(dates[0]).replace(tzinfo=KST)
            end = datetime.fromisoformat(dates[-1]).replace(tzinfo=KST) + timedelta(days=1)
            if end <= start:
                raise ValueError()
            intent.filters.update(from_at=start.isoformat(), to_at=end.isoformat())
        else:
            period = re.search(r"(?:최근|지난)\s*(\d+)\s*(일|주)", q)
            if period:
                days = int(period[1]) * (7 if period[2] == "주" else 1)
                if not 1 <= days <= 3660:
                    raise ValueError()
                intent.filters.update(from_at=(now - timedelta(days=days)).isoformat(), to_at=now.isoformat())
            elif "오늘" in q or "어제" in q:
                start = now.astimezone(KST).replace(hour=0, minute=0, second=0, microsecond=0)
                if "어제" in q:
                    start -= timedelta(days=1)
                intent.filters.update(from_at=start.isoformat(), to_at=(start + timedelta(days=1)).isoformat())
            elif re.search(r"최근|지난", q) and not limit and not intent.product_ids:
                intent.filters.update(from_at=(now - timedelta(days=7)).isoformat(), to_at=now.isoformat())
    except ValueError:
        intent.clarification = "기간을 YYYY-MM-DD 형식 또는 최근 7일처럼 입력해주세요."
        return intent
    if re.search(r"\d+\s*(개월|달)|지난달|이번달|지난해|올해", q):
        intent.clarification = "조회할 시작일과 종료일을 YYYY-MM-DD 형식으로 입력해주세요."
        return intent
    help_requested = bool(re.search(r"어떻게|사용|방법|뭐야|무엇|뜻|차이가|의미", q))
    if not intent.product_ids and (help_requested or "CSV" in q.upper()):
        intent.name = "USAGE_HELP"
        intent.topic = ("data_browser" if "CSV" in q.upper() or "데이터 조회" in q else
                        "robot_control" if "반복" in q or "로봇" in q or "실행" in q else
                        "dashboard" if "대시보드" in q else
                        "quality" if "품질관리" in q else "terminology")
    elif len(intent.product_ids) > 1 or "비교" in q:
        intent.name = "PRODUCT_COMPARE"
        if len(intent.product_ids) < 2 and len(intent.groups) < 2:
            intent.clarification = "비교할 제품 ID 두 개 또는 제품군 두 개를 입력해주세요."
    elif intent.product_ids:
        intent.name = ("PRODUCT_REPORT" if "보고서" in q else
                       "PRODUCT_CHECKS" if re.search(r"점검|조치|확인 순서", q) else "PRODUCT_DETAIL")
    elif "등급" in q and re.search(r"추세|추이", q):
        intent.name, intent.grade_trend = "METRIC_TREND", True
    elif "등급별" in q or "등급 분포" in q:
        intent.name = "GRADE_DISTRIBUTION"
    elif intent.chart or re.search(r"추세|추이", q) or intent.by_group:
        intent.name = "METRIC_TREND"
    elif re.search(r"높은|높아|상위|가장", q):
        intent.name = "TOP_PRODUCTS"
        if not limit:
            intent.limit = 5
    elif "요약" in q or "분석" in q or "공통점" in q:
        intent.name = "PERIOD_SUMMARY"
    elif re.search(r"제품|목록", q) or "grade" in intent.filters:
        intent.name = "PRODUCT_SEARCH"
    if intent.name == "PRODUCT_SEARCH" and re.search(r"이 제품|이제품", q):
        intent.clarification = "설명할 제품 ID를 입력해주세요."
    return intent


def metric_value(row: dict, metric: str):
    value = row.get(metric)
    if not isinstance(value, (float, int)) or not math.isfinite(value):
        return None
    return value / METRICS[metric][2]


def number(value) -> str:
    return "분석 결과 없음" if value is None else f"{value:.6g}"


class CopilotQueries:
    """No caller-supplied SQL, writes, inference, or rule re-evaluation."""

    def __init__(self, database: Database):
        self.db = database

    def search_products(self, filters: dict) -> list[dict]:
        return self.db.browse_rpfs(**filters)["items"]

    def get_product(self, product_id: str) -> dict | None:
        # Existing browser is substring-based; enforce exact identity afterwards.
        matches = self.search_products({"product_id": product_id})
        return next((row for row in matches if row["product_id"].casefold() == product_id.casefold()), None)

    def compare_products(self, product_ids: list[str]) -> list[dict | None]:
        return [self.get_product(product_id) for product_id in product_ids]

    def get_top_products(self, metric: str, rows: list[dict], limit: int) -> list[dict]:
        if metric not in METRICS:
            raise ValueError("Unsupported metric")
        return sorted((row for row in rows if metric_value(row, metric) is not None),
                      key=lambda row: metric_value(row, metric), reverse=True)[:limit]

    def get_grade_distribution(self, rows: list[dict]) -> dict:
        counts = Counter(GRADES.get(row["grade"], "미분류") for row in rows)
        labels = list(GRADES.values()) + (["미분류"] if "미분류" in counts else [])
        return {"type": "bar", "title": "등급별 제품 수", "labels": labels,
                "series": [{"name": "제품 수", "values": [counts[label] for label in labels]}], "unit": "건"}

    def get_metric_trend(self, intent: Intent, rows: list[dict]) -> dict:
        label, unit, _ = METRICS[intent.metric]
        if intent.grade_trend:
            counts = defaultdict(Counter)
            for row in rows:
                if row["finished_at"]:
                    date = datetime.fromisoformat(row["finished_at"].replace("Z", "+00:00")).astimezone(KST)
                    counts[date.strftime("%Y-%m-%d")][GRADES.get(row["grade"], "미분류")] += 1
            dates = sorted(counts)[-50:]
            grades = list(GRADES.values()) + (["미분류"] if any("미분류" in c for c in counts.values()) else [])
            return {"type": "line", "title": "최근 등급 추세 (완료일 · 한국 시간, 최대 50일)", "labels": dates,
                    "series": [{"name": grade, "values": [counts[day][grade] for day in dates]} for grade in grades], "unit": "건"}
        if intent.by_group:
            groups = defaultdict(list)
            for row in rows:
                groups[row["product_group"] or "미지정"].append(metric_value(row, intent.metric))
            labels = sorted(groups)[:50]
            values = []
            for group in labels:
                valid = [value for value in groups[group] if value is not None]
                values.append(math.fsum(valid) / len(valid) if valid else None)
            return {"type": "bar", "title": f"제품군별 평균 {label} (최대 50개 제품군)", "labels": labels,
                    "series": [{"name": f"평균 {label}", "values": values}], "unit": unit}
        selected = rows[:intent.limit]
        # Series ordered from oldest to newest; null remains a gap, never zero.
        selected = list(reversed(selected))
        return {"type": "line", "title": f"최근 {len(selected)}개 제품 {label} (완료 시각 순)",
                "labels": [row["product_id"] for row in selected],
                "series": [{"name": label, "values": [metric_value(row, intent.metric) for row in selected]}], "unit": unit}

    def summarize_period(self, rows: list[dict]) -> list[str]:
        counts = Counter(row["grade"] for row in rows)
        sentences = [f"조회된 제품은 {len(rows)}건입니다. " + ", ".join(
            f"{label} {counts[grade]}건" for grade, label in GRADES.items()) + "입니다."]
        if counts[None]:
            sentences.append(f"아직 등급이 없는 제품은 {counts[None]}건입니다.")
        for metric, (label, unit, _) in METRICS.items():
            values = [metric_value(row, metric) for row in rows]
            valid = [value for value in values if value is not None]
            if valid:
                sentences.append(f"{label} 평균은 {number(math.fsum(valid) / len(valid))}{unit}이며, 값이 저장된 {len(valid)}건 기준입니다.")
        abnormal = [row for row in rows if row["grade"] in ("review", "priority")]
        if abnormal:
            counts = Counter(reason for row in abnormal for reason in self.db.get_rpf(row["id"])["grade_reasons"])
            if counts:
                sentences.append("확인 필요·우선검사 제품의 저장된 판정 근거: " + ", ".join(
                    f"{reason} ({count}건)" for reason, count in counts.most_common(5)) + ".")
        return sentences

    def get_usage_help(self, topic: str) -> list[str]:
        if topic not in {"dashboard", "robot_control", "quality", "data_browser", "terminology"}:
            return []
        return [part.strip() for part in (KNOWLEDGE / f"{topic}.md").read_text(encoding="utf-8").split("\n\n")
                if part.strip() and not part.startswith("#")]

    def demo_data(self, rows: list[dict]) -> bool:
        ids = {row["id"] for row in rows}
        with self.db.lock:
            demo_ids = self.db.connection.execute(
                "SELECT DISTINCT rpf_id FROM events WHERE name=? AND raw=?",
                ("DEMO_RPF_SEEDED", "causalroboqc:seed_demo_rpf:v1"),
            ).fetchall()
        return any(row[0] in ids for row in demo_ids)

    def product_table(self, rows: list[dict]) -> dict:
        return {"columns": ["제품 ID", "제품군", "등급", "작업시간 (s)", "공정 이상도", "검사 위험도", "공정 단계 시간 이상도", "주요 근거"],
                "rows": [[row["product_id"], row["product_group"], GRADES.get(row["grade"], "미분류"),
                          metric_value(row, "work_time_ms"), row["anomaly_score"], row["inspection_risk_score"], row["timeseries_anomaly_score"],
                          ", ".join(self.db.get_rpf(row["id"])["grade_reasons"]) or "기록된 근거 없음"] for row in rows]}

    def prepare(self, question: str, now: datetime | None = None) -> dict:
        intent = route(question, now)
        result = {"answer": "", "table": None, "chart": None, "demo_data": False,
                  "intent": intent.name, "facts": [], "required_fact_ids": []}

        def fact(text: str, required: bool = False):
            ident = f"f{len(result['facts'])}"
            result["facts"].append({"id": ident, "text": text})
            if required:
                result["required_fact_ids"].append(ident)

        if intent.clarification:
            result["answer"] = intent.clarification
            return result
        if intent.name == "GENERAL":
            result["answer"] = "제품 ID, 조회 기간 또는 앱 사용법을 질문해주세요."
            return result
        if intent.name == "USAGE_HELP":
            for text in self.get_usage_help(intent.topic):
                fact(text)
            return result
        if intent.product_ids:
            matches = self.compare_products(intent.product_ids)
            if any(row is None for row in matches):
                result["answer"] = NO_DATA
                return result
            rows = matches
        else:
            rows = self.search_products(intent.filters)
            if intent.groups:
                rows = [row for row in rows if row["product_group"] in intent.groups]
                if any(not any(row["product_group"] == group for row in rows) for group in intent.groups):
                    result["answer"] = NO_DATA
                    return result
            if intent.abnormal:
                rows = [row for row in rows if row["grade"] in ("review", "priority")]
        if not rows:
            result["answer"] = NO_DATA
            return result
        result["demo_data"] = self.demo_data(rows)
        if intent.filters and not intent.product_ids:
            scope = []
            if "from_at" in intent.filters:
                start = datetime.fromisoformat(intent.filters["from_at"]).astimezone(KST)
                end = datetime.fromisoformat(intent.filters["to_at"]).astimezone(KST)
                scope.append(f"완료 시각 {start:%Y-%m-%d %H:%M}부터 {end:%Y-%m-%d %H:%M} 전까지 (한국 시간)")
            if "product_group" in intent.filters:
                scope.append(f"제품군 {intent.filters['product_group']}")
            if "grade" in intent.filters:
                scope.append(f"등급 {GRADES[intent.filters['grade']]}")
            fact("조회 범위: " + "; ".join(scope) + ".", True)
        elif not intent.product_ids:
            fact("전체 저장 데이터 기준입니다.", True)
        if intent.name in {"PRODUCT_DETAIL", "PRODUCT_COMPARE", "PRODUCT_REPORT", "PRODUCT_CHECKS"} and intent.product_ids:
            result["table"] = self.product_table(rows)
            for row in rows:
                record = self.db.get_rpf(row["id"])
                fact(f"{row['product_id']}의 저장된 등급은 {GRADES.get(row['grade'], '미분류')}입니다. "
                     + ("판정 근거는 " + ", ".join(record["grade_reasons"]) + "입니다."
                        if record["grade_reasons"] else "기록된 판정 근거가 없습니다."), True)
                fact(f"{row['product_id']}: 작업시간 {number(metric_value(row, 'work_time_ms'))}s, "
                     f"재시도 {row['retry_count']}회, 오류 {row['error_count']}회, 수동 개입 {row['operator_interventions']}회.")
                events = self.db.list_rpf_events(row["id"])
                stages = [event["payload"].get("pose") for event in events if event["name"] == "POSE_FINISHED"]
                if stages:
                    fact(f"{row['product_id']}의 기록된 완료 단계: " + " → ".join(str(s) for s in stages[:32]) + ".")
                durations = pose_sequence(events, record["cycle_index"])
                if durations:
                    fact(f"{row['product_id']}의 단계별 소요시간: " + ", ".join(
                        f"{stage} {number(value / 1000)}s" for stage, value in durations.items()) + ".")
                analysis = self.db.get_analysis_result(row["id"])
                if intent.name in {"PRODUCT_REPORT", "PRODUCT_CHECKS"}:
                    guidance = presentation(record, events, analysis)
                    if intent.name == "PRODUCT_REPORT":
                        fact(guidance["report_draft"], True)
                    else:
                        fact("권장 점검 순서:\n" + "\n".join(
                            f"{i}. {check}" for i, check in enumerate(guidance["recommended_checks"], 1))
                            + "\n기록에 따른 확인 항목이며 원인을 확정하지 않습니다.", True)
                if analysis:
                    fact(f"{row['product_id']}: " + ", ".join(
                        f"{METRICS[key][0]} {number(analysis.get(key))}" for key in METRICS if key != "work_time_ms") + ".")
                    fact("저장된 점수만으로 개별 특징의 기여도나 인과 원인은 확인할 수 없습니다. 보조 분석 점수는 규칙 기반 등급을 변경하지 않습니다.", True)
            if len(rows) == 2:
                for metric, (label, unit, _) in METRICS.items():
                    a, b = (metric_value(row, metric) for row in rows)
                    if a is not None and b is not None:
                        fact(f"{rows[0]['product_id']}에서 {rows[1]['product_id']}을 뺀 {label} 차이는 {number(a - b)}{unit}입니다.")
            if intent.chart:
                label, unit, _ = METRICS[intent.metric]
                result["chart"] = {"type": "bar", "title": f"제품별 {label}",
                                   "labels": [row["product_id"] for row in rows],
                                   "series": [{"name": label, "values": [metric_value(row, intent.metric) for row in rows]}],
                                   "unit": unit}
        elif intent.name == "PERIOD_SUMMARY":
            for text in self.summarize_period(rows):
                fact(text)
            result["table"] = self.product_table(rows[:intent.limit])
            fact(f"표에는 최근 {min(len(rows), intent.limit)}건을 표시합니다. 요약은 조회 범위 전체 기준입니다.", True)
        elif intent.name in {"METRIC_TREND", "GRADE_DISTRIBUTION", "PRODUCT_COMPARE"}:
            chart = (self.get_grade_distribution(rows) if intent.name == "GRADE_DISTRIBUTION"
                     else self.get_metric_trend(intent, rows))
            result["chart"] = chart
            result["table"] = {"columns": ["구분", *[series["name"] for series in chart["series"]]],
                               "rows": [[label, *[series["values"][i] for series in chart["series"]]]
                                        for i, label in enumerate(chart["labels"])]}
            fact(f"{chart['title']}입니다. 단위: {chart['unit'] or '점수 (0~1)'}.", True)
            for series in chart["series"]:
                valid = [(value, label) for value, label in zip(series["values"], chart["labels"]) if value is not None]
                if valid:
                    maximum = max(value for value, _ in valid)
                    labels = [label for value, label in valid if value == maximum]
                    fact(f"{series['name']}의 최댓값은 {number(maximum)}{chart['unit']}이며, "
                         + ", ".join(labels[:5]) + (" 등" if len(labels) > 5 else "") + "에서 관찰됩니다.")
                if chart["type"] == "line" and len(valid) >= 2:
                    first, last = valid[0], valid[-1]
                    fact(f"{series['name']}: 값이 있는 첫 항목 {first[1]}은 {number(first[0])}{chart['unit']}, "
                         f"마지막 항목 {last[1]}은 {number(last[0])}{chart['unit']}입니다. "
                         f"마지막 값에서 첫 값을 뺀 차이는 {number(last[0] - first[0])}{chart['unit']}입니다.")
            if intent.by_group:
                fact("제품군 평균은 해당 값이 저장된 제품만 포함합니다. 값이 없는 제품군은 빈칸으로 표시합니다.", True)
            if all(value is None for series in chart["series"] for value in series["values"]):
                result["answer"] = "분석 결과 없음\n" + NO_DATA
                result["chart"] = None
        else:
            selected = (self.get_top_products(intent.metric, rows, intent.limit)
                        if intent.name == "TOP_PRODUCTS" else rows[:intent.limit])
            if not selected:
                result["answer"] = "분석 결과 없음\n" + NO_DATA
                return result
            result["table"] = self.product_table(selected)
            fact(f"조건에 맞는 제품 {len(rows)}건 중 "
                 + (f"{METRICS[intent.metric][0]}가 높은 순으로 " if intent.name == "TOP_PRODUCTS" else "최근 순으로 ")
                 + f"{len(selected)}건을 표시합니다.", True)
        missing = sum(row["anomaly_score"] is None for row in rows)
        if missing:
            fact(f"조회 제품 중 {missing}건은 분석 결과 없음 상태입니다. 저장되지 않은 점수를 추정하지 않습니다.", True)
        return result
