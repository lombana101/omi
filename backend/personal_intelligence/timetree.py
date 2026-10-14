from __future__ import annotations

import asyncio
import logging
import re
from html.parser import HTMLParser
from typing import Any
from uuid import uuid4

import httpx
from pydantic import ValidationError

from personal_intelligence.models import CalendarEventDraft, TimeTreeCalendar, TimeTreeEvent
from personal_intelligence.rate_limit import AsyncRateLimiter

logger = logging.getLogger(__name__)

V1_BASE_URL = 'https://timetreeapp.com/api/v1'
WEB_BASE_URL = 'https://timetreeapp.com/'
DEFAULT_HEADERS = {'Content-Type': 'application/json', 'X-Timetreea': 'web/2.1.0/en'}
IDENTIFIER = re.compile(r'^[A-Za-z0-9_-]+$')
SESSION_COOKIE = '_session_id'
REFRESHABLE_CODES = {-1, -493}
RECORD_NOT_FOUND = -403
CALENDAR_INACCESSIBLE = -425


class TimeTreeError(RuntimeError):
    def __init__(self, message: str, *, status_code: int | None = None, provider_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code
        self.provider_code = provider_code


class TimeTreeAuthenticationError(TimeTreeError):
    pass


class TimeTreeUnavailableError(TimeTreeError):
    pass


class TimeTreeNotFoundError(TimeTreeError):
    pass


class UncertainWriteOutcome(TimeTreeError):
    """The provider may have applied a write; callers must reconcile before retrying."""

    def __init__(self, operation: str, safe_target: str) -> None:
        super().__init__(f'{operation} outcome is uncertain; inspect TimeTree before retrying')
        self.operation = operation
        self.safe_target = safe_target


class _ProviderResponseError(TimeTreeError):
    @property
    def refreshable(self) -> bool:
        return self.status_code in {401, 403} or self.provider_code in REFRESHABLE_CODES


class _CsrfParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.token: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != 'meta':
            return
        values = {key.lower(): value for key, value in attrs}
        if (values.get('name') or '').lower() == 'csrf-token' and values.get('content'):
            self.token = values['content']


def validate_identifier(value: str, field: str) -> str:
    if not IDENTIFIER.fullmatch(value):
        raise ValueError(f'{field} contains invalid characters')
    return value


def _provider_code(response: httpx.Response) -> int | None:
    try:
        payload = response.json()
    except (ValueError, TypeError):
        return None
    if not isinstance(payload, dict) or not isinstance(payload.get('error'), dict):
        return None
    code = payload['error'].get('code')
    return code if isinstance(code, int) else None


class TimeTreeClient:
    def __init__(
        self,
        *,
        email: str,
        password: str,
        timeout_seconds: float = 20.0,
        requests_per_second: float = 10.0,
        client: httpx.AsyncClient | None = None,
        limiter: AsyncRateLimiter | None = None,
        max_pages: int = 200,
        max_events: int = 20000,
    ) -> None:
        self._email = email
        self._password = password
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient(
            headers=DEFAULT_HEADERS,
            follow_redirects=True,
            timeout=httpx.Timeout(timeout_seconds, connect=min(timeout_seconds, 5.0)),
        )
        self._limiter = limiter or AsyncRateLimiter(requests_per_second)
        self._auth_lock = asyncio.Lock()
        self._authenticated = False
        self._auth_generation = 0
        self._csrf_token: str | None = None
        self._max_pages = max_pages
        self._max_events = max_events

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def __aenter__(self) -> 'TimeTreeClient':
        return self

    async def __aexit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        await self.close()

    def _has_session_cookie(self) -> bool:
        return any(cookie.name == SESSION_COOKIE and bool(cookie.value) for cookie in self._client.cookies.jar)

    async def _ensure_authenticated(self) -> None:
        if self._authenticated and self._has_session_cookie():
            return
        async with self._auth_lock:
            if self._authenticated and self._has_session_cookie():
                return
            await self._login_locked()

    async def _reauthenticate_if_stale(self, observed_generation: int) -> None:
        async with self._auth_lock:
            if self._auth_generation != observed_generation and self._authenticated:
                return
            await self._login_locked()

    async def _login_locked(self) -> None:
        self._authenticated = False
        self._csrf_token = None
        self._client.cookies.clear()
        body = {'uid': self._email, 'password': self._password, 'uuid': uuid4().hex}
        try:
            response = await self._send_transport(
                'PUT', f'{V1_BASE_URL}/auth/email/signin', json=body, is_write=False, operation='authenticate'
            )
            self._raise_for_status(response)
            if not self._has_session_cookie():
                raise TimeTreeAuthenticationError('TimeTree did not issue a session cookie')
            page = await self._send_transport('GET', WEB_BASE_URL, is_write=False, operation='csrf')
            self._raise_for_status(page)
            parser = _CsrfParser()
            parser.feed(page.text)
            self._csrf_token = parser.token or page.headers.get('x-csrf-token')
            if not self._csrf_token:
                raise TimeTreeAuthenticationError('TimeTree did not issue a CSRF token')
        except TimeTreeAuthenticationError:
            raise
        except _ProviderResponseError as exc:
            raise TimeTreeAuthenticationError(
                'TimeTree authentication was rejected', status_code=exc.status_code, provider_code=exc.provider_code
            ) from exc
        except TimeTreeError as exc:
            raise TimeTreeAuthenticationError('TimeTree authentication is unavailable') from exc
        self._authenticated = True
        self._auth_generation += 1
        logger.info('TimeTree authentication refreshed')

    async def _send_transport(
        self,
        method: str,
        url: str,
        *,
        json: Any = None,
        is_write: bool,
        operation: str,
        safe_target: str = 'provider',
        requires_csrf: bool = False,
    ) -> httpx.Response:
        await self._limiter.acquire()
        headers: dict[str, str] = dict(DEFAULT_HEADERS)
        if requires_csrf:
            if not self._csrf_token:
                raise TimeTreeAuthenticationError('TimeTree CSRF token is unavailable')
            headers['x-csrf-token'] = self._csrf_token
        try:
            response = await self._client.request(method, url, json=json, headers=headers)
        except (httpx.TimeoutException, httpx.TransportError) as exc:
            if is_write:
                raise UncertainWriteOutcome(operation, safe_target) from exc
            raise TimeTreeUnavailableError('TimeTree request failed') from exc
        rotated = response.headers.get('x-csrf-token')
        if rotated:
            self._csrf_token = rotated
        if is_write and response.status_code >= 500:
            raise UncertainWriteOutcome(operation, safe_target)
        return response

    @staticmethod
    def _raise_for_status(response: httpx.Response) -> None:
        if 200 <= response.status_code < 300:
            return
        raise _ProviderResponseError(
            'TimeTree rejected the request',
            status_code=response.status_code,
            provider_code=_provider_code(response),
        )

    async def _request(
        self,
        method: str,
        path: str,
        *,
        json: Any = None,
        is_write: bool = False,
        operation: str = 'read',
        safe_target: str = 'provider',
        requires_csrf: bool = False,
        expect_json: bool = True,
    ) -> Any:
        await self._ensure_authenticated()
        observed_generation = self._auth_generation
        for attempt in range(2):
            try:
                response = await self._send_transport(
                    method,
                    f'{V1_BASE_URL}{path}',
                    json=json,
                    is_write=is_write,
                    operation=operation,
                    safe_target=safe_target,
                    requires_csrf=requires_csrf,
                )
                self._raise_for_status(response)
                if not expect_json:
                    return None
                try:
                    return response.json()
                except (ValueError, TypeError) as exc:
                    if is_write:
                        raise UncertainWriteOutcome(operation, safe_target) from exc
                    raise TimeTreeUnavailableError('TimeTree returned an invalid response') from exc
            except _ProviderResponseError as exc:
                if attempt == 0 and exc.refreshable and (exc.status_code or 0) < 500:
                    await self._reauthenticate_if_stale(observed_generation)
                    observed_generation = self._auth_generation
                    continue
                if exc.provider_code == RECORD_NOT_FOUND or exc.status_code == 404:
                    raise TimeTreeNotFoundError('TimeTree resource was not found', status_code=404) from exc
                if exc.provider_code == CALENDAR_INACCESSIBLE:
                    raise TimeTreeNotFoundError('TimeTree calendar is inaccessible', status_code=404) from exc
                if exc.refreshable:
                    raise TimeTreeAuthenticationError('TimeTree session was rejected after one refresh') from exc
                raise TimeTreeError(
                    'TimeTree rejected the request', status_code=exc.status_code, provider_code=exc.provider_code
                ) from exc
        raise AssertionError('unreachable')

    async def list_calendars(self) -> list[TimeTreeCalendar]:
        payload = await self._request('GET', '/calendars?since=0')
        calendars = payload.get('calendars') if isinstance(payload, dict) else None
        if not isinstance(calendars, list):
            raise TimeTreeUnavailableError('TimeTree returned an invalid calendar list')
        result: list[TimeTreeCalendar] = []
        try:
            for item in calendars:
                if isinstance(item, dict) and item.get('deactivated_at') is None:
                    result.append(TimeTreeCalendar(id=str(item['id']), name=str(item['name'])))
        except (KeyError, TypeError, ValidationError) as exc:
            raise TimeTreeUnavailableError('TimeTree returned an invalid calendar list') from exc
        return result

    async def _event_pages(self, calendar_id: str, *, include_deleted: bool = False) -> list[TimeTreeEvent]:
        calendar_id = validate_identifier(calendar_id, 'calendar_id')
        endpoint = 'events' if include_deleted else 'events/sync'
        cursor = 0
        events: list[TimeTreeEvent] = []
        for _ in range(self._max_pages):
            payload = await self._request(
                'GET', f'/calendar/{calendar_id}/{endpoint}?since={cursor}', safe_target=calendar_id
            )
            if not isinstance(payload, dict) or not isinstance(payload.get('events'), list):
                raise TimeTreeUnavailableError('TimeTree returned an invalid event page')
            try:
                events.extend(TimeTreeEvent.from_provider(item) for item in payload['events'] if isinstance(item, dict))
            except (KeyError, TypeError, ValueError, ValidationError) as exc:
                raise TimeTreeUnavailableError('TimeTree returned an invalid event') from exc
            if len(events) > self._max_events:
                raise TimeTreeUnavailableError('TimeTree event page limit exceeded')
            chunk = bool(payload.get('chunk'))
            next_cursor = payload.get('since')
            if not chunk:
                return events
            if not isinstance(next_cursor, int) or next_cursor <= cursor:
                return events
            cursor = next_cursor
        raise TimeTreeUnavailableError('TimeTree pagination limit exceeded')

    async def list_events(self, calendar_id: str) -> list[TimeTreeEvent]:
        events = await self._event_pages(calendar_id)
        return [event for event in events if event.deactivated_at is None]

    async def list_event_changes(self, calendar_id: str) -> list[TimeTreeEvent]:
        return await self._event_pages(calendar_id, include_deleted=True)

    async def get_event(self, calendar_id: str, event_uuid: str) -> TimeTreeEvent:
        calendar_id = validate_identifier(calendar_id, 'calendar_id')
        event_uuid = validate_identifier(event_uuid, 'event_uuid')
        payload = await self._request('GET', f'/calendar/{calendar_id}/event/{event_uuid}', safe_target=event_uuid)
        event = payload.get('event') if isinstance(payload, dict) else None
        if not isinstance(event, dict):
            raise TimeTreeUnavailableError('TimeTree returned an invalid event')
        try:
            return TimeTreeEvent.from_provider(event)
        except (KeyError, TypeError, ValueError, ValidationError) as exc:
            raise TimeTreeUnavailableError('TimeTree returned an invalid event') from exc

    async def create_event(self, calendar_id: str, event: CalendarEventDraft) -> TimeTreeEvent:
        calendar_id = validate_identifier(calendar_id, 'calendar_id')
        payload = await self._request(
            'POST',
            f'/calendar/{calendar_id}/event',
            json=event.provider_payload(),
            is_write=True,
            operation='create',
            safe_target=calendar_id,
            requires_csrf=True,
        )
        created = payload.get('event') if isinstance(payload, dict) else None
        if not isinstance(created, dict):
            raise UncertainWriteOutcome('create', calendar_id)
        try:
            return TimeTreeEvent.from_provider(created)
        except (KeyError, TypeError, ValueError, ValidationError) as exc:
            raise UncertainWriteOutcome('create', calendar_id) from exc

    async def update_event(self, calendar_id: str, event_uuid: str, changes: dict[str, Any]) -> TimeTreeEvent:
        calendar_id = validate_identifier(calendar_id, 'calendar_id')
        event_uuid = validate_identifier(event_uuid, 'event_uuid')
        if not changes:
            raise ValueError('changes must not be empty')
        payload = await self._request(
            'PUT',
            f'/calendar/{calendar_id}/event/{event_uuid}',
            json=changes,
            is_write=True,
            operation='update',
            safe_target=event_uuid,
            requires_csrf=True,
        )
        updated = payload.get('event') if isinstance(payload, dict) else None
        if not isinstance(updated, dict):
            raise UncertainWriteOutcome('update', event_uuid)
        try:
            return TimeTreeEvent.from_provider(updated)
        except (KeyError, TypeError, ValueError, ValidationError) as exc:
            raise UncertainWriteOutcome('update', event_uuid) from exc

    async def delete_event(self, calendar_id: str, event_uuid: str) -> None:
        calendar_id = validate_identifier(calendar_id, 'calendar_id')
        event_uuid = validate_identifier(event_uuid, 'event_uuid')
        target = await self.get_event(calendar_id, event_uuid)
        path = f'/calendar/{calendar_id}/event/{event_uuid}'
        try:
            await self._request(
                'DELETE',
                path,
                is_write=True,
                operation='delete',
                safe_target=event_uuid,
                requires_csrf=True,
                expect_json=False,
            )
        except TimeTreeError as exc:
            # The private API has accepted two DELETE shapes across web client
            # revisions. An explicit body-shape rejection proves the first
            # request was not applied, so one full-event fallback is safe.
            # Timeouts, transport loss, 5xx and auth/CSRF failures never enter
            # this branch and are therefore never retried as writes.
            if exc.status_code not in {400, 405, 415} or exc.provider_code is not None:
                raise
            await self._request(
                'DELETE',
                path,
                json=target.provider_payload,
                is_write=True,
                operation='delete',
                safe_target=event_uuid,
                requires_csrf=True,
                expect_json=False,
            )
