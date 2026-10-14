from __future__ import annotations

import hmac
from collections.abc import Callable
from typing import Annotated, Any

from fastapi import Header, HTTPException, Request, status

from personal_intelligence.config import Settings

SENSITIVE_KEYS = frozenset(
    {
        'authorization',
        'cookie',
        'email',
        'password',
        'session',
        'session_cookie',
        'csrf',
        'csrf_token',
        'title',
        'note',
        'location',
        'text',
        'excerpt',
    }
)


def redact_for_log(value: Any) -> Any:
    """Return safe structural metadata without user content or credentials."""
    if isinstance(value, dict):
        return {
            str(key): '<redacted>' if str(key).lower() in SENSITIVE_KEYS else redact_for_log(item)
            for key, item in value.items()
        }
    if isinstance(value, (list, tuple)):
        return [redact_for_log(item) for item in value]
    return value


OwnerUid = Annotated[str, Header(alias='X-PIS-Owner-Uid')]
Authorization = Annotated[str | None, Header(alias='Authorization')]


def owner_dependency(settings: Settings) -> Callable[..., str]:
    expected_token = settings.api_token.get_secret_value().encode()
    expected_owner = settings.owner_uid.encode()

    async def authenticate_owner(owner_uid: OwnerUid, authorization: Authorization = None) -> str:
        scheme, separator, token = (authorization or '').partition(' ')
        valid_scheme = separator == ' ' and scheme.lower() == 'bearer'
        valid_token = valid_scheme and hmac.compare_digest(token.encode(), expected_token)
        valid_owner = hmac.compare_digest(owner_uid.encode(), expected_owner)
        if not (valid_token and valid_owner):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail='Owner authentication failed',
                headers={'WWW-Authenticate': 'Bearer'},
            )
        return settings.owner_uid

    return authenticate_owner


async def authenticate_request_owner(
    request: Request,
    owner_uid: Annotated[str | None, Header(alias='X-PIS-Owner-Uid')] = None,
    authorization: Authorization = None,
) -> str:
    settings: Settings = request.app.state.settings
    expected_token = settings.api_token.get_secret_value().encode()
    expected_owner = settings.owner_uid.encode()
    scheme, separator, token = (authorization or '').partition(' ')
    valid_scheme = separator == ' ' and scheme.lower() == 'bearer'
    valid_token = valid_scheme and hmac.compare_digest(token.encode(), expected_token)
    valid_owner = owner_uid is not None and hmac.compare_digest(owner_uid.encode(), expected_owner)
    if not (valid_token and valid_owner):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail='Owner authentication failed',
            headers={'WWW-Authenticate': 'Bearer'},
        )
    return settings.owner_uid
