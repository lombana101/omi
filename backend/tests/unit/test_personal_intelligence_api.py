from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import httpx
import pytest
from fastapi.testclient import TestClient
from pydantic import SecretStr

from personal_intelligence import __main__ as personal_intelligence_cli
from personal_intelligence.app import create_app
from personal_intelligence.config import ConfigurationError, Settings
from personal_intelligence.llm import (
    IntelligenceUnavailableError,
    InvalidModelOutputError,
    OllamaIntelligenceClient,
)
from personal_intelligence.operation_store import OperationStore
from personal_intelligence.service import PersonalIntelligenceService

TOKEN = 'owner-api-token-at-least-24-characters'
OWNER = 'owner-uid'
AUTH_HEADERS = {
    'Authorization': f'Bearer {TOKEN}',
    'X-PIS-Owner-Uid': OWNER,
}


def _settings(tmp_path: Path, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        'owner_uid': OWNER,
        'api_token': SecretStr(TOKEN),
        'state_path': tmp_path / 'state' / 'operations.sqlite3',
    }
    values.update(overrides)
    return Settings(**values)


def _service(
    settings: Settings,
    *,
    intelligence: Any = None,
) -> PersonalIntelligenceService:
    return PersonalIntelligenceService(
        settings=settings,
        operations=OperationStore(settings.state_path),
        timetree=None,
        intelligence=intelligence,
    )


def _extraction_body() -> dict[str, Any]:
    return {
        'source_ref': 'capture-1',
        'source_kind': 'manual_text',
        'authorization_basis': 'self_only',
        'text': 'I will prepare the deck tomorrow.',
        'timezone': 'America/Toronto',
        'now': '2026-11-02T09:00:00-05:00',
    }


def _assistant_body() -> dict[str, Any]:
    return {
        'message': 'What is on my list?',
        'timezone': 'America/Toronto',
        'now': '2026-11-02T09:00:00-05:00',
        'open_tasks': [],
    }


def _proactive_body() -> dict[str, Any]:
    return {
        'timezone': 'America/Toronto',
        'now': '2026-11-02T09:00:00-05:00',
        'open_tasks': [],
    }


def _calendar_operation_body() -> dict[str, Any]:
    return {
        'kind': 'create',
        'idempotency_key': 'auth-check-123',
        'calendar_id': 'calendar_1',
        'event': {
            'title': 'Private event',
            'start_at': '2026-11-02T09:00:00-05:00',
            'end_at': '2026-11-02T10:00:00-05:00',
            'start_timezone': 'America/Toronto',
            'end_timezone': 'America/Toronto',
        },
    }


def test_health_is_unauthenticated_but_every_v1_route_requires_both_owner_credentials(
    tmp_path: Path,
) -> None:
    settings = _settings(tmp_path)
    app = create_app(configured_settings=settings, configured_service=_service(settings))

    with TestClient(app) as client:
        assert client.get('/health').json() == {'status': 'ok'}

        for headers in (
            {},
            {'X-PIS-Owner-Uid': OWNER},
            {'Authorization': f'Bearer {TOKEN}'},
            {'Authorization': 'Bearer wrong-token', 'X-PIS-Owner-Uid': OWNER},
            {'Authorization': f'Bearer {TOKEN}', 'X-PIS-Owner-Uid': 'other-owner'},
        ):
            response = client.get('/v1/integrations', headers=headers)
            assert response.status_code == 401
            assert response.headers['www-authenticate'] == 'Bearer'
            assert response.json() == {'detail': 'Owner authentication failed'}
            assert TOKEN not in response.text
            assert OWNER not in response.text

        authenticated = client.get(
            '/v1/integrations',
            headers={'Authorization': f'bEaReR {TOKEN}', 'X-PIS-Owner-Uid': OWNER},
        )

        protected_requests = [
            ('GET', '/v1/integrations', None),
            ('GET', '/v1/timetree/calendars', None),
            ('GET', '/v1/timetree/events', None),
            ('POST', '/v1/intelligence/extract', _extraction_body()),
            ('POST', '/v1/intelligence/proactive/evaluate', _proactive_body()),
            ('POST', '/v1/assistant', _assistant_body()),
            ('POST', '/v1/timetree/operations/prepare', _calendar_operation_body()),
            ('POST', '/v1/timetree/operations/confirm', {'operation_id': '0' * 32}),
            ('GET', f'/v1/timetree/operations/{"0" * 32}', None),
            ('DELETE', '/v1/timetree/operations', None),
        ]
        for method, path, body in protected_requests:
            response = client.request(method, path, json=body)
            assert response.status_code == 401, (method, path, response.text)
            assert response.json() == {'detail': 'Owner authentication failed'}

    assert authenticated.status_code == 200
    assert authenticated.json() == {
        'local_intelligence': False,
        'timetree': False,
        'generic_calendar_uses_timetree': False,
    }


def test_offline_integrations_return_bounded_503_responses_without_external_calls(tmp_path: Path) -> None:
    settings = _settings(tmp_path)
    app = create_app(configured_settings=settings, configured_service=_service(settings))

    with TestClient(app) as client:
        calendars = client.get('/v1/timetree/calendars', headers=AUTH_HEADERS)
        extraction = client.post('/v1/intelligence/extract', headers=AUTH_HEADERS, json=_extraction_body())
        assistant = client.post('/v1/assistant', headers=AUTH_HEADERS, json=_assistant_body())

    assert calendars.status_code == 503
    assert calendars.json() == {'detail': 'TimeTree integration is disabled or not configured'}
    assert extraction.status_code == 503
    assert extraction.json() == {'detail': 'Local intelligence is disabled or not configured'}
    assert assistant.status_code == 503
    assert assistant.json() == {'detail': 'Local intelligence is disabled or not configured'}


def test_api_rejects_naive_clocks_and_invalid_event_ranges_before_service_use(tmp_path: Path) -> None:
    settings = _settings(tmp_path)
    app = create_app(configured_settings=settings, configured_service=_service(settings))
    extraction_body = _extraction_body()
    extraction_body['now'] = '2026-11-02T09:00:00'
    assistant_body = _assistant_body()
    assistant_body['now'] = '2026-11-02T09:00:00'
    assistant_with_naive_task = _assistant_body()
    assistant_with_naive_task['open_tasks'] = [
        {
            'task_id': 'task-1',
            'title': 'Private task',
            'due_at': '2026-11-02T10:00:00',
        }
    ]
    private_text = extraction_body['text']

    with TestClient(app) as client:
        extraction = client.post('/v1/intelligence/extract', headers=AUTH_HEADERS, json=extraction_body)
        assistant = client.post('/v1/assistant', headers=AUTH_HEADERS, json=assistant_body)
        naive_task = client.post('/v1/assistant', headers=AUTH_HEADERS, json=assistant_with_naive_task)
        calendar = client.get(
            '/v1/timetree/events',
            headers=AUTH_HEADERS,
            params={
                'start_at': '2026-11-02T10:00:00Z',
                'end_at': '2026-11-02T09:00:00Z',
            },
        )

    assert extraction.status_code == 422
    assert extraction.json() == {'detail': 'Request validation failed'}
    assert private_text not in extraction.text
    assert assistant.status_code == 422
    assert assistant.json() == {'detail': 'Request validation failed'}
    assert naive_task.status_code == 422
    assert naive_task.json() == {'detail': 'Request validation failed'}
    assert calendar.status_code == 422
    assert calendar.json() == {'detail': 'end_at must be after start_at'}


class _UnavailableIntelligence:
    async def extract(self, _request: Any) -> Any:
        raise IntelligenceUnavailableError('provider URL contains token=private-secret')

    async def plan_assistant(self, **_kwargs: Any) -> Any:
        raise IntelligenceUnavailableError('provider URL contains token=private-secret')


def test_api_redacts_provider_failure_details(tmp_path: Path) -> None:
    settings = _settings(tmp_path, llm_enabled=True, llm_model='local-model')
    app = create_app(
        configured_settings=settings,
        configured_service=_service(settings, intelligence=_UnavailableIntelligence()),
    )

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.post('/v1/intelligence/extract', headers=AUTH_HEADERS, json=_extraction_body())

    assert response.status_code == 503
    assert response.json() == {'detail': 'Local intelligence is temporarily unavailable'}
    assert 'private-secret' not in response.text


@pytest.mark.parametrize(
    'environment',
    [
        {'PIS_API_TOKEN': TOKEN},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': 'short'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'PIS_LISTEN_HOST': '0.0.0.0'},
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'https://remote-model.example.test',
        },
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'TIMETREE_INTEGRATION_ENABLED': 'true',
        },
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'TIMETREE_PREFER_FOR_GENERIC_CALENDAR': 'true',
        },
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'PIS_LISTEN_PORT': 'not-a-port'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'TIMETREE_TIMEOUT_SECONDS': 'fast'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'TIMETREE_TIMEOUT_SECONDS': 'nan'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'TIMETREE_REQUESTS_PER_SECOND': 'nan'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'PIS_LLM_TIMEOUT_SECONDS': '0'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': TOKEN, 'PIS_LLM_TIMEOUT_SECONDS': 'inf'},
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'ftp://127.0.0.1:11434',
        },
        {'PIS_OWNER_UID': 'owner/uid', 'PIS_API_TOKEN': TOKEN},
        {'PIS_OWNER_UID': 'a' * 201, 'PIS_API_TOKEN': TOKEN},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': 'a' * 23 + '/'},
        {'PIS_OWNER_UID': OWNER, 'PIS_API_TOKEN': 'a' * 257},
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'http://user:password@127.0.0.1:11434',
        },
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'http://127.0.0.1:11434?private=true',
        },
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'http://127.0.0.1:11434#private',
        },
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'http://127.0.0.1:99999',
        },
        {
            'PIS_OWNER_UID': OWNER,
            'PIS_API_TOKEN': TOKEN,
            'PIS_LLM_BASE_URL': 'http://[::1',
        },
    ],
)
def test_configuration_fails_closed_for_missing_secrets_or_non_loopback_services(
    environment: dict[str, str],
) -> None:
    with pytest.raises(ConfigurationError):
        Settings.from_env(environment)


def test_configuration_accepts_documented_owner_and_token_character_sets(tmp_path: Path) -> None:
    settings = Settings.from_env(
        {
            'PIS_OWNER_UID': 'Owner._:@-123',
            'PIS_API_TOKEN': 'Token._~-0123456789abcdefghij',
            'PIS_STATE_PATH': str(tmp_path / 'operations.sqlite3'),
        }
    )

    assert settings.owner_uid == 'Owner._:@-123'
    assert settings.api_token.get_secret_value() == 'Token._~-0123456789abcdefghij'


def test_configuration_repr_redacts_all_credentials(tmp_path: Path) -> None:
    settings = _settings(
        tmp_path,
        timetree_enabled=True,
        timetree_email=SecretStr('private@example.test'),
        timetree_password=SecretStr('time-tree-private-password'),
    )

    rendered = repr(settings)

    assert TOKEN not in rendered
    assert 'private@example.test' not in rendered
    assert 'time-tree-private-password' not in rendered
    assert '**********' in rendered


def test_command_line_server_disables_access_logging_for_private_query_terms(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    settings = _settings(tmp_path)
    captured: dict[str, Any] = {}

    monkeypatch.setattr(
        personal_intelligence_cli.Settings,
        'from_env',
        classmethod(lambda _cls: settings),
    )

    def fake_run(app: Any, **kwargs: Any) -> None:
        captured['app'] = app
        captured.update(kwargs)

    monkeypatch.setattr(personal_intelligence_cli.uvicorn, 'run', fake_run)

    personal_intelligence_cli.main()

    assert captured['app'] is personal_intelligence_cli.app
    assert captured['host'] == '127.0.0.1'
    assert captured['port'] == 8792
    assert captured['access_log'] is False


@pytest.mark.asyncio
async def test_ollama_request_is_loopback_structured_deterministic_and_non_streaming() -> None:
    captured: dict[str, Any] = {}

    async def handler(request: httpx.Request) -> httpx.Response:
        captured['url'] = str(request.url)
        captured['body'] = json.loads(request.content)
        return httpx.Response(
            200,
            json={
                'message': {
                    'content': json.dumps(
                        {
                            'suggestions': [
                                {
                                    'suggested_type': 'task',
                                    'title': 'Prepare the deck',
                                    'proposed_time_text': 'tomorrow',
                                    'source_ref': 'capture-1',
                                    'supporting_excerpt': 'I will prepare the deck tomorrow.',
                                    'uncertainty': 0.1,
                                }
                            ]
                        }
                    )
                }
            },
        )

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        intelligence = OllamaIntelligenceClient(
            base_url='http://127.0.0.1:11434',
            model='local-model',
            timeout_seconds=2,
            client=http_client,
        )
        suggestions = await intelligence.extract(
            # Validation is deliberately exercised before provider invocation.
            __import__('personal_intelligence.models', fromlist=['ExtractionRequest']).ExtractionRequest.model_validate(
                _extraction_body()
            )
        )

    assert suggestions[0].title == 'Prepare the deck'
    assert captured['url'] == 'http://127.0.0.1:11434/api/chat'
    assert captured['body']['model'] == 'local-model'
    assert captured['body']['stream'] is False
    assert captured['body']['options'] == {'temperature': 0}
    assert captured['body']['format']['additionalProperties'] is False


@pytest.mark.parametrize('failure', ['transport', 'invalid-output'])
@pytest.mark.asyncio
async def test_ollama_provider_faults_are_typed_and_do_not_leak_response_content(failure: str) -> None:
    async def handler(request: httpx.Request) -> httpx.Response:
        if failure == 'transport':
            raise httpx.ConnectError('private endpoint detail', request=request)
        return httpx.Response(200, json={'message': {'content': 'private invalid output'}})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http_client:
        intelligence = OllamaIntelligenceClient(
            base_url='http://127.0.0.1:11434',
            model='local-model',
            timeout_seconds=2,
            client=http_client,
        )
        expected = IntelligenceUnavailableError if failure == 'transport' else InvalidModelOutputError
        with pytest.raises(expected) as raised:
            await intelligence.extract(
                __import__(
                    'personal_intelligence.models', fromlist=['ExtractionRequest']
                ).ExtractionRequest.model_validate(_extraction_body())
            )

    assert 'private' not in str(raised.value)
