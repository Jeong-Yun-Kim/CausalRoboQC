"""Best-effort auxiliary analysis for newly completed RPFs."""

import asyncio
import logging

from .analysis_client import AnalysisClient, AnalysisError
from .database import Database


logger = logging.getLogger(__name__)


class RpfAnalysisService:
    def __init__(self, database: Database, client: AnalysisClient):
        self.database = database
        self.client = client
        self._tasks: dict[int, asyncio.Task[None]] = {}

    def is_pending(self, rpf_id: int) -> bool:
        task = self._tasks.get(rpf_id)
        return task is not None and not task.done()

    async def analyze(self, rpf_id: int) -> dict:
        """Shared by automatic analysis and the manual debugging API."""
        record = self.database.get_rpf(rpf_id)
        if record is None:
            raise AnalysisError(404, "RPF not found")
        if record["status"] != "completed":
            raise AnalysisError(409, "완료된 RPF만 분석할 수 있습니다.")
        result = await self.client.analyze(record, self.database.list_rpf_events(rpf_id))
        # Only analysis_results is written; the rule-based RPF stays intact.
        return self.database.save_analysis_result(result)

    def schedule(self, rpf_id: int) -> None:
        if self.is_pending(rpf_id):
            return
        task = asyncio.create_task(self._analyze_safely(rpf_id), name=f"rpf-analysis-{rpf_id}")
        self._tasks[rpf_id] = task
        task.add_done_callback(lambda finished: self._forget(rpf_id, finished))

    def _forget(self, rpf_id: int, task: asyncio.Task[None]) -> None:
        if self._tasks.get(rpf_id) is task:
            del self._tasks[rpf_id]

    async def _analyze_safely(self, rpf_id: int) -> None:
        try:
            await self.analyze(rpf_id)
        except Exception:
            # Laptop outages, invalid responses and storage errors must not
            # affect robot completion or erase a previously saved result.
            logger.warning("Automatic analysis failed for RPF %s", rpf_id, exc_info=True)

    async def shutdown(self) -> None:
        tasks = list(self._tasks.values())
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._tasks.clear()
