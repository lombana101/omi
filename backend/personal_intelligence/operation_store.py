from __future__ import annotations

import asyncio
import hashlib
import os
import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path

from personal_intelligence.models import (
    CalendarOperationOutcome,
    CalendarOperationPreview,
    CalendarOperationRequest,
)


class OperationConflictError(RuntimeError):
    pass


class OperationNotFoundError(RuntimeError):
    pass


@dataclass(frozen=True)
class StoredOperation:
    operation_id: str
    owner_uid: str
    idempotency_key: str
    request_fingerprint: str
    status: str
    request: CalendarOperationRequest
    preview: CalendarOperationPreview
    outcome: CalendarOperationOutcome | None
    expires_at: datetime


class OperationStore:
    """Small durable confirmation/idempotency journal for calendar writes."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._lock = asyncio.Lock()

    async def initialize(self) -> None:
        await asyncio.to_thread(self._initialize_sync)

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self._path, timeout=10)
        connection.row_factory = sqlite3.Row
        return connection

    def _initialize_sync(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self._path.parent, 0o700)
        with self._connect() as connection:
            connection.execute("""
                CREATE TABLE IF NOT EXISTS calendar_operations (
                    operation_id TEXT PRIMARY KEY,
                    owner_uid TEXT NOT NULL,
                    idempotency_key TEXT NOT NULL,
                    request_fingerprint TEXT NOT NULL,
                    status TEXT NOT NULL,
                    request_json TEXT NOT NULL,
                    preview_json TEXT NOT NULL,
                    outcome_json TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    UNIQUE(owner_uid, idempotency_key)
                )
                """)
        os.chmod(self._path, 0o600)

    @staticmethod
    def fingerprint(request: CalendarOperationRequest) -> str:
        canonical = request.model_dump_json(exclude={'idempotency_key'}, exclude_unset=True)
        return hashlib.sha256(canonical.encode()).hexdigest()

    async def prepare(
        self,
        *,
        owner_uid: str,
        operation_id: str,
        request: CalendarOperationRequest,
        preview: CalendarOperationPreview,
        now: datetime,
    ) -> StoredOperation:
        async with self._lock:
            return await asyncio.to_thread(
                self._prepare_sync,
                owner_uid,
                operation_id,
                request,
                preview,
                now.astimezone(UTC),
            )

    def _prepare_sync(
        self,
        owner_uid: str,
        operation_id: str,
        request: CalendarOperationRequest,
        preview: CalendarOperationPreview,
        now: datetime,
    ) -> StoredOperation:
        fingerprint = self.fingerprint(request)
        cutoff = now - timedelta(days=7)
        with self._connect() as connection:
            connection.execute('DELETE FROM calendar_operations WHERE updated_at < ?', (cutoff.isoformat(),))
            existing = connection.execute(
                'SELECT * FROM calendar_operations WHERE owner_uid = ? AND idempotency_key = ?',
                (owner_uid, request.idempotency_key),
            ).fetchone()
            if existing is not None:
                operation = self._decode(existing)
                if operation.request_fingerprint != fingerprint:
                    raise OperationConflictError('Idempotency key was already used for a different operation')
                return operation
            timestamp = now.isoformat()
            connection.execute(
                """
                INSERT INTO calendar_operations (
                    operation_id, owner_uid, idempotency_key, request_fingerprint, status,
                    request_json, preview_json, created_at, updated_at, expires_at
                ) VALUES (?, ?, ?, ?, 'pending', ?, ?, ?, ?, ?)
                """,
                (
                    operation_id,
                    owner_uid,
                    request.idempotency_key,
                    fingerprint,
                    request.model_dump_json(exclude_unset=True),
                    preview.model_dump_json(),
                    timestamp,
                    timestamp,
                    preview.expires_at.astimezone(UTC).isoformat(),
                ),
            )
            row = connection.execute(
                'SELECT * FROM calendar_operations WHERE operation_id = ?', (operation_id,)
            ).fetchone()
        if row is None:
            raise OperationNotFoundError('Prepared operation was not persisted')
        return self._decode(row)

    async def get(self, owner_uid: str, operation_id: str) -> StoredOperation:
        async with self._lock:
            row = await asyncio.to_thread(self._get_sync, owner_uid, operation_id)
        if row is None:
            raise OperationNotFoundError('Calendar operation was not found')
        return self._decode(row)

    def _get_sync(self, owner_uid: str, operation_id: str) -> sqlite3.Row | None:
        with self._connect() as connection:
            return connection.execute(
                'SELECT * FROM calendar_operations WHERE owner_uid = ? AND operation_id = ?',
                (owner_uid, operation_id),
            ).fetchone()

    async def claim(self, owner_uid: str, operation_id: str, now: datetime) -> StoredOperation:
        async with self._lock:
            return await asyncio.to_thread(self._claim_sync, owner_uid, operation_id, now.astimezone(UTC))

    def _claim_sync(self, owner_uid: str, operation_id: str, now: datetime) -> StoredOperation:
        with self._connect() as connection:
            connection.execute('BEGIN IMMEDIATE')
            row = connection.execute(
                'SELECT * FROM calendar_operations WHERE owner_uid = ? AND operation_id = ?',
                (owner_uid, operation_id),
            ).fetchone()
            if row is None:
                raise OperationNotFoundError('Calendar operation was not found')
            operation = self._decode(row)
            if operation.status != 'pending':
                return operation
            if operation.expires_at <= now:
                outcome = CalendarOperationOutcome(
                    operation_id=operation_id,
                    status='failed',
                    message='Confirmation expired; prepare the operation again',
                )
                connection.execute(
                    "UPDATE calendar_operations SET status = 'failed', outcome_json = ?, updated_at = ? "
                    'WHERE operation_id = ?',
                    (outcome.model_dump_json(), now.isoformat(), operation_id),
                )
            else:
                connection.execute(
                    "UPDATE calendar_operations SET status = 'executing', updated_at = ? WHERE operation_id = ?",
                    (now.isoformat(), operation_id),
                )
            updated = connection.execute(
                'SELECT * FROM calendar_operations WHERE operation_id = ?', (operation_id,)
            ).fetchone()
        if updated is None:
            raise OperationNotFoundError('Calendar operation was not found')
        return self._decode(updated)

    async def finish(self, owner_uid: str, outcome: CalendarOperationOutcome, now: datetime) -> StoredOperation:
        async with self._lock:
            row = await asyncio.to_thread(self._finish_sync, owner_uid, outcome, now.astimezone(UTC))
        if row is None:
            raise OperationNotFoundError('Calendar operation was not found')
        return self._decode(row)

    def _finish_sync(self, owner_uid: str, outcome: CalendarOperationOutcome, now: datetime) -> sqlite3.Row | None:
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE calendar_operations
                SET status = ?, outcome_json = ?, updated_at = ?
                WHERE owner_uid = ? AND operation_id = ?
                """,
                (outcome.status, outcome.model_dump_json(), now.isoformat(), owner_uid, outcome.operation_id),
            )
            return connection.execute(
                'SELECT * FROM calendar_operations WHERE owner_uid = ? AND operation_id = ?',
                (owner_uid, outcome.operation_id),
            ).fetchone()

    async def clear(self, owner_uid: str) -> int:
        async with self._lock:
            return await asyncio.to_thread(self._clear_sync, owner_uid)

    def _clear_sync(self, owner_uid: str) -> int:
        with self._connect() as connection:
            cursor = connection.execute(
                "DELETE FROM calendar_operations WHERE owner_uid = ? AND status != 'executing'", (owner_uid,)
            )
            return cursor.rowcount

    @staticmethod
    def _decode(row: sqlite3.Row) -> StoredOperation:
        outcome_raw = row['outcome_json']
        return StoredOperation(
            operation_id=row['operation_id'],
            owner_uid=row['owner_uid'],
            idempotency_key=row['idempotency_key'],
            request_fingerprint=row['request_fingerprint'],
            status=row['status'],
            request=CalendarOperationRequest.model_validate_json(row['request_json']),
            preview=CalendarOperationPreview.model_validate_json(row['preview_json']),
            outcome=CalendarOperationOutcome.model_validate_json(outcome_raw) if outcome_raw else None,
            expires_at=datetime.fromisoformat(row['expires_at']),
        )
