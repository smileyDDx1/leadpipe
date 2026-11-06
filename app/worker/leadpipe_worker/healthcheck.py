"""Health check for the worker, which has no HTTP port.

The consumer loop touches a heartbeat file on every turn. This exits non-zero when the file is
old or missing. Docker's HEALTHCHECK and the Kubernetes exec probes both run it.

Every probe starts a new Python process, so this module must only import the standard library.
Importing psycopg here cost 0.92 CPU seconds and 3.7 seconds per probe under the pod's CPU limit,
which used about 120m CPU on an idle worker and came close to the probe's 5 second timeout.
"""

from __future__ import annotations

import os
import sys
import time

DEFAULT_HEARTBEAT_FILE = "/tmp/leadpipe-worker-heartbeat"  # noqa: S108 - emptyDir in the pod
HEARTBEAT_MAX_AGE_SECONDS = 30


def is_healthy(path: str, max_age_seconds: int, now: float | None = None) -> bool:
    try:
        modified = os.stat(path).st_mtime
    except OSError:
        return False
    return ((time.time() if now is None else now) - modified) <= max_age_seconds


def main() -> int:
    path = os.environ.get("HEARTBEAT_FILE") or DEFAULT_HEARTBEAT_FILE
    return 0 if is_healthy(path, HEARTBEAT_MAX_AGE_SECONDS) else 1


if __name__ == "__main__":
    sys.exit(main())
