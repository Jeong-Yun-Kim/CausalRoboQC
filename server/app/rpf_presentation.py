"""Read-only operator guidance derived from recorded evidence, never a diagnosis."""

from .analysis_client import pose_sequence


GRADES = {"normal": "정상", "review": "확인 필요", "priority": "우선검사"}
SCORES = {"anomaly_score": "공정 이상도", "inspection_risk_score": "검사 위험도",
          "timeseries_anomaly_score": "공정 단계 시간 이상도"}


def presentation(record: dict, events: list[dict], analysis: dict | None) -> dict:
    sequence = pose_sequence(events, record.get("cycle_index"))
    stages = [{"name": name, "duration_ms": value} for name, value in (sequence or {}).items()]
    names = {event["name"] for event in events}
    checks = []
    if record["retry_count"]:
        checks.append("집기 재시도 시점의 제품 투입 위치와 그리퍼 파지 위치·각도를 확인하세요.")
    if names & {"PLACE_FAILURE_INJECTED", "PLACE_FAILED", "PLACE_TIMEOUT"}:
        checks.append("배치 실패 기록의 목표 위치와 RELEASE 단계 전후 작업 이력을 확인하세요.")
    if record["error_count"]:
        checks.append("오류 발생 시각의 명령 응답과 장치 연결 이력을 확인하세요.")
    if record["operator_interventions"]:
        checks.append("작업자 개입 시점과 변경한 설정·조치 내용을 대조하세요.")
    if names & {"WORK_TIME_OVERRUN_INJECTED", "WORK_TIME_EXCEEDED"}:
        checks.append("단계별 소요시간을 비교하고 지연된 단계의 작업 이력을 확인하세요.")
    if not checks:
        checks.append("저장된 공정 순서와 단계별 소요시간, 규칙 기반 판정 근거를 확인하세요.")
    reasons = ", ".join(record["grade_reasons"]) or "기록된 이상 근거 없음"
    elapsed = record.get("work_time_ms")
    lines = [f"품질보고서 초안 · {record['product_id']}",
             f"제품군: {record.get('product_group') or '미지정'}",
             f"규칙 기반 등급: {GRADES.get(record['grade'], '미분류')}",
             f"판정 근거: {reasons}",
             f"완료 시각 (UTC): {record.get('finished_at') or '완료 전'}",
             f"작업시간: {elapsed / 1000:.3f}초" if elapsed is not None else "작업시간: 기록 없음",
             f"재시도 {record['retry_count']}회 · 오류 {record['error_count']}건 · 작업자 개입 {record['operator_interventions']}회"]
    for key, label in SCORES.items():
        value = (analysis or {}).get(key)
        lines.append(f"{label}: {value:.6g} (0~1)" if value is not None else f"{label}: 분석 결과 없음")
    lines.extend(["권장 점검 순서:", *[f"{index}. {check}" for index, check in enumerate(checks, 1)],
                  "보조 점수는 규칙 기반 등급을 변경하지 않으며 실제 검사 PASS/FAIL을 뜻하지 않습니다.",
                  "점검 안내는 기록에 따른 확인 항목입니다. 원인 확정이나 검사 판정은 포함하지 않습니다."])
    return {"stages": stages, "recommended_checks": checks, "report_draft": "\n".join(lines)}
