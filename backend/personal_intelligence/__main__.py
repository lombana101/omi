from __future__ import annotations

import uvicorn

from personal_intelligence.app import app
from personal_intelligence.config import Settings


def main() -> None:
    settings = Settings.from_env()
    # Access logs include the raw request target. Calendar search terms are
    # private user content and must never reach journald.
    uvicorn.run(app, host=settings.listen_host, port=settings.listen_port, log_level='info', access_log=False)


if __name__ == '__main__':
    main()
