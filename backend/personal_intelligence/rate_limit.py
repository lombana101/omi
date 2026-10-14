from __future__ import annotations

import asyncio
import time
from collections.abc import Awaitable, Callable


class AsyncRateLimiter:
    """A fair, process-local limiter with no initial burst."""

    def __init__(
        self,
        requests_per_second: float,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ) -> None:
        if requests_per_second <= 0:
            raise ValueError('requests_per_second must be positive')
        self._interval = 1.0 / requests_per_second
        self._clock = clock
        self._sleep = sleep
        self._lock = asyncio.Lock()
        self._next = 0.0

    async def acquire(self) -> None:
        async with self._lock:
            now = self._clock()
            wait = max(0.0, self._next - now)
            if wait:
                await self._sleep(wait)
                now = self._clock()
            self._next = max(self._next, now) + self._interval
