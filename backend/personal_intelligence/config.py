from __future__ import annotations

import os
import re
from math import isfinite
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlparse

from pydantic import SecretStr


class ConfigurationError(RuntimeError):
    pass


OWNER_UID_PATTERN = re.compile(r'^[A-Za-z0-9._:@-]{1,200}$')
API_TOKEN_PATTERN = re.compile(r'^[A-Za-z0-9._~-]{24,256}$')


def _enabled(value: str | None, *, default: bool = False) -> bool:
    if value is None:
        return default
    normalized = value.strip().lower()
    if normalized in {'1', 'true', 'yes', 'on'}:
        return True
    if normalized in {'0', 'false', 'no', 'off'}:
        return False
    raise ConfigurationError('Boolean environment value must be true/on or false/off')


def _required(env: dict[str, str], name: str) -> str:
    value = env.get(name, '').strip()
    if not value:
        raise ConfigurationError(f'{name} is required')
    return value


def _integer(env: dict[str, str], name: str, default: int) -> int:
    try:
        return int(env.get(name, str(default)))
    except ValueError as exc:
        raise ConfigurationError(f'{name} must be an integer') from exc


def _number(env: dict[str, str], name: str, default: float) -> float:
    try:
        return float(env.get(name, str(default)))
    except ValueError as exc:
        raise ConfigurationError(f'{name} must be a number') from exc


def _owner_uid(env: dict[str, str]) -> str:
    primary = env.get('PIS_OWNER_UID', '').strip()
    integration = env.get('TIMETREE_OWNER_UID', '').strip()
    if primary and integration and primary != integration:
        raise ConfigurationError('PIS_OWNER_UID and TIMETREE_OWNER_UID must identify the same owner')
    value = primary or integration
    if not value:
        raise ConfigurationError('PIS_OWNER_UID (or TIMETREE_OWNER_UID) is required')
    return value


@dataclass(frozen=True, repr=False)
class Settings:
    owner_uid: str
    api_token: SecretStr
    state_path: Path
    listen_host: str = '127.0.0.1'
    listen_port: int = 8792
    timetree_enabled: bool = False
    timetree_email: SecretStr | None = None
    timetree_password: SecretStr | None = None
    timetree_default_calendar_id: str | None = None
    timetree_prefer_for_generic_calendar: bool = False
    timetree_timeout_seconds: float = 20.0
    timetree_requests_per_second: float = 10.0
    llm_enabled: bool = False
    llm_base_url: str = 'http://127.0.0.1:11434'
    llm_model: str | None = None
    llm_timeout_seconds: float = 45.0
    confirmation_ttl_seconds: int = 900

    def __post_init__(self) -> None:
        if not OWNER_UID_PATTERN.fullmatch(self.owner_uid):
            raise ConfigurationError('PIS_OWNER_UID must be 1-200 URL-safe identifier characters')
        if not API_TOKEN_PATTERN.fullmatch(self.api_token.get_secret_value()):
            raise ConfigurationError('PIS_API_TOKEN must be a URL-safe token of 24-256 characters')
        if self.listen_host not in {'127.0.0.1', '::1', 'localhost'}:
            raise ConfigurationError('PIS_LISTEN_HOST must remain loopback-only')
        if not (1 <= self.listen_port <= 65535):
            raise ConfigurationError('PIS_LISTEN_PORT is invalid')
        if not isfinite(self.timetree_requests_per_second) or not 0 < self.timetree_requests_per_second <= 10:
            raise ConfigurationError('TIMETREE_REQUESTS_PER_SECOND must be in (0, 10]')
        if not isfinite(self.timetree_timeout_seconds) or self.timetree_timeout_seconds <= 0:
            raise ConfigurationError('TIMETREE_TIMEOUT_SECONDS must be positive')
        if self.timetree_enabled and (self.timetree_email is None or self.timetree_password is None):
            raise ConfigurationError('TimeTree is enabled but its server-side credentials are missing')
        if self.timetree_prefer_for_generic_calendar and not self.timetree_enabled:
            raise ConfigurationError('TIMETREE_PREFER_FOR_GENERIC_CALENDAR requires TimeTree to be enabled')
        if self.llm_enabled and not self.llm_model:
            raise ConfigurationError('PIS_LLM_MODEL is required when PIS_LLM_ENABLED=true')
        if not isfinite(self.llm_timeout_seconds) or self.llm_timeout_seconds <= 0:
            raise ConfigurationError('PIS_LLM_TIMEOUT_SECONDS must be positive')
        try:
            llm_url = urlparse(self.llm_base_url)
        except ValueError as exc:
            raise ConfigurationError('PIS_LLM_BASE_URL is invalid') from exc
        if llm_url.scheme not in {'http', 'https'}:
            raise ConfigurationError('PIS_LLM_BASE_URL must use HTTP or HTTPS')
        if llm_url.username is not None or llm_url.password is not None:
            raise ConfigurationError('PIS_LLM_BASE_URL must not contain user information')
        if llm_url.query or llm_url.fragment:
            raise ConfigurationError('PIS_LLM_BASE_URL must not contain a query or fragment')
        try:
            llm_port = llm_url.port
        except ValueError as exc:
            raise ConfigurationError('PIS_LLM_BASE_URL contains an invalid port') from exc
        if llm_port == 0:
            raise ConfigurationError('PIS_LLM_BASE_URL contains an invalid port')
        llm_host = llm_url.hostname
        if llm_host not in {'127.0.0.1', 'localhost', '::1'}:
            raise ConfigurationError('PIS_LLM_BASE_URL must be loopback-only; private text cannot leave Ubuntu')
        if self.confirmation_ttl_seconds < 60 or self.confirmation_ttl_seconds > 3600:
            raise ConfigurationError('PIS_CONFIRMATION_TTL_SECONDS must be between 60 and 3600')

    def __repr__(self) -> str:
        return (
            'Settings('
            f'owner_uid={self.owner_uid!r}, api_token=SecretStr(\'**********\'), '
            f'state_path={str(self.state_path)!r}, listen_host={self.listen_host!r}, '
            f'listen_port={self.listen_port!r}, timetree_enabled={self.timetree_enabled!r}, '
            f'llm_enabled={self.llm_enabled!r})'
        )

    @classmethod
    def from_env(cls, environ: dict[str, str] | None = None) -> 'Settings':
        env = dict(os.environ if environ is None else environ)
        timetree_enabled = _enabled(env.get('TIMETREE_INTEGRATION_ENABLED'))
        llm_enabled = _enabled(env.get('PIS_LLM_ENABLED'))
        email = env.get('TIMETREE_EMAIL', '').strip()
        password = env.get('TIMETREE_PASSWORD', '')
        default_calendar = env.get('TIMETREE_DEFAULT_CALENDAR_ID', '').strip() or None
        return cls(
            owner_uid=_owner_uid(env),
            api_token=SecretStr(_required(env, 'PIS_API_TOKEN')),
            state_path=Path(env.get('PIS_STATE_PATH', '/var/lib/omi-personal-intelligence/operations.sqlite3')),
            listen_host=env.get('PIS_LISTEN_HOST', '127.0.0.1').strip(),
            listen_port=_integer(env, 'PIS_LISTEN_PORT', 8792),
            timetree_enabled=timetree_enabled,
            timetree_email=SecretStr(email) if email else None,
            timetree_password=SecretStr(password) if password else None,
            timetree_default_calendar_id=default_calendar,
            timetree_prefer_for_generic_calendar=_enabled(
                env.get('TIMETREE_PREFER_FOR_GENERIC_CALENDAR'), default=False
            ),
            timetree_timeout_seconds=_number(env, 'TIMETREE_TIMEOUT_SECONDS', 20),
            timetree_requests_per_second=_number(env, 'TIMETREE_REQUESTS_PER_SECOND', 10),
            llm_enabled=llm_enabled,
            llm_base_url=env.get('PIS_LLM_BASE_URL', 'http://127.0.0.1:11434').rstrip('/'),
            llm_model=env.get('PIS_LLM_MODEL', '').strip() or None,
            llm_timeout_seconds=_number(env, 'PIS_LLM_TIMEOUT_SECONDS', 45),
            confirmation_ttl_seconds=_integer(env, 'PIS_CONFIRMATION_TTL_SECONDS', 900),
        )
