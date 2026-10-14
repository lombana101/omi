from __future__ import annotations

import asyncio
import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4
from zoneinfo import ZoneInfo

from personal_intelligence.config import Settings
from personal_intelligence.llm import AssistantAction, AssistantPlan, OllamaIntelligenceClient
from personal_intelligence.models import (
    AssistantRequest,
    AssistantResponse,
    CalendarOperationKind,
    CalendarOperationOutcome,
    CalendarOperationPreview,
    CalendarOperationRequest,
    CalendarWriteProposal,
    ExtractionRequest,
    ExtractionResponse,
    TimeTreeCalendar,
    TimeTreeEvent,
)
from personal_intelligence.operation_store import OperationStore, StoredOperation
from personal_intelligence.timetree import TimeTreeClient, TimeTreeError, UncertainWriteOutcome


class AuthorizationBasisError(RuntimeError):
    pass


class IntegrationDisabledError(RuntimeError):
    pass


class CalendarSelectionError(RuntimeError):
    pass


class RecurrenceScopeError(RuntimeError):
    pass


class OperationValidationError(RuntimeError):
    pass


class PersonalIntelligenceService:
    def __init__(
        self,
        *,
        settings: Settings,
        operations: OperationStore,
        timetree: TimeTreeClient | None,
        intelligence: OllamaIntelligenceClient | None,
    ) -> None:
        self._settings = settings
        self._operations = operations
        self._timetree = timetree
        self._intelligence = intelligence
        self._confirmation_lock = asyncio.Lock()

    async def close(self) -> None:
        if self._timetree is not None:
            await self._timetree.close()
        if self._intelligence is not None:
            await self._intelligence.close()

    def _calendar_client(self) -> TimeTreeClient:
        if self._timetree is None:
            raise IntegrationDisabledError('TimeTree integration is disabled or not configured')
        return self._timetree

    def _intelligence_client(self) -> OllamaIntelligenceClient:
        if self._intelligence is None:
            raise IntegrationDisabledError('Local intelligence is disabled or not configured')
        return self._intelligence

    async def list_calendars(self) -> list[TimeTreeCalendar]:
        return await self._calendar_client().list_calendars()

    async def _select_calendar(self, requested_id: str | None) -> TimeTreeCalendar:
        calendars = await self.list_calendars()
        selected_id = requested_id or self._settings.timetree_default_calendar_id
        if selected_id:
            match = next((calendar for calendar in calendars if calendar.id == selected_id), None)
            if match is None:
                raise CalendarSelectionError('Configured calendar is not available')
            return match
        if len(calendars) == 1:
            return calendars[0]
        if not calendars:
            raise CalendarSelectionError('No TimeTree calendars are available')
        raise CalendarSelectionError('Choose a TimeTree calendar before continuing')

    async def search_events(
        self,
        *,
        calendar_id: str | None = None,
        query: str | None = None,
        start_at: datetime | None = None,
        end_at: datetime | None = None,
        limit: int = 50,
    ) -> list[TimeTreeEvent]:
        client = self._calendar_client()
        calendars = await self.list_calendars()
        if calendar_id is not None:
            calendars = [calendar for calendar in calendars if calendar.id == calendar_id]
            if not calendars:
                raise CalendarSelectionError('Requested TimeTree calendar is not available')
        normalized_query = (query or '').strip().casefold()
        matches: list[TimeTreeEvent] = []
        for calendar in calendars:
            for event in await client.list_events(calendar.id):
                if start_at is not None and event.end_at < start_at.astimezone(UTC):
                    continue
                if end_at is not None and event.start_at >= end_at.astimezone(UTC):
                    continue
                if normalized_query:
                    searchable = ' '.join((event.title, event.location or '', event.note or '')).casefold()
                    if normalized_query not in searchable:
                        continue
                matches.append(event)
        matches.sort(key=lambda event: (event.start_at, event.end_at, event.uuid))
        return matches[:limit]

    async def extract(self, request: ExtractionRequest) -> ExtractionResponse:
        self._validate_authorization_basis(request)
        suggestions = await self._intelligence_client().extract(request)
        result = []
        seen: set[tuple[str, str, str]] = set()
        source_text = ' '.join(request.text.split()).casefold()
        for suggestion in suggestions:
            excerpt = ' '.join(suggestion.supporting_excerpt.split())
            if excerpt.casefold() not in source_text:
                continue
            normalized = (
                suggestion.suggested_type.value,
                ' '.join(suggestion.title.split()).casefold(),
                suggestion.proposed_time_text or '',
            )
            if normalized in seen:
                continue
            seen.add(normalized)
            result.append(
                suggestion.model_copy(
                    update={
                        'source_ref': request.source_ref,
                        'supporting_excerpt': excerpt,
                        'review_state': 'pending',
                    }
                )
            )
        return ExtractionResponse(suggestions=result, extractor='ollama-structured-v1')

    @staticmethod
    def _validate_authorization_basis(request: ExtractionRequest) -> None:
        if request.source_kind == 'consented_conversation':
            if request.authorization_basis != 'participants_consented':
                raise AuthorizationBasisError('Consented conversations require a participants_consented basis')
            return
        if request.authorization_basis != 'self_only':
            raise AuthorizationBasisError('Self-authored sources require a self_only basis')

    async def prepare_calendar_operation(
        self, owner_uid: str, request: CalendarOperationRequest, *, now: datetime
    ) -> CalendarOperationPreview:
        calendar = await self._select_calendar(request.calendar_id)
        operation_id = uuid4().hex
        expires_at = now.astimezone(UTC) + timedelta(seconds=self._settings.confirmation_ttl_seconds)

        if request.kind == CalendarOperationKind.CREATE:
            assert request.event is not None
            event = request.event
            preview = CalendarOperationPreview(
                operation_id=operation_id,
                kind=request.kind,
                calendar_id=calendar.id,
                calendar_name=calendar.name,
                title=event.title,
                start_at=event.start_at,
                end_at=event.end_at,
                timezone=event.start_timezone,
                all_day=event.all_day,
                recurrence_scope='series' if event.recurrences else 'not_recurring',
                changes=['Create this event'],
                expires_at=expires_at,
            )
        else:
            assert request.event_uuid is not None
            target = await self._calendar_client().get_event(calendar.id, request.event_uuid)
            recurrence_scope = self._recurrence_scope(target, request.recurrence_scope)
            if request.kind == CalendarOperationKind.DELETE:
                preview = CalendarOperationPreview(
                    operation_id=operation_id,
                    kind=request.kind,
                    calendar_id=calendar.id,
                    calendar_name=calendar.name,
                    event_uuid=target.uuid,
                    title=target.title,
                    start_at=target.start_at,
                    end_at=target.end_at,
                    timezone=target.start_timezone,
                    all_day=target.all_day,
                    recurrence_scope=recurrence_scope,
                    changes=['Delete this event'],
                    expires_at=expires_at,
                )
            else:
                assert request.changes is not None
                fields = request.changes.model_fields_set
                start = request.changes.start_at if 'start_at' in fields else target.start_at
                end = request.changes.end_at if 'end_at' in fields else target.end_at
                resulting_all_day = request.changes.all_day if 'all_day' in fields else target.all_day
                if start is None or end is None or end < start or (end == start and not resulting_all_day):
                    raise OperationValidationError('Updated event end must be after its start')
                preview = CalendarOperationPreview(
                    operation_id=operation_id,
                    kind=request.kind,
                    calendar_id=calendar.id,
                    calendar_name=calendar.name,
                    event_uuid=target.uuid,
                    title=(request.changes.title or target.title) if 'title' in fields else target.title,
                    start_at=start,
                    end_at=end,
                    timezone=(
                        request.changes.start_timezone or target.start_timezone
                        if 'start_timezone' in fields
                        else target.start_timezone
                    ),
                    all_day=resulting_all_day,
                    recurrence_scope=recurrence_scope,
                    changes=sorted(fields),
                    expires_at=expires_at,
                )

        stored = await self._operations.prepare(
            owner_uid=owner_uid,
            operation_id=operation_id,
            request=request.model_copy(update={'calendar_id': calendar.id}),
            preview=preview,
            now=now,
        )
        return stored.preview

    @staticmethod
    def _recurrence_scope(event: TimeTreeEvent, requested: str | None) -> str:
        if not event.is_recurring:
            return 'not_recurring'
        if requested == 'occurrence':
            raise RecurrenceScopeError('Editing one recurring occurrence is not safely supported')
        if requested != 'series':
            raise RecurrenceScopeError('Confirm that the entire recurring series will be affected')
        return 'series'

    async def confirm_calendar_operation(
        self, owner_uid: str, operation_id: str, *, now: datetime
    ) -> CalendarOperationOutcome:
        async with self._confirmation_lock:
            existing = await self._operations.get(owner_uid, operation_id)
            if existing.outcome is not None:
                return existing.outcome
            if existing.status == 'executing':
                uncertain = CalendarOperationOutcome(
                    operation_id=operation_id,
                    status='uncertain',
                    message='A previous confirmation may still have reached TimeTree; inspect the calendar before retrying',
                )
                await self._operations.finish(owner_uid, uncertain, now)
                return uncertain
            claimed = await self._operations.claim(owner_uid, operation_id, now)
            if claimed.outcome is not None:
                return claimed.outcome
            if claimed.status != 'executing':
                return CalendarOperationOutcome(
                    operation_id=operation_id,
                    status='failed',
                    message='Calendar operation could not be confirmed',
                )
            outcome = await self._execute_calendar_operation(claimed)
            await self._operations.finish(owner_uid, outcome, now)
            return outcome

    async def _execute_calendar_operation(self, operation: StoredOperation) -> CalendarOperationOutcome:
        request = operation.request
        assert request.calendar_id is not None
        client = self._calendar_client()
        try:
            if request.kind == CalendarOperationKind.CREATE:
                assert request.event is not None
                event = await client.create_event(request.calendar_id, request.event)
                return CalendarOperationOutcome(
                    operation_id=operation.operation_id,
                    status='succeeded',
                    message='TimeTree confirmed that the event was created',
                    event=event,
                )
            if request.kind == CalendarOperationKind.UPDATE:
                assert request.event_uuid is not None and request.changes is not None
                event = await client.update_event(
                    request.calendar_id, request.event_uuid, request.changes.provider_payload()
                )
                return CalendarOperationOutcome(
                    operation_id=operation.operation_id,
                    status='succeeded',
                    message='TimeTree confirmed that the event was updated',
                    event=event,
                )
            assert request.event_uuid is not None
            await client.delete_event(request.calendar_id, request.event_uuid)
            return CalendarOperationOutcome(
                operation_id=operation.operation_id,
                status='succeeded',
                message='TimeTree confirmed that the event was deleted',
            )
        except UncertainWriteOutcome:
            return CalendarOperationOutcome(
                operation_id=operation.operation_id,
                status='uncertain',
                message='TimeTree may have applied the change; inspect the calendar before preparing another write',
            )
        except TimeTreeError:
            return CalendarOperationOutcome(
                operation_id=operation.operation_id,
                status='failed',
                message='TimeTree rejected the calendar operation',
            )
        except Exception:
            return CalendarOperationOutcome(
                operation_id=operation.operation_id,
                status='uncertain',
                message='The operation ended unexpectedly; inspect TimeTree before retrying',
            )

    async def assistant(self, request: AssistantRequest) -> AssistantResponse:
        plan = await self._intelligence_client().plan_assistant(
            message=request.message,
            timezone=request.timezone,
            now=request.now,
            tasks=request.open_tasks,
        )
        if plan.action == AssistantAction.TASK_QUERY:
            return self._task_answer(request, today_only=False)
        if plan.action == AssistantAction.TODAY_QUERY:
            task_answer = self._task_answer(request, today_only=True)
            if self._settings.timetree_prefer_for_generic_calendar and self._timetree is not None:
                zone = ZoneInfo(request.timezone)
                local_now = request.now.astimezone(zone)
                start = datetime(local_now.year, local_now.month, local_now.day, tzinfo=zone)
                events = await self.search_events(start_at=start, end_at=start + timedelta(days=1))
                return task_answer.model_copy(
                    update={
                        'events': events,
                        'used_timetree': True,
                        'message': self._combined_today_message(task_answer.message, events),
                    }
                )
            return task_answer
        if plan.action == AssistantAction.CALENDAR_READ:
            if not self._calendar_allowed(plan):
                return AssistantResponse(
                    message='Generic calendar requests are not configured to use TimeTree; say “TimeTree” explicitly.',
                )
            events = await self.search_events(
                calendar_id=plan.calendar_id,
                query=plan.event_query,
                start_at=plan.range_start,
                end_at=plan.range_end,
            )
            return AssistantResponse(message=self._calendar_message(events), events=events, used_timetree=True)
        if plan.action == AssistantAction.TASK_SUGGESTION:
            suggestion = plan.task_suggestion
            suggestions = []
            if suggestion is not None:
                excerpt = ' '.join(suggestion.supporting_excerpt.split())
                source = ' '.join(request.message.split())
                if excerpt.casefold() in source.casefold():
                    source_digest = hashlib.sha256(request.message.encode()).hexdigest()[:24]
                    suggestions = [
                        suggestion.model_copy(
                            update={
                                'source_ref': f'assistant:{source_digest}',
                                'supporting_excerpt': excerpt,
                                'review_state': 'pending',
                            }
                        )
                    ]
            return AssistantResponse(
                message=(
                    plan.response or 'Review the task suggestion before saving it.'
                    if suggestions
                    else 'I could not ground that suggestion in your request.'
                ),
                task_suggestions=suggestions,
                used_local_tasks=True,
            )
        if plan.action in {
            AssistantAction.CALENDAR_CREATE,
            AssistantAction.CALENDAR_UPDATE,
            AssistantAction.CALENDAR_DELETE,
        }:
            return await self._calendar_proposal(plan)
        return AssistantResponse(message=plan.response or 'I do not have enough information to answer that.')

    def _calendar_allowed(self, plan: AssistantPlan) -> bool:
        return plan.explicit_timetree or self._settings.timetree_prefer_for_generic_calendar

    async def _calendar_proposal(self, plan: AssistantPlan) -> AssistantResponse:
        if not self._calendar_allowed(plan):
            return AssistantResponse(
                message='Generic calendar requests are not configured to use TimeTree; say “TimeTree” explicitly.',
            )
        action_to_kind = {
            AssistantAction.CALENDAR_CREATE: CalendarOperationKind.CREATE,
            AssistantAction.CALENDAR_UPDATE: CalendarOperationKind.UPDATE,
            AssistantAction.CALENDAR_DELETE: CalendarOperationKind.DELETE,
        }
        kind = action_to_kind[plan.action]
        calendar_id = plan.calendar_id
        event_uuid = plan.event_uuid
        if kind != CalendarOperationKind.CREATE and event_uuid is None:
            candidates = await self.search_events(
                calendar_id=calendar_id,
                query=plan.event_query,
                start_at=plan.range_start,
                end_at=plan.range_end,
                limit=3,
            )
            if len(candidates) != 1:
                message = (
                    'No matching TimeTree event was found.'
                    if not candidates
                    else 'More than one event matches; choose one.'
                )
                return AssistantResponse(message=message, events=candidates, used_timetree=True)
            event_uuid = candidates[0].uuid
            calendar_id = candidates[0].calendar_id
        proposal = CalendarWriteProposal(
            kind=kind,
            calendar_id=calendar_id,
            event_uuid=event_uuid,
            event=plan.event,
            changes=plan.changes,
            recurrence_scope=plan.recurrence_scope,
            explanation=plan.response or 'Review the exact calendar change before confirming.',
        )
        return AssistantResponse(
            message='Review the proposed TimeTree change. Nothing has been written yet.',
            calendar_proposal=proposal,
            used_timetree=True,
        )

    @staticmethod
    def _task_answer(request: AssistantRequest, *, today_only: bool) -> AssistantResponse:
        tasks = request.open_tasks
        if today_only:
            zone = ZoneInfo(request.timezone)
            today = request.now.astimezone(zone).date()
            tasks = [
                task
                for task in tasks
                if task.in_today or (task.due_at is not None and task.due_at.astimezone(zone).date() <= today)
            ]
        if not tasks:
            message = 'You have no matching open tasks.'
        else:
            message = 'Open tasks: ' + '; '.join(task.title for task in tasks)
        return AssistantResponse(message=message, used_local_tasks=True)

    @staticmethod
    def _calendar_message(events: list[TimeTreeEvent]) -> str:
        if not events:
            return 'No matching TimeTree events were found.'
        return 'TimeTree events: ' + '; '.join(event.title for event in events)

    @staticmethod
    def _combined_today_message(task_message: str, events: list[TimeTreeEvent]) -> str:
        if not events:
            return f'{task_message} No TimeTree events are scheduled today.'
        return f'{task_message} TimeTree: ' + '; '.join(event.title for event in events)
