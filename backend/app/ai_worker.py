"""Small durable worker for grade AI jobs; no broker or web request required."""
from __future__ import annotations

import asyncio
import os
import socket
import uuid

from app.ai_jobs import claim_next_job, execute_job
from app.db import SessionLocal


POLL_SECONDS = 1.0


async def run_once(worker_id: str) -> bool:
    async with SessionLocal() as db:
        job_id = await claim_next_job(db, worker_id=worker_id)
    if job_id is None:
        return False
    async with SessionLocal() as db:
        await execute_job(db, worker_id=worker_id, job_id=job_id)
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
