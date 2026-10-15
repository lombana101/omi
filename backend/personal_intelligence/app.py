from __future__ import annotations

from contextlib import asynccontextmanager
from datetime import UTC, datetime
from typing import Annotated, AsyncIterator

from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from personal_intelligence.config import ConfigurationError, Settings
from personal_intelligence.llm import (
    IntelligenceUnavailableError,
    InvalidModelOutputError,
    OllamaIntelligenceClient,
)
from personal_intelligence.models import (
    AssistantRequest,
    AssistantResponse,
    CalendarOperationConfirmation,
    CalendarOperationOutcome,
    CalendarOperationPreview,
    CalendarOperationRequest,
    ExtractionRequest,
    ExtractionResponse,
    ProactiveEvaluationRequest,
    ProactiveEvaluationResponse,
    TimeTreeCalendar,
    TimeTreeEvent,
)
from personal_intelligence.operation_store import (
    OperationConflictError,
    OperationNotFoundError,
    OperationStore,
)
from personal_intelligence.security import authenticate_request_owner
from personal_intelligence.service import (
    AuthorizationBasisError,
    CalendarSelectionError,
    IntegrationDisabledError,
    OperationValidationError,
    PersonalIntelligenceService,
    RecurrenceScopeError,
)
from personal_intelligence.timetree import (
    TimeTreeAuthenticationError,
    TimeTreeClient,
    TimeTreeError,
    TimeTreeNotFoundError,
    TimeTreeUnavailableError,
)

OwnerUid = Annotated[str, Depends(authenticate_request_owner)]


def _build_service(settings: Settings, operations: OperationStore) -> PersonalIntelligenceService:
    timetree = None
    if settings.timetree_enabled:
        assert settings.timetree_email is not None and settings.timetree_password is not None
        timetree = TimeTreeClient(
            email=settings.timetree_email.get_secret_value(),
            password=settings.timetree_password.get_secret_value(),
            timeout_seconds=settings.timetree_timeout_seconds,
            requests_per_second=settings.timetree_requests_per_second,
        )
    intelligence = None
    if settings.llm_enabled:
        assert settings.llm_model is not None
        intelligence = OllamaIntelligenceClient(
            base_url=settings.llm_base_url,
            model=settings.llm_model,
            timeout_seconds=settings.llm_timeout_seconds,
        )
    return PersonalIntelligenceService(
        settings=settings,
        operations=operations,
        timetree=timetree,
        intelligence=intelligence,
    )


def create_app(
    *,
    configured_settings: Settings | None = None,
    configured_service: PersonalIntelligenceService | None = None,
) -> FastAPI:
    @asynccontextmanager
    async def lifespan(application: FastAPI) -> AsyncIterator[None]:
        settings = configured_settings or Settings.from_env()
        operations = OperationStore(settings.state_path)
        await operations.initialize()
        service = configured_service or _build_service(settings, operations)
        application.state.settings = settings
        application.state.operations = operations
        application.state.service = service
        try:
            yield
        finally:
            if configured_service is None:
                await service.close()

    application = FastAPI(
        title='Omi Personal Intelligence API',
        version='1.1.0',
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
        lifespan=lifespan,
    )

    @application.exception_handler(ConfigurationError)
    async def configuration_error(_request: Request, _exc: ConfigurationError) -> JSONResponse:
        return JSONResponse(status_code=503, content={'detail': 'Service configuration is invalid'})

    @application.exception_handler(RequestValidationError)
    async def request_validation_error(_request: Request, _exc: RequestValidationError) -> JSONResponse:
        # FastAPI's default validation response includes the rejected input.
        # Requests can contain transcripts, notes, locations, and event titles,
        # so return only a compact error and never reflect private content.
        return JSONResponse(status_code=422, content={'detail': 'Request validation failed'})

    @application.exception_handler(IntegrationDisabledError)
    async def integration_disabled(_request: Request, exc: IntegrationDisabledError) -> JSONResponse:
        return JSONResponse(status_code=503, content={'detail': str(exc)})

    @application.exception_handler(AuthorizationBasisError)
    async def authorization_basis_error(_request: Request, exc: AuthorizationBasisError) -> JSONResponse:
        return JSONResponse(status_code=403, content={'detail': str(exc)})

    @application.exception_handler(OperationConflictError)
    async def operation_conflict(_request: Request, exc: OperationConflictError) -> JSONResponse:
        return JSONResponse(status_code=409, content={'detail': str(exc)})

    @application.exception_handler(OperationNotFoundError)
    async def operation_not_found(_request: Request, exc: OperationNotFoundError) -> JSONResponse:
        return JSONResponse(status_code=404, content={'detail': str(exc)})

    @application.exception_handler(TimeTreeNotFoundError)
    async def timetree_not_found(_request: Request, exc: TimeTreeNotFoundError) -> JSONResponse:
        return JSONResponse(status_code=404, content={'detail': str(exc)})

    async def invalid_operation(_request: Request, exc: Exception) -> JSONResponse:
        return JSONResponse(status_code=422, content={'detail': str(exc)})

    application.add_exception_handler(CalendarSelectionError, invalid_operation)
    application.add_exception_handler(RecurrenceScopeError, invalid_operation)
    application.add_exception_handler(OperationValidationError, invalid_operation)

    @application.exception_handler(TimeTreeAuthenticationError)
    async def timetree_authentication(_request: Request, _exc: TimeTreeAuthenticationError) -> JSONResponse:
        return JSONResponse(status_code=502, content={'detail': 'TimeTree authentication was rejected'})

    @application.exception_handler(TimeTreeUnavailableError)
    async def timetree_unavailable(_request: Request, _exc: TimeTreeUnavailableError) -> JSONResponse:
        return JSONResponse(status_code=503, content={'detail': 'TimeTree is temporarily unavailable'})

    @application.exception_handler(TimeTreeError)
    async def timetree_error(_request: Request, _exc: TimeTreeError) -> JSONResponse:
        return JSONResponse(status_code=502, content={'detail': 'TimeTree rejected the request'})

    @application.exception_handler(IntelligenceUnavailableError)
    async def intelligence_unavailable(_request: Request, _exc: IntelligenceUnavailableError) -> JSONResponse:
        return JSONResponse(status_code=503, content={'detail': 'Local intelligence is temporarily unavailable'})

    @application.exception_handler(InvalidModelOutputError)
    async def invalid_model_output(_request: Request, _exc: InvalidModelOutputError) -> JSONResponse:
        return JSONResponse(status_code=502, content={'detail': 'Local intelligence returned invalid output'})

    @application.get('/health')
    async def health() -> dict[str, str]:
        return {'status': 'ok'}

    @application.get('/v1/integrations', dependencies=[Depends(authenticate_request_owner)])
    async def integrations(request: Request) -> dict[str, bool]:
        settings: Settings = request.app.state.settings
        return {
            'local_intelligence': settings.llm_enabled,
            'timetree': settings.timetree_enabled,
            'generic_calendar_uses_timetree': settings.timetree_prefer_for_generic_calendar,
        }

    @application.get('/v1/timetree/calendars', response_model=list[TimeTreeCalendar])
    async def list_calendars(request: Request, _owner_uid: OwnerUid) -> list[TimeTreeCalendar]:
        service: PersonalIntelligenceService = request.app.state.service
        return await service.list_calendars()

    @application.get('/v1/timetree/events', response_model=list[TimeTreeEvent])
    async def search_events(
        request: Request,
        _owner_uid: OwnerUid,
        calendar_id: str | None = Query(default=None, pattern=r'^[A-Za-z0-9_-]+$'),
        query: str | None = Query(default=None, max_length=300),
        start_at: datetime | None = None,
        end_at: datetime | None = None,
        limit: int = Query(default=50, ge=1, le=200),
    ) -> list[TimeTreeEvent]:
        if start_at is not None and start_at.tzinfo is None:
            raise HTTPException(status_code=422, detail='start_at must include a timezone')
        if end_at is not None and end_at.tzinfo is None:
            raise HTTPException(status_code=422, detail='end_at must include a timezone')
        if start_at is not None and end_at is not None and end_at <= start_at:
            raise HTTPException(status_code=422, detail='end_at must be after start_at')
        service: PersonalIntelligenceService = request.app.state.service
        return await service.search_events(
            calendar_id=calendar_id,
            query=query,
            start_at=start_at,
            end_at=end_at,
            limit=limit,
        )

    @application.post('/v1/intelligence/extract', response_model=ExtractionResponse)
    async def extract_actions(body: ExtractionRequest, request: Request, _owner_uid: OwnerUid) -> ExtractionResponse:
        service: PersonalIntelligenceService = request.app.state.service
        return await service.extract(body)

    @application.post('/v1/intelligence/proactive/evaluate', response_model=ProactiveEvaluationResponse)
    async def evaluate_proactive(
        body: ProactiveEvaluationRequest, request: Request, _owner_uid: OwnerUid
    ) -> ProactiveEvaluationResponse:
        service: PersonalIntelligenceService = request.app.state.service
        return await service.evaluate_proactive(body)

    @application.post('/v1/assistant', response_model=AssistantResponse)
    async def assistant(body: AssistantRequest, request: Request, _owner_uid: OwnerUid) -> AssistantResponse:
        service: PersonalIntelligenceService = request.app.state.service
        return await service.assistant(body)

    @application.post('/v1/timetree/operations/prepare', response_model=CalendarOperationPreview)
    async def prepare_operation(
        body: CalendarOperationRequest, request: Request, owner_uid: OwnerUid
    ) -> CalendarOperationPreview:
        service: PersonalIntelligenceService = request.app.state.service
        return await service.prepare_calendar_operation(owner_uid, body, now=datetime.now(UTC))

    @application.post('/v1/timetree/operations/confirm', response_model=CalendarOperationOutcome)
    async def confirm_operation(
        body: CalendarOperationConfirmation, request: Request, owner_uid: OwnerUid
    ) -> CalendarOperationOutcome:
        service: PersonalIntelligenceService = request.app.state.service
        return await service.confirm_calendar_operation(owner_uid, body.operation_id, now=datetime.now(UTC))

    @application.get('/v1/timetree/operations/{operation_id}', response_model=CalendarOperationOutcome)
    async def operation_status(operation_id: str, request: Request, owner_uid: OwnerUid) -> CalendarOperationOutcome:
        if len(operation_id) != 32 or any(character not in '0123456789abcdef' for character in operation_id):
            raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail='Invalid operation ID')
        operations: OperationStore = request.app.state.operations
        operation = await operations.get(owner_uid, operation_id)
        if operation.outcome is not None:
            return operation.outcome
        return CalendarOperationOutcome(
            operation_id=operation.operation_id,
            status='pending',
            message='Waiting for explicit confirmation',
        )

    @application.delete('/v1/timetree/operations', status_code=status.HTTP_204_NO_CONTENT)
    async def clear_operation_history(request: Request, owner_uid: OwnerUid) -> Response:
        operations: OperationStore = request.app.state.operations
        await operations.clear(owner_uid)
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    return application


app = create_app()
