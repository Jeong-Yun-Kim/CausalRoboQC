"""Read-only RPF browser and CSV export with one shared filter contract."""

import csv
import json
from datetime import datetime, timezone
import io
from typing import Annotated, Any, Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import AwareDatetime


router = APIRouter(prefix="/api/data", tags=["data"])
CSV_COLUMNS = (
    "id", "marker_id", "inspection_result", "confirmed_causes", "action", "note", "inspected_at",
    "product_id", "product_group", "started_at", "finished_at", "status", "grade",
    "work_time_ms", "retry_count", "error_count", "operator_interventions",
    "anomaly_score", "inspection_risk_score", "timeseries_anomaly_score",
)


def rpf_filters(
    from_at: Annotated[AwareDatetime | None, Query(description="Inclusive timestamp with timezone")] = None,
    to_at: Annotated[AwareDatetime | None, Query(description="Exclusive timestamp with timezone")] = None,
    product_group: Annotated[str | None, Query(max_length=200)] = None,
    grade: Literal["normal", "review", "priority"] | None = None,
    product_id: Annotated[str | None, Query(max_length=200)] = None,
    limit: Annotated[int | None, Query(ge=1, le=500)] = None,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> dict[str, Any]:
    if from_at is not None and to_at is not None and from_at >= to_at:
        raise HTTPException(422, "from_at must be earlier than to_at")
    return {
        "from_at": from_at.astimezone(timezone.utc).isoformat() if from_at else None,
        "to_at": to_at.astimezone(timezone.utc).isoformat() if to_at else None,
        "product_group": product_group, "grade": grade, "product_id": product_id,
        "limit": limit, "offset": offset,
    }


@router.get("/rpf")
def browse_rpfs(request: Request, filters: Annotated[dict, Depends(rpf_filters)]) -> dict:
    """Default page size is 50. total counts all matches before pagination."""
    return request.app.state.service.database.browse_rpfs(
        **{**filters, "limit": filters["limit"] or 50}
    )


@router.get("/rpf.csv")
def export_rpfs(request: Request, filters: Annotated[dict, Depends(rpf_filters)]) -> StreamingResponse:
    """Omit limit/offset to download ALL matches; explicit pagination is honored."""
    rows = request.app.state.service.database.browse_rpfs(**filters)["items"]

    def content():
        yield "\ufeff"  # UTF-8 BOM for Korean Excel.
        buffer = io.StringIO(newline="")
        writer = csv.DictWriter(buffer, fieldnames=CSV_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        yield buffer.getvalue()
        for row in rows:
            buffer.seek(0)
            buffer.truncate(0)
            row = {**row, "confirmed_causes": json.dumps(row["confirmed_causes"], ensure_ascii=False)}
            # User-entered inspection text must remain literal in spreadsheet software.
            row = {key: "'" + value if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@"))
                   else value for key, value in row.items()}
            writer.writerow(row)  # None is an empty CSV cell; scores are never invented.
            yield buffer.getvalue()

    filename = f"causalroboqc_rpf_{datetime.now(timezone.utc):%Y%m%d}.csv"
    return StreamingResponse(content(), media_type="text/csv; charset=utf-8", headers={
        "Content-Disposition": f'attachment; filename="{filename}"',
        "Cache-Control": "no-store",
    })
