from __future__ import annotations

from datetime import UTC, date, datetime
from enum import StrEnum
from typing import Any, Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class SuggestionType(StrEnum):
    TASK = 'task'
    CALENDAR_EVENT = 'calendar_event'
    COMMITMENT = 'commitment'
    PROJECT = 'project'
    HABIT = 'habit'
    INTENTION = 'intention'
    ADVICE = 'advice'


class StructuredSuggestion(BaseModel):
    model_config = ConfigDict(extra='forbid')

    suggested_type: SuggestionType
    title: str = Field(min_length=1, max_length=200)
    description: str | None = Field(default=None, max_length=1000)
    proposed_time_text: str | None = Field(default=None, max_length=120)
    start_at: datetime | None = None
    end_at: datetime | None = None
    timezone: str | None = Field(default=None, max_length=64)
    source_ref: str = Field(min_length=1, max_length=160)
    supporting_excerpt: str = Field(min_length=1, max_length=240)
    uncertainty: float = Field(ge=0, le=1)
    review_state: Literal['pending'] = 'pending'

    @model_validator(mode='after')
    def validate_time(self) -> 'StructuredSuggestion':
        if self.start_at is not None and self.start_at.tzinfo is None:
            raise ValueError('start_at must include a timezone')
        if self.end_at is not None and self.end_at.tzinfo is None:
            raise ValueError('end_at must include a timezone')
        if self.start_at is not None and self.end_at is not None and self.end_at <= self.start_at:
            raise ValueError('end_at must be after start_at')
        return self


class ExtractionRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    source_ref: str = Field(min_length=1, max_length=160)
    source_kind: Literal['self_authored_transcript', 'manual_text', 'owner_note', 'consented_conversation']
    authorization_basis: Literal['self_only', 'participants_consented']
    text: str = Field(min_length=1, max_length=12000)
    timezone: str = Field(min_length=1, max_length=64)
    now: datetime

    @field_validator('timezone')
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError('timezone must be an IANA timezone') from exc
        return value

    @field_validator('now')
    @classmethod
    def aware_now(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError('now must include a timezone')
        return value


class ExtractionResponse(BaseModel):
    suggestions: list[StructuredSuggestion]
    extractor: str


class TimeTreeCalendar(BaseModel):
    model_config = ConfigDict(extra='ignore')

    id: str
    name: str


class TimeTreeEvent(BaseModel):
    model_config = ConfigDict(extra='ignore')

    uuid: str
    calendar_id: str
    title: str
    all_day: bool
    start_at: datetime
    end_at: datetime
    start_timezone: str = 'UTC'
    end_timezone: str = 'UTC'
    recurrences: list[Any] = Field(default_factory=list)
    author_id: int | None = None
    parent_id: str | None = None
    deactivated_at: int | None = None
    location: str | None = None
    note: str | None = None
    provider_payload: dict[str, Any] = Field(default_factory=dict, exclude=True, repr=False)

    @property
    def is_recurring(self) -> bool:
        return bool(self.recurrences or self.parent_id)

    @classmethod
    def from_provider(cls, payload: dict[str, Any]) -> 'TimeTreeEvent':
        return cls(
            uuid=str(payload['uuid']),
            calendar_id=str(payload['calendar_id']),
            title=str(payload['title']),
            all_day=bool(payload['all_day']),
            start_at=datetime.fromtimestamp(int(payload['start_at']) / 1000, tz=UTC),
            end_at=datetime.fromtimestamp(int(payload['end_at']) / 1000, tz=UTC),
            start_timezone=str(payload.get('start_timezone') or 'UTC'),
            end_timezone=str(payload.get('end_timezone') or 'UTC'),
            recurrences=list(payload.get('recurrences') or []),
            author_id=payload.get('author_id') if isinstance(payload.get('author_id'), int) else None,
            parent_id=str(payload['parent_id']) if payload.get('parent_id') is not None else None,
            deactivated_at=payload.get('deactivated_at'),
            location=payload.get('location') if isinstance(payload.get('location'), str) else None,
            note=payload.get('note') if isinstance(payload.get('note'), str) else None,
            provider_payload=dict(payload),
        )


class CalendarEventDraft(BaseModel):
    model_config = ConfigDict(extra='forbid')

    title: str = Field(min_length=1, max_length=300)
    all_day: bool = False
    start_at: datetime
    end_at: datetime
    start_timezone: str
    end_timezone: str
    note: str | None = Field(default=None, max_length=4000)
    location: str | None = Field(default=None, max_length=500)
    label_id: int | None = Field(default=None, ge=1, le=10)
    category: int = 1
    attendees: list[int] = Field(default_factory=list, max_length=100)
    recurrences: list[str] = Field(default_factory=list, max_length=20)
    alerts: list[int] = Field(default_factory=list, max_length=20)
    file_uuids: list[str] = Field(default_factory=list, max_length=20)

    @model_validator(mode='after')
    def validate_draft(self) -> 'CalendarEventDraft':
        if self.start_at.tzinfo is None or self.end_at.tzinfo is None:
            raise ValueError('calendar timestamps must include a timezone')
        if self.end_at < self.start_at or (self.end_at == self.start_at and not self.all_day):
            raise ValueError('event end must be after its start')
        for timezone_name in (self.start_timezone, self.end_timezone):
            try:
                ZoneInfo(timezone_name)
            except ZoneInfoNotFoundError as exc:
                raise ValueError('event timezone must be an IANA timezone') from exc
        return self

    def provider_payload(self) -> dict[str, Any]:
        payload = self.model_dump(exclude_none=True)
        payload['start_at'] = int(self.start_at.timestamp() * 1000)
        payload['end_at'] = int(self.end_at.timestamp() * 1000)
        return payload


class CalendarEventPatch(BaseModel):
    model_config = ConfigDict(extra='forbid')

    title: str | None = Field(default=None, min_length=1, max_length=300)
    all_day: bool | None = None
    start_at: datetime | None = None
    end_at: datetime | None = None
    start_timezone: str | None = None
    end_timezone: str | None = None
    note: str | None = Field(default=None, max_length=4000)
    location: str | None = Field(default=None, max_length=500)
    label_id: int | None = Field(default=None, ge=1, le=10)
    category: int | None = None
    attendees: list[int] | None = Field(default=None, max_length=100)
    recurrences: list[str] | None = Field(default=None, max_length=20)
    alerts: list[int] | None = Field(default=None, max_length=20)
    file_uuids: list[str] | None = Field(default=None, max_length=20)

    @model_validator(mode='after')
    def validate_patch(self) -> 'CalendarEventPatch':
        if not self.model_fields_set:
            raise ValueError('calendar patch must contain a change')
        required_when_set = {
            'title',
            'all_day',
            'start_at',
            'end_at',
            'start_timezone',
            'end_timezone',
            'category',
            'attendees',
            'recurrences',
            'alerts',
            'file_uuids',
        }
        if any(field in self.model_fields_set and getattr(self, field) is None for field in required_when_set):
            raise ValueError('calendar patch fields cannot be null; omit them when unchanged')
        for value in (self.start_at, self.end_at):
            if value is not None and value.tzinfo is None:
                raise ValueError('calendar timestamps must include a timezone')
        for timezone_name in (self.start_timezone, self.end_timezone):
            if timezone_name is None:
                continue
            try:
                ZoneInfo(timezone_name)
            except ZoneInfoNotFoundError as exc:
                raise ValueError('event timezone must be an IANA timezone') from exc
        return self

    def provider_payload(self) -> dict[str, Any]:
        payload = self.model_dump(exclude_unset=True)
        if self.start_at is not None:
            payload['start_at'] = int(self.start_at.timestamp() * 1000)
        if self.end_at is not None:
            payload['end_at'] = int(self.end_at.timestamp() * 1000)
        return payload


class CalendarOperationKind(StrEnum):
    CREATE = 'create'
    UPDATE = 'update'
    DELETE = 'delete'


class CalendarOperationRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    kind: CalendarOperationKind
    idempotency_key: str = Field(pattern=r'^[A-Za-z0-9_-]{8,128}$')
    calendar_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    event_uuid: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    event: CalendarEventDraft | None = None
    changes: CalendarEventPatch | None = None
    recurrence_scope: Literal['occurrence', 'series'] | None = None

    @model_validator(mode='after')
    def validate_operation(self) -> 'CalendarOperationRequest':
        if self.kind == CalendarOperationKind.CREATE:
            if self.event is None:
                raise ValueError('create requires event')
            if self.event_uuid is not None or self.changes is not None or self.recurrence_scope is not None:
                raise ValueError('create contains fields for a different operation')
        elif self.kind == CalendarOperationKind.UPDATE:
            if not self.event_uuid or not self.changes:
                raise ValueError('update requires event_uuid and at least one change')
            if self.event is not None:
                raise ValueError('update must contain changes, not a complete event')
        else:
            if not self.event_uuid:
                raise ValueError('delete requires event_uuid')
            if self.event is not None or self.changes is not None:
                raise ValueError('delete contains fields for a different operation')
        return self


class CalendarOperationPreview(BaseModel):
    operation_id: str
    kind: CalendarOperationKind
    calendar_id: str
    calendar_name: str
    event_uuid: str | None = None
    title: str
    start_at: datetime
    end_at: datetime
    timezone: str
    all_day: bool
    recurrence_scope: Literal['not_recurring', 'series']
    changes: list[str] = Field(default_factory=list)
    expires_at: datetime


class CalendarOperationOutcome(BaseModel):
    operation_id: str
    status: Literal['pending', 'succeeded', 'failed', 'uncertain']
    message: str
    event: TimeTreeEvent | None = None


class CalendarOperationConfirmation(BaseModel):
    model_config = ConfigDict(extra='forbid')

    operation_id: str = Field(pattern=r'^[a-f0-9]{32}$')


class LocalTaskContext(BaseModel):
    model_config = ConfigDict(extra='forbid')

    task_id: str = Field(min_length=1, max_length=160)
    title: str = Field(min_length=1, max_length=300)
    due_at: datetime | None = None
    project_name: str | None = Field(default=None, max_length=200)
    in_today: bool = False

    @field_validator('due_at')
    @classmethod
    def aware_due_at(cls, value: datetime | None) -> datetime | None:
        if value is not None and value.tzinfo is None:
            raise ValueError('task due_at must include a timezone')
        return value


class AssistantRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')

    message: str = Field(min_length=1, max_length=3000)
    timezone: str = Field(min_length=1, max_length=64)
    now: datetime
    open_tasks: list[LocalTaskContext] = Field(default_factory=list, max_length=250)

    @field_validator('timezone')
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError('timezone must be an IANA timezone') from exc
        return value

    @field_validator('now')
    @classmethod
    def aware_now(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError('now must include a timezone')
        return value


class ProactiveEvaluationRequest(BaseModel):
    """A minimized task snapshot used for one owner-triggered evaluation."""

    model_config = ConfigDict(extra='forbid')

    timezone: str = Field(min_length=1, max_length=64)
    now: datetime
    open_tasks: list[LocalTaskContext] = Field(default_factory=list, max_length=250)

    @field_validator('timezone')
    @classmethod
    def valid_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as exc:
            raise ValueError('timezone must be an IANA timezone') from exc
        return value

    @field_validator('now')
    @classmethod
    def aware_now(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError('now must include a timezone')
        return value


class ProactiveEvaluationResponse(BaseModel):
    suggestions: list[StructuredSuggestion] = Field(default_factory=list)
    used_local_tasks: bool = True
    used_timetree: bool = False
    calendar_status: Literal['not_configured', 'available', 'unavailable'] = 'not_configured'


class CalendarWriteProposal(BaseModel):
    model_config = ConfigDict(extra='forbid')

    kind: CalendarOperationKind
    calendar_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    event_uuid: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    event: CalendarEventDraft | None = None
    changes: CalendarEventPatch | None = None
    recurrence_scope: Literal['occurrence', 'series'] | None = None
    explanation: str = Field(min_length=1, max_length=500)

    @model_validator(mode='after')
    def validate_proposal(self) -> 'CalendarWriteProposal':
        if self.kind == CalendarOperationKind.CREATE:
            if self.event is None:
                raise ValueError('create proposal requires event')
            if self.event_uuid is not None or self.changes is not None or self.recurrence_scope is not None:
                raise ValueError('create proposal contains fields for a different operation')
        elif self.kind == CalendarOperationKind.UPDATE:
            if self.event_uuid is None or self.changes is None:
                raise ValueError('update proposal requires event_uuid and changes')
            if self.event is not None:
                raise ValueError('update proposal must contain changes, not a complete event')
        else:
            if self.event_uuid is None:
                raise ValueError('delete proposal requires event_uuid')
            if self.event is not None or self.changes is not None:
                raise ValueError('delete proposal contains fields for a different operation')
        return self


class AssistantResponse(BaseModel):
    message: str
    events: list[TimeTreeEvent] = Field(default_factory=list)
    task_suggestions: list[StructuredSuggestion] = Field(default_factory=list)
    calendar_proposal: CalendarWriteProposal | None = None
    used_local_tasks: bool = False
    used_timetree: bool = False


class CalendarQuery(BaseModel):
    calendar_id: str | None = Field(default=None, pattern=r'^[A-Za-z0-9_-]+$')
    query: str | None = Field(default=None, max_length=300)
    start_at: datetime | None = None
    end_at: datetime | None = None
    limit: int = Field(default=50, ge=1, le=200)


class CalendarRange(BaseModel):
    start_date: date
    end_date: date
