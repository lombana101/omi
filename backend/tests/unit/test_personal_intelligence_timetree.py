from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

import httpx
import pytest

from personal_intelligence.models import CalendarEventDraft
from personal_intelligence.rate_limit import AsyncRateLimiter
from personal_intelligence.security import redact_for_log
from personal_intelligence.timetree import (
    TimeTreeAuthenticationError,
    TimeTreeClient,
    TimeTreeNotFoundError,
    TimeTreeUnavailableError,
    UncertainWriteOutcome,
    validate_identifier,
)


class _NoopLimiter:
    async def acquire(self) -> None:
        return None


def _event_payload(
    *,
    uuid: str = 'event_1',
    calendar_id: str = 'calendar_1',
    title: str = 'Private title',
    deactivated_at: int | None = None,
    recurrences: list[str] | None = None,
) -> dict[str, Any]:
    start = datetime(2026, 11, 2, 9, 30, tzinfo=ZoneInfo('America/Toronto'))
    end = datetime(2026, 11, 2, 10, 30, tzinfo=ZoneInfo('America/Toronto'))
    return {
        'id': uuid,
        'uuid': uuid,
        'calendar_id': calendar_id,
        'title': title,
        'all_day': False,
        'start_at': int(start.timestamp() * 1000),
        'start_timezone': 'America/Toronto',
        'end_at': int(end.timestamp() * 1000),
        'end_timezone': 'America/Toronto',
        'recurrences': recurrences or [],
        'author_id': 17,
        'location': 'Private location',
        'note': 'Private note',
        'deactivated_at': deactivated_at,
    }


def _draft(*, title: str = 'Prepare presentation') -> CalendarEventDraft:
    zone = ZoneInfo('America/Toronto')
    return CalendarEventDraft(
        title=title,
        all_day=False,
        start_at=datetime(2026, 11, 2, 9, 30, tzinfo=zone),
        end_at=datetime(2026, 11, 2, 10, 30, tzinfo=zone),
        start_timezone='America/Toronto',
        end_timezone='America/Toronto',
        note='Bring the private deck',
        location='Private room',
        recurrences=['RRULE:FREQ=WEEKLY;COUNT=3'],
    )


def _client(http_client: httpx.AsyncClient, **kwargs: Any) -> TimeTreeClient:
    return TimeTreeClient(
        email='owner@example.test',
        password='time-tree-secret',
        client=http_client,
        limiter=_NoopLimiter(),  # type: ignore[arg-type]
        **kwargs,
    )


def _login_response(session: str = 'session-secret') -> httpx.Response:
    return httpx.Response(200, headers={'set-cookie': f'_session_id={session}; Path=/; Secure; HttpOnly'})


def _csrf_response(token: str = 'csrf-secret') -> httpx.Response:
    return httpx.Response(200, text=f'<html><meta content="{token}" name="csrf-token"></html>')


@pytest.mark.asyncio
async def test_authentication_keeps_cookie_extracts_csrf_and_lists_only_active_calendars() -> None:
    requests: list[httpx.Request] = []

    async def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        if request.url.path == '/api/v1/auth/email/signin':
            body = json.loads(request.content)
            assert body['uid'] == 'owner@example.test'
            assert body['password'] == 'time-tree-secret'
            assert len(body['uuid']) == 32
            assert '-' not in body['uuid']
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        assert request.url.path == '/api/v1/calendars'
        assert dict(request.url.params) == {'since': '0'}
        assert request.headers['cookie'] == '_session_id=session-secret'
        assert request.headers['x-timetreea'] == 'web/2.1.0/en'
        return httpx.Response(
            200,
            json={
                'calendars': [
                    {'id': 12, 'name': 'Active', 'deactivated_at': None},
                    {'id': 13, 'name': 'Archived', 'deactivated_at': 123},
                ]
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        calendars = await _client(http_client).list_calendars()

    assert [calendar.model_dump() for calendar in calendars] == [{'id': '12', 'name': 'Active'}]
    assert [request.method for request in requests] == ['PUT', 'GET', 'GET']


@pytest.mark.asyncio
async def test_authentication_fails_closed_when_csrf_token_is_missing() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        return httpx.Response(200, text='<html></html>')

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(TimeTreeAuthenticationError, match='CSRF token'):
            await _client(http_client).list_calendars()


@pytest.mark.asyncio
async def test_event_pagination_preserves_timezone_all_day_and_recurrence_semantics() -> None:
    cursors: list[str] = []
    first = _event_payload(uuid='series_1', recurrences=['RRULE:FREQ=WEEKLY;COUNT=3'])
    first['all_day'] = True
    second = _event_payload(uuid='deleted_1', deactivated_at=123)

    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        cursors.append(request.url.params['since'])
        if request.url.params['since'] == '0':
            return httpx.Response(200, json={'events': [first], 'chunk': True, 'since': 7})
        return httpx.Response(200, json={'events': [second], 'chunk': False, 'since': 9})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        events = await _client(http_client).list_events('calendar_1')

    assert cursors == ['0', '7']
    assert len(events) == 1
    assert events[0].uuid == 'series_1'
    assert events[0].all_day is True
    assert events[0].start_timezone == 'America/Toronto'
    assert events[0].end_timezone == 'America/Toronto'
    assert events[0].recurrences == ['RRULE:FREQ=WEEKLY;COUNT=3']
    assert events[0].is_recurring is True


@pytest.mark.asyncio
async def test_pagination_stops_on_a_stuck_cursor_and_rejects_page_limit_exhaustion() -> None:
    event = _event_payload()
    page_calls = 0

    async def stuck_handler(request: httpx.Request) -> httpx.Response:
        nonlocal page_calls
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        page_calls += 1
        return httpx.Response(200, json={'events': [event], 'chunk': True, 'since': 0})

    async with httpx.AsyncClient(transport=httpx.MockTransport(stuck_handler)) as http_client:
        events = await _client(http_client).list_events('calendar_1')
    assert [item.uuid for item in events] == ['event_1']
    assert page_calls == 1

    async def endless_handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        cursor = int(request.url.params['since'])
        return httpx.Response(200, json={'events': [], 'chunk': True, 'since': cursor + 1})

    async with httpx.AsyncClient(transport=httpx.MockTransport(endless_handler)) as http_client:
        with pytest.raises(TimeTreeUnavailableError, match='pagination limit'):
            await _client(http_client, max_pages=2).list_events('calendar_1')


@pytest.mark.asyncio
async def test_create_update_and_delete_send_exact_csrf_protected_requests() -> None:
    writes: list[httpx.Request] = []
    event_payload = _event_payload()

    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        if request.method == 'GET':
            return httpx.Response(200, json={'event': event_payload})
        writes.append(request)
        assert request.headers['x-csrf-token'] == 'csrf-secret'
        if request.method == 'DELETE':
            assert request.content in {b'', b'null'}
            return httpx.Response(204)
        return httpx.Response(200, json={'event': event_payload})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        client = _client(http_client)
        created = await client.create_event('calendar_1', _draft())
        updated = await client.update_event(
            'calendar_1',
            'event_1',
            {'title': 'Updated title', 'start_timezone': 'America/Toronto'},
        )
        await client.delete_event('calendar_1', 'event_1')

    assert created.uuid == 'event_1'
    assert updated.uuid == 'event_1'
    assert [request.method for request in writes] == ['POST', 'PUT', 'DELETE']
    create_body = json.loads(writes[0].content)
    assert create_body['start_timezone'] == 'America/Toronto'
    assert create_body['end_timezone'] == 'America/Toronto'
    assert create_body['recurrences'] == ['RRULE:FREQ=WEEKLY;COUNT=3']
    assert create_body['start_at'] == int(_draft().start_at.timestamp() * 1000)
    assert json.loads(writes[1].content) == {
        'title': 'Updated title',
        'start_timezone': 'America/Toronto',
    }


@pytest.mark.parametrize('status_code', [400, 405, 415])
@pytest.mark.asyncio
async def test_delete_retries_only_an_explicit_request_shape_rejection_with_full_event(status_code: int) -> None:
    deletes: list[httpx.Request] = []
    event_payload = _event_payload()

    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        if request.method == 'GET':
            return httpx.Response(200, json={'event': event_payload})
        deletes.append(request)
        if len(deletes) == 1:
            return httpx.Response(status_code, json={'error': {'message': 'body required'}})
        return httpx.Response(204)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        await _client(http_client).delete_event('calendar_1', 'event_1')

    assert len(deletes) == 2
    assert deletes[0].content in {b'', b'null'}
    assert json.loads(deletes[1].content)['uuid'] == 'event_1'


@pytest.mark.asyncio
async def test_csrf_rejection_reauthenticates_and_retries_a_write_once() -> None:
    login_count = 0
    write_count = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal login_count, write_count
        if request.url.path == '/api/v1/auth/email/signin':
            login_count += 1
            return _login_response(f'session-{login_count}')
        if request.url.path == '/':
            return _csrf_response(f'csrf-{login_count}')
        write_count += 1
        if write_count == 1:
            return httpx.Response(403, json={'error': {'code': -1}})
        return httpx.Response(200, json={'event': _event_payload()})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        created = await _client(http_client).create_event('calendar_1', _draft())

    assert created.uuid == 'event_1'
    assert login_count == 2
    assert write_count == 2


@pytest.mark.asyncio
async def test_bare_http_403_is_treated_as_a_refreshable_csrf_rejection() -> None:
    login_count = 0
    write_count = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal login_count, write_count
        if request.url.path == '/api/v1/auth/email/signin':
            login_count += 1
            return _login_response(f'session-{login_count}')
        if request.url.path == '/':
            return _csrf_response(f'csrf-{login_count}')
        write_count += 1
        if write_count == 1:
            return httpx.Response(403)
        return httpx.Response(200, json={'event': _event_payload()})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        created = await _client(http_client).create_event('calendar_1', _draft())

    assert created.uuid == 'event_1'
    assert login_count == 2
    assert write_count == 2


@pytest.mark.asyncio
async def test_plain_http_404_is_reported_as_not_found() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        return httpx.Response(404)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(TimeTreeNotFoundError, match='not found'):
            await _client(http_client).get_event('calendar_1', 'event_1')


@pytest.mark.asyncio
async def test_session_rejection_reauthenticates_once_and_shares_concurrent_login() -> None:
    login_count = 0
    calendar_count = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal login_count, calendar_count
        if request.url.path == '/api/v1/auth/email/signin':
            login_count += 1
            await asyncio.sleep(0)
            return _login_response(f'session-{login_count}')
        if request.url.path == '/':
            return _csrf_response(f'csrf-{login_count}')
        calendar_count += 1
        if calendar_count == 1:
            return httpx.Response(400, json={'error': {'code': -493}})
        return httpx.Response(200, json={'calendars': [{'id': 1, 'name': 'Owner'}]})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        client = _client(http_client)
        calendars = await client.list_calendars()
        assert calendars[0].id == '1'
        await asyncio.gather(client.list_calendars(), client.list_calendars())

    assert login_count == 2
    assert calendar_count == 4


@pytest.mark.asyncio
async def test_persistent_session_rejection_stops_after_one_reauthentication() -> None:
    login_count = 0
    calendar_count = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal login_count, calendar_count
        if request.url.path == '/api/v1/auth/email/signin':
            login_count += 1
            return _login_response(f'session-{login_count}')
        if request.url.path == '/':
            return _csrf_response(f'csrf-{login_count}')
        calendar_count += 1
        return httpx.Response(400, json={'error': {'code': -493}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(TimeTreeAuthenticationError, match='after one refresh'):
            await _client(http_client).list_calendars()

    assert login_count == 2
    assert calendar_count == 2


@pytest.mark.asyncio
async def test_concurrent_cold_calls_share_one_login() -> None:
    login_count = 0
    calendar_count = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal login_count, calendar_count
        if request.url.path == '/api/v1/auth/email/signin':
            login_count += 1
            await asyncio.sleep(0.01)
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        calendar_count += 1
        return httpx.Response(200, json={'calendars': []})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        client = _client(http_client)
        await asyncio.gather(client.list_calendars(), client.list_calendars(), client.list_calendars())

    assert login_count == 1
    assert calendar_count == 3


@pytest.mark.asyncio
async def test_rate_limiter_spaces_requests_without_an_initial_burst() -> None:
    current = 0.0
    waits: list[float] = []

    def clock() -> float:
        return current

    async def sleep(seconds: float) -> None:
        nonlocal current
        waits.append(seconds)
        current += seconds

    limiter = AsyncRateLimiter(10, clock=clock, sleep=sleep)
    await limiter.acquire()
    await limiter.acquire()
    await limiter.acquire()

    assert waits == pytest.approx([0.1, 0.1])


@pytest.mark.parametrize('value', ['../calendar', 'calendar/event', '', 'space value', 'café'])
def test_identifier_validation_rejects_unsafe_path_segments(value: str) -> None:
    with pytest.raises(ValueError, match='invalid characters'):
        validate_identifier(value, 'calendar_id')


@pytest.mark.asyncio
async def test_invalid_identifier_is_rejected_before_any_network_io() -> None:
    calls = 0

    async def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(500)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(ValueError, match='invalid characters'):
            await _client(http_client).get_event('../calendar', 'event_1')
    assert calls == 0


@pytest.mark.parametrize('failure', ['timeout', 'server'])
@pytest.mark.asyncio
async def test_write_timeout_or_server_failure_is_uncertain_and_never_retried(failure: str) -> None:
    writes = 0

    async def handler(request: httpx.Request) -> httpx.Response:
        nonlocal writes
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        writes += 1
        if failure == 'timeout':
            raise httpx.ReadTimeout('late response', request=request)
        return httpx.Response(503, json={'error': {'code': -493}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(UncertainWriteOutcome, match='inspect TimeTree') as raised:
            await _client(http_client).create_event('calendar_1', _draft())

    assert writes == 1
    assert raised.value.operation == 'create'
    assert raised.value.safe_target == 'calendar_1'


@pytest.mark.asyncio
async def test_read_timeout_is_unavailable_not_an_uncertain_write() -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        raise httpx.ReadTimeout('read timed out', request=request)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(TimeTreeUnavailableError, match='request failed'):
            await _client(http_client).list_calendars()


@pytest.mark.asyncio
async def test_logs_and_errors_do_not_expose_timetree_secrets_or_event_content(
    caplog: pytest.LogCaptureFixture,
) -> None:
    private_values = {
        'owner@example.test',
        'time-tree-secret',
        'session-secret',
        'csrf-secret',
        'Private title',
        'Private note',
        'Private location',
    }

    async def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == '/api/v1/auth/email/signin':
            return _login_response()
        if request.url.path == '/':
            return _csrf_response()
        return httpx.Response(
            400,
            json={
                'error': {'code': 999},
                'title': 'Private title',
                'note': 'Private note',
                'location': 'Private location',
            },
        )

    caplog.set_level(logging.DEBUG)
    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        with pytest.raises(Exception) as raised:
            await _client(http_client).list_calendars()

    combined = caplog.text + str(raised.value)
    assert all(value not in combined for value in private_values)

    redacted = redact_for_log(
        {
            'authorization': 'Bearer api-secret',
            'cookie': 'session-secret',
            'nested': [{'csrf_token': 'csrf-secret', 'title': 'Private title', 'count': 2}],
        }
    )
    rendered = repr(redacted)
    assert 'api-secret' not in rendered
    assert 'session-secret' not in rendered
    assert 'csrf-secret' not in rendered
    assert 'Private title' not in rendered
    assert redacted['nested'][0]['count'] == 2
