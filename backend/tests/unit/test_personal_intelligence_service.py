from __future__ import annotations

import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo

import pytest
from pydantic import SecretStr

from personal_intelligence.config import Settings
from personal_intelligence.llm import (
    AssistantAction,
    AssistantPlan,
    IntelligenceUnavailableError,
)
from personal_intelligence.models import (
    AssistantRequest,
    CalendarEventDraft,
    CalendarEventPatch,
    CalendarOperationKind,
    CalendarOperationRequest,
    CalendarWriteProposal,
    ExtractionRequest,
    LocalTaskContext,
    StructuredSuggestion,
    SuggestionType,
    TimeTreeCalendar,
    TimeTreeEvent,
)
from personal_intelligence.operation_store import (
    OperationConflictError,
    OperationNotFoundError,
    OperationStore,
)
from personal_intelligence.service import (
    AuthorizationBasisError,
    IntegrationDisabledError,
    PersonalIntelligenceService,
    RecurrenceScopeError,
)
from personal_intelligence.timetree import TimeTreeError, UncertainWriteOutcome

NOW = datetime(2026, 11, 2, 14, 0, tzinfo=UTC)


def _settings(path: Path, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        'owner_uid': 'owner-uid',
        'api_token': SecretStr('owner-api-token-at-least-24-characters'),
        'state_path': path,
        'timetree_enabled': True,
        'timetree_email': SecretStr('owner@example.test'),
        'timetree_password': SecretStr('private-password'),
        'llm_enabled': True,
        'llm_model': 'local-model',
    }
    values.update(overrides)
    return Settings(**values)


def _event(*, recurring: bool = False, title: str = 'Private event') -> TimeTreeEvent:
    return TimeTreeEvent(
        uuid='event_1',
        calendar_id='calendar_1',
        title=title,
        all_day=False,
        start_at=NOW + timedelta(hours=1),
        end_at=NOW + timedelta(hours=2),
        start_timezone='America/Toronto',
        end_timezone='America/Toronto',
        recurrences=['RRULE:FREQ=WEEKLY;COUNT=3'] if recurring else [],
        note='Private note',
        location='Private room',
    )


def _draft(*, title: str = 'Prepare presentation') -> CalendarEventDraft:
    zone = ZoneInfo('America/Toronto')
    return CalendarEventDraft(
        title=title,
        start_at=datetime(2026, 11, 3, 9, 0, tzinfo=zone),
        end_at=datetime(2026, 11, 3, 10, 0, tzinfo=zone),
        start_timezone='America/Toronto',
        end_timezone='America/Toronto',
        note='Bring the private deck',
    )


def _create_request(*, key: str = 'idempotency-1', title: str = 'Prepare presentation') -> CalendarOperationRequest:
    return CalendarOperationRequest(
        kind=CalendarOperationKind.CREATE,
        idempotency_key=key,
        calendar_id='calendar_1',
        event=_draft(title=title),
    )


def _extraction_request(
    *,
    source_kind: str = 'manual_text',
    authorization_basis: str = 'self_only',
) -> ExtractionRequest:
    return ExtractionRequest(
        source_ref='capture-1',
        source_kind=source_kind,
        authorization_basis=authorization_basis,
        text='I will prepare the deck tomorrow. Then I will email Sam.',
        timezone='America/Toronto',
        now=NOW,
    )


class _FakeTimeTree:
    def __init__(self, *, target: TimeTreeEvent | None = None) -> None:
        self.calendars = [TimeTreeCalendar(id='calendar_1', name='Personal')]
        self.target = target or _event()
        self.events = [self.target]
        self.create_calls: list[tuple[str, CalendarEventDraft]] = []
        self.update_calls: list[tuple[str, str, dict[str, Any]]] = []
        self.delete_calls: list[tuple[str, str]] = []
        self.write_failure: Exception | None = None

    async def close(self) -> None:
        return None

    async def list_calendars(self) -> list[TimeTreeCalendar]:
        return self.calendars

    async def list_events(self, _calendar_id: str) -> list[TimeTreeEvent]:
        return self.events

    async def get_event(self, _calendar_id: str, _event_uuid: str) -> TimeTreeEvent:
        return self.target

    async def create_event(self, calendar_id: str, event: CalendarEventDraft) -> TimeTreeEvent:
        self.create_calls.append((calendar_id, event))
        if self.write_failure is not None:
            raise self.write_failure
        return self.target.model_copy(update={'title': event.title})

    async def update_event(self, calendar_id: str, event_uuid: str, changes: dict[str, Any]) -> TimeTreeEvent:
        self.update_calls.append((calendar_id, event_uuid, changes))
        if self.write_failure is not None:
            raise self.write_failure
        return self.target.model_copy(update=changes)

    async def delete_event(self, calendar_id: str, event_uuid: str) -> None:
        self.delete_calls.append((calendar_id, event_uuid))
        if self.write_failure is not None:
            raise self.write_failure


class _FakeIntelligence:
    def __init__(
        self,
        *,
        suggestions: list[StructuredSuggestion] | None = None,
        plan: AssistantPlan | None = None,
        failure: Exception | None = None,
    ) -> None:
        self.suggestions = suggestions or []
        self.plan = plan or AssistantPlan(action=AssistantAction.ANSWER, response='No action')
        self.failure = failure
        self.extract_calls = 0
        self.plan_calls = 0

    async def close(self) -> None:
        return None

    async def extract(self, _request: ExtractionRequest) -> list[StructuredSuggestion]:
        self.extract_calls += 1
        if self.failure is not None:
            raise self.failure
        return self.suggestions

    async def plan_assistant(self, **_kwargs: Any) -> AssistantPlan:
        self.plan_calls += 1
        if self.failure is not None:
            raise self.failure
        return self.plan


async def _service(
    tmp_path: Path,
    *,
    timetree: _FakeTimeTree | None = None,
    intelligence: _FakeIntelligence | None = None,
    settings: Settings | None = None,
) -> tuple[PersonalIntelligenceService, OperationStore]:
    configured = settings or _settings(tmp_path / 'state' / 'operations.sqlite3')
    store = OperationStore(configured.state_path)
    await store.initialize()
    return (
        PersonalIntelligenceService(
            settings=configured,
            operations=store,
            timetree=timetree,  # type: ignore[arg-type]
            intelligence=intelligence,  # type: ignore[arg-type]
        ),
        store,
    )


@pytest.mark.parametrize(
    ('source_kind', 'authorization_basis'),
    [
        ('consented_conversation', 'self_only'),
        ('manual_text', 'participants_consented'),
    ],
)
@pytest.mark.asyncio
async def test_extraction_rejects_invalid_consent_before_calling_provider(
    tmp_path: Path, source_kind: str, authorization_basis: str
) -> None:
    intelligence = _FakeIntelligence()
    service, _ = await _service(tmp_path, intelligence=intelligence)

    with pytest.raises(AuthorizationBasisError):
        await service.extract(_extraction_request(source_kind=source_kind, authorization_basis=authorization_basis))

    assert intelligence.extract_calls == 0


@pytest.mark.asyncio
async def test_extraction_accepts_consent_and_deduplicates_only_supported_suggestions(tmp_path: Path) -> None:
    supported = StructuredSuggestion(
        suggested_type=SuggestionType.TASK,
        title='Prepare the deck',
        proposed_time_text='tomorrow',
        source_ref='provider-must-not-control-this',
        supporting_excerpt='I will prepare the deck tomorrow.',
        uncertainty=0.1,
    )
    duplicate = supported.model_copy(update={'title': '  PREPARE   THE DECK  '})
    unsupported = supported.model_copy(
        update={
            'title': 'Book a flight',
            'supporting_excerpt': 'I will book a flight to Tokyo.',
        }
    )
    intelligence = _FakeIntelligence(suggestions=[supported, duplicate, unsupported])
    service, _ = await _service(tmp_path, intelligence=intelligence)

    response = await service.extract(
        _extraction_request(
            source_kind='consented_conversation',
            authorization_basis='participants_consented',
        )
    )

    assert len(response.suggestions) == 1
    assert response.suggestions[0].title == 'Prepare the deck'
    assert response.suggestions[0].source_ref == 'capture-1'
    assert response.suggestions[0].review_state == 'pending'
    assert intelligence.extract_calls == 1


@pytest.mark.asyncio
async def test_provider_unavailable_and_disabled_integrations_fail_closed(tmp_path: Path) -> None:
    failure = IntelligenceUnavailableError('local provider secret detail')
    intelligence = _FakeIntelligence(failure=failure)
    service, _ = await _service(tmp_path, intelligence=intelligence)

    with pytest.raises(IntelligenceUnavailableError):
        await service.extract(_extraction_request())

    disabled, _ = await _service(tmp_path / 'disabled')
    with pytest.raises(IntegrationDisabledError, match='TimeTree integration is disabled'):
        await disabled.list_calendars()
    with pytest.raises(IntegrationDisabledError, match='Local intelligence is disabled'):
        await disabled.extract(_extraction_request())


@pytest.mark.asyncio
async def test_prepare_is_write_free_and_confirmation_is_exactly_once(tmp_path: Path) -> None:
    timetree = _FakeTimeTree()
    service, store = await _service(tmp_path, timetree=timetree)
    request = _create_request()

    preview = await service.prepare_calendar_operation('owner-uid', request, now=NOW)
    stored = await store.get('owner-uid', preview.operation_id)

    assert timetree.create_calls == []
    assert stored.request == request
    assert stored.preview == preview

    first = await service.confirm_calendar_operation('owner-uid', preview.operation_id, now=NOW)
    second = await service.confirm_calendar_operation('owner-uid', preview.operation_id, now=NOW + timedelta(seconds=1))

    assert first.status == 'succeeded'
    assert second == first
    assert [(calendar_id, draft.title) for calendar_id, draft in timetree.create_calls] == [
        ('calendar_1', 'Prepare presentation')
    ]


@pytest.mark.asyncio
async def test_idempotency_replays_same_preview_and_rejects_changed_request(tmp_path: Path) -> None:
    service, _ = await _service(tmp_path, timetree=_FakeTimeTree())
    original = _create_request(key='same-key-123')

    first = await service.prepare_calendar_operation('owner-uid', original, now=NOW)
    second = await service.prepare_calendar_operation('owner-uid', original, now=NOW + timedelta(seconds=1))

    assert second == first
    with pytest.raises(OperationConflictError, match='different operation'):
        await service.prepare_calendar_operation(
            'owner-uid',
            _create_request(key='same-key-123', title='Changed title'),
            now=NOW + timedelta(seconds=2),
        )


@pytest.mark.asyncio
async def test_expired_or_interrupted_confirmation_never_replays_a_write(tmp_path: Path) -> None:
    settings = _settings(
        tmp_path / 'state' / 'operations.sqlite3',
        confirmation_ttl_seconds=60,
    )
    timetree = _FakeTimeTree()
    service, store = await _service(tmp_path, timetree=timetree, settings=settings)

    expired_preview = await service.prepare_calendar_operation('owner-uid', _create_request(key='expires-key'), now=NOW)
    expired = await service.confirm_calendar_operation(
        'owner-uid', expired_preview.operation_id, now=NOW + timedelta(seconds=61)
    )
    assert expired.status == 'failed'

    interrupted_preview = await service.prepare_calendar_operation(
        'owner-uid', _create_request(key='interrupted-key'), now=NOW
    )
    claimed = await store.claim('owner-uid', interrupted_preview.operation_id, NOW)
    assert claimed.status == 'executing'
    restarted_service = PersonalIntelligenceService(
        settings=settings,
        operations=store,
        timetree=timetree,  # type: ignore[arg-type]
        intelligence=None,
    )
    interrupted = await restarted_service.confirm_calendar_operation(
        'owner-uid', interrupted_preview.operation_id, now=NOW + timedelta(seconds=1)
    )

    assert interrupted.status == 'uncertain'
    assert timetree.create_calls == []


@pytest.mark.asyncio
async def test_recurring_event_requires_explicit_series_scope(tmp_path: Path) -> None:
    timetree = _FakeTimeTree(target=_event(recurring=True))
    service, _ = await _service(tmp_path, timetree=timetree)

    def update(scope: str | None, key: str) -> CalendarOperationRequest:
        return CalendarOperationRequest(
            kind=CalendarOperationKind.UPDATE,
            idempotency_key=key,
            calendar_id='calendar_1',
            event_uuid='event_1',
            changes=CalendarEventPatch(title='Updated series'),
            recurrence_scope=scope,
        )

    with pytest.raises(RecurrenceScopeError, match='entire recurring series'):
        await service.prepare_calendar_operation('owner-uid', update(None, 'scope-key-1'), now=NOW)
    with pytest.raises(RecurrenceScopeError, match='one recurring occurrence'):
        await service.prepare_calendar_operation('owner-uid', update('occurrence', 'scope-key-2'), now=NOW)

    preview = await service.prepare_calendar_operation('owner-uid', update('series', 'scope-key-3'), now=NOW)
    assert preview.recurrence_scope == 'series'
    assert timetree.update_calls == []


@pytest.mark.parametrize(
    ('failure', 'expected_status'),
    [
        (UncertainWriteOutcome('create', 'calendar_1'), 'uncertain'),
        (TimeTreeError('provider rejected request'), 'failed'),
    ],
)
@pytest.mark.asyncio
async def test_confirmation_records_provider_failure_without_retry(
    tmp_path: Path, failure: Exception, expected_status: str
) -> None:
    timetree = _FakeTimeTree()
    timetree.write_failure = failure
    service, store = await _service(tmp_path, timetree=timetree)
    preview = await service.prepare_calendar_operation('owner-uid', _create_request(), now=NOW)

    outcome = await service.confirm_calendar_operation('owner-uid', preview.operation_id, now=NOW)
    replay = await service.confirm_calendar_operation('owner-uid', preview.operation_id, now=NOW + timedelta(seconds=1))

    assert outcome.status == expected_status
    assert replay == outcome
    assert len(timetree.create_calls) == 1
    assert (await store.get('owner-uid', preview.operation_id)).outcome == outcome


@pytest.mark.asyncio
async def test_assistant_calendar_write_is_only_a_proposal_and_tasks_come_from_supplied_context(
    tmp_path: Path,
) -> None:
    timetree = _FakeTimeTree()
    create_plan = AssistantPlan(
        action=AssistantAction.CALENDAR_CREATE,
        response='Created it successfully',
        explicit_timetree=True,
        calendar_id='calendar_1',
        event=_draft(),
    )
    intelligence = _FakeIntelligence(plan=create_plan)
    service, _ = await _service(tmp_path, timetree=timetree, intelligence=intelligence)
    request = AssistantRequest(
        message='Add this to TimeTree',
        timezone='America/Toronto',
        now=NOW,
    )

    proposal = await service.assistant(request)

    assert proposal.calendar_proposal is not None
    assert proposal.calendar_proposal.kind == CalendarOperationKind.CREATE
    assert proposal.message == 'Review the proposed TimeTree change. Nothing has been written yet.'
    assert timetree.create_calls == []

    intelligence.plan = AssistantPlan(
        action=AssistantAction.TASK_QUERY,
        response='Hallucinated task: upload secrets',
    )
    task_request = AssistantRequest(
        message='What are my tasks?',
        timezone='America/Toronto',
        now=NOW,
        open_tasks=[
            LocalTaskContext(task_id='task-1', title='Ship the deck'),
            LocalTaskContext(task_id='task-2', title='Email Sam'),
        ],
    )
    task_response = await service.assistant(task_request)

    assert task_response.message == 'Open tasks: Ship the deck; Email Sam'
    assert 'upload secrets' not in task_response.message
    assert task_response.used_local_tasks is True


@pytest.mark.parametrize(
    'plan_fields',
    [
        {
            'action': AssistantAction.CALENDAR_UPDATE,
            'event_query': 'dentist',
            'changes': CalendarEventPatch(title='Moved dentist appointment'),
        },
        {
            'action': AssistantAction.CALENDAR_DELETE,
            'event_uuid': 'event_1',
            'event_query': 'dentist',
        },
        {
            'action': AssistantAction.CALENDAR_CREATE,
            'event': _draft(),
            'changes': CalendarEventPatch(title='Unrelated patch'),
        },
    ],
)
def test_assistant_plan_rejects_ambiguous_or_cross_operation_write_fields(plan_fields: dict[str, Any]) -> None:
    with pytest.raises(ValueError):
        AssistantPlan(**plan_fields)


def test_assistant_plan_accepts_one_query_target_only_with_a_bounded_aware_range() -> None:
    plan = AssistantPlan(
        action=AssistantAction.CALENDAR_UPDATE,
        event_query='dentist',
        range_start=NOW,
        range_end=NOW + timedelta(days=7),
        changes=CalendarEventPatch(title='Moved dentist appointment'),
    )

    assert plan.event_query == 'dentist'


@pytest.mark.parametrize(
    'proposal_fields',
    [
        {'kind': CalendarOperationKind.CREATE},
        {
            'kind': CalendarOperationKind.CREATE,
            'event': _draft(),
            'event_uuid': 'event_1',
        },
        {
            'kind': CalendarOperationKind.UPDATE,
            'event_uuid': 'event_1',
        },
        {
            'kind': CalendarOperationKind.UPDATE,
            'event_uuid': 'event_1',
            'changes': CalendarEventPatch(title='Moved'),
            'event': _draft(),
        },
        {
            'kind': CalendarOperationKind.DELETE,
            'event_uuid': 'event_1',
            'changes': CalendarEventPatch(title='Should not be here'),
        },
    ],
)
def test_calendar_write_proposal_rejects_incomplete_or_cross_operation_shapes(
    proposal_fields: dict[str, Any],
) -> None:
    with pytest.raises(ValueError):
        CalendarWriteProposal(explanation='Review this change', **proposal_fields)


@pytest.mark.asyncio
async def test_store_permissions_owner_isolation_and_owner_scoped_clear(tmp_path: Path) -> None:
    state_path = tmp_path / 'private-state' / 'operations.sqlite3'
    service, store = await _service(
        tmp_path,
        timetree=_FakeTimeTree(),
        settings=_settings(state_path),
    )
    owner_preview = await service.prepare_calendar_operation('owner-uid', _create_request(key='shared-key-1'), now=NOW)
    other_preview = await service.prepare_calendar_operation(
        'other-owner', _create_request(key='shared-key-1'), now=NOW
    )

    assert os.stat(state_path.parent).st_mode & 0o777 == 0o700
    assert os.stat(state_path).st_mode & 0o777 == 0o600
    with pytest.raises(OperationNotFoundError):
        await store.get('other-owner', owner_preview.operation_id)

    assert await store.clear('owner-uid') == 1
    with pytest.raises(OperationNotFoundError):
        await store.get('owner-uid', owner_preview.operation_id)
    assert (await store.get('other-owner', other_preview.operation_id)).owner_uid == 'other-owner'
