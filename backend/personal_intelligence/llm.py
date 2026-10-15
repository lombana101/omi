from __future__ import annotations

import json
from datetime import datetime
from enum import StrEnum
from typing import TypeVar

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from personal_intelligence.models import (
    CalendarEventDraft,
    CalendarEventPatch,
    ExtractionRequest,
    LocalTaskContext,
    StructuredSuggestion,
)


class IntelligenceUnavailableError(RuntimeError):
    pass


class InvalidModelOutputError(RuntimeError):
    pass


class AssistantAction(StrEnum):
    ANSWER = 'answer'
    TASK_QUERY = 'task_query'
    TODAY_QUERY = 'today_query'
    TOMORROW_QUERY = 'tomorrow_query'
    CALENDAR_READ = 'calendar_read'
    TASK_SUGGESTION = 'task_suggestion'
    CALENDAR_CREATE = 'calendar_create'
    CALENDAR_UPDATE = 'calendar_update'
    CALENDAR_DELETE = 'calendar_delete'


class SuggestionEnvelope(BaseModel):
    model_config = ConfigDict(extra='forbid')
    suggestions: list[StructuredSuggestion] = Field(default_factory=list, max_length=20)


class AssistantPlan(BaseModel):
    model_config = ConfigDict(extra='forbid')

    action: AssistantAction
    response: str = Field(default='', max_length=1500)
    explicit_timetree: bool = False
    calendar_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    event_uuid: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    event_query: str | None = Field(default=None, max_length=300)
    range_start: datetime | None = None
    range_end: datetime | None = None
    event: CalendarEventDraft | None = None
    changes: CalendarEventPatch | None = None
    recurrence_scope: str | None = Field(default=None, pattern=r'^(occurrence|series)$')
    task_suggestion: StructuredSuggestion | None = None

    @model_validator(mode='after')
    def validate_action(self) -> 'AssistantPlan':
        for value in (self.range_start, self.range_end):
            if value is not None and value.tzinfo is None:
                raise ValueError('assistant calendar ranges must include a timezone')
        if self.range_start is not None and self.range_end is not None and self.range_end <= self.range_start:
            raise ValueError('assistant calendar range end must be after its start')
        if self.action == AssistantAction.TASK_SUGGESTION and self.task_suggestion is None:
            raise ValueError('task_suggestion action requires a suggestion')
        if self.action == AssistantAction.CALENDAR_CREATE:
            if self.event is None:
                raise ValueError('calendar_create requires an event')
            if self.event_uuid is not None or self.event_query or self.changes is not None or self.recurrence_scope:
                raise ValueError('calendar_create contains fields for a different operation')
        if self.action == AssistantAction.CALENDAR_UPDATE:
            if self.event is not None:
                raise ValueError('calendar_update must contain changes, not a complete event')
            if self.changes is None:
                raise ValueError('calendar_update requires changes and a target')
            self._validate_write_target('calendar_update')
        if self.action == AssistantAction.CALENDAR_DELETE:
            if self.event is not None or self.changes is not None:
                raise ValueError('calendar_delete contains fields for a different operation')
            self._validate_write_target('calendar_delete')
        return self

    def _validate_write_target(self, action: str) -> None:
        has_uuid = self.event_uuid is not None
        has_query = bool(self.event_query)
        if has_uuid == has_query:
            raise ValueError(f'{action} requires exactly one event target')
        if has_query and (self.range_start is None or self.range_end is None):
            raise ValueError(f'{action} query targets require a bounded time range')


ModelT = TypeVar('ModelT', bound=BaseModel)


class OllamaIntelligenceClient:
    """Lifecycle-managed local Ollama client using validated structured output."""

    def __init__(
        self,
        *,
        base_url: str,
        model: str,
        timeout_seconds: float,
        client: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip('/')
        self._model = model
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient(
            timeout=httpx.Timeout(timeout_seconds, connect=min(timeout_seconds, 3.0))
        )

    async def close(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    async def _structured(self, output_type: type[ModelT], *, system: str, user: str) -> ModelT:
        body = {
            'model': self._model,
            'stream': False,
            'format': output_type.model_json_schema(),
            'options': {'temperature': 0},
            'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
            ],
        }
        try:
            response = await self._client.post(f'{self._base_url}/api/chat', json=body)
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError, TypeError) as exc:
            raise IntelligenceUnavailableError('Local intelligence provider is unavailable') from exc
        try:
            content = payload['message']['content']
            decoded = json.loads(content) if isinstance(content, str) else content
            return output_type.model_validate(decoded)
        except (KeyError, TypeError, ValueError, json.JSONDecodeError, ValidationError) as exc:
            raise InvalidModelOutputError('Local intelligence provider returned invalid structured output') from exc

    async def extract(self, request: ExtractionRequest) -> list[StructuredSuggestion]:
        system = (
            'Extract only reviewable actions about the owner from authorized input. '
            'Return tasks, calendar events, commitments, projects, habits, or general intentions. '
            'Questions, hypotheticals, reflections without an action, and facts about other people are not actions. '
            'Never invent a commitment, date, deadline, timezone, or event identifier. '
            'Keep relative phrases such as "next Friday" in proposed_time_text unless the text itself and supplied '
            'clock make the intended instant unambiguous. AI interpretations remain pending suggestions, never facts. '
            'supporting_excerpt must be a short verbatim excerpt from the supplied text. '
            'For a consented conversation, include only the owner\'s own commitment and minimize third-party detail.'
        )
        user = json.dumps(
            {
                'source_ref': request.source_ref,
                'source_kind': request.source_kind,
                'authorization_basis': request.authorization_basis,
                'timezone': request.timezone,
                'now': request.now.isoformat(),
                'text': request.text,
            },
            ensure_ascii=False,
        )
        envelope = await self._structured(SuggestionEnvelope, system=system, user=user)
        return envelope.suggestions

    async def plan_assistant(
        self,
        *,
        message: str,
        timezone: str,
        now: datetime,
        tasks: list[LocalTaskContext],
    ) -> AssistantPlan:
        system = (
            'Plan one safe action for a personal assistant. Use task_query, today_query, or tomorrow_query for questions '
            'about the provided local tasks; never invent tasks. Use tomorrow_query for prioritization questions about '
            'tomorrow. Use calendar_read for calendar questions. Set explicit_timetree '
            'only when the user explicitly says TimeTree. Calendar create/update/delete are proposals only and must '
            'contain the requested data without claiming success. If a date or target is ambiguous, use answer and ask '
            'one concise question. For update/delete, provide event_uuid only if the user supplied it; otherwise provide '
            'event_query and a bounded time range. A request for one recurring occurrence must set occurrence; never '
            'silently choose series. Task creation returns one pending task_suggestion. Preserve uncertainty.'
        )
        user = json.dumps(
            {
                'message': message,
                'timezone': timezone,
                'now': now.isoformat(),
                'open_tasks': [task.model_dump(mode='json') for task in tasks],
            },
            ensure_ascii=False,
        )
        return await self._structured(AssistantPlan, system=system, user=user)
