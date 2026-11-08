"""Small durable worker for grade AI jobs; no broker or web request required."""
from __future__ import annotations

import asyncio
import logging
import os
import socket
import uuid

from app.ai_jobs import claim_next_job, execute_job
from app.db import SessionLocal


POLL_SECONDS = 1.0
logger = logging.getLogger(__name__)


async def run_once(worker_id: str) -> bool:
    try:
        async with SessionLocal() as db:
            job_id = await claim_next_job(db, worker_id=worker_id)
    except Exception:
        logger.exception("AI job worker could not claim work")
        return False
    if job_id is None:
        return False
    try:
        async with SessionLocal() as db:
            await execute_job(db, worker_id=worker_id, job_id=job_id)
    except asyncio.CancelledError:
        raise
    except Exception:
        # Do not let a database/ORM defect terminate the worker. The lease
        # becomes `unknown` after expiry instead of risking a duplicate call.
        logger.exception("AI job worker could not finish job %s", job_id)
        return False
    return True


async def run_forever() -> None:
    worker_id = f"{socket.gethostname()}-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    while True:
        worked = await run_once(worker_id)
        if not worked:
            await asyncio.sleep(POLL_SECONDS)


def main() -> None:
    try:
        asyncio.run(run_forever())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
