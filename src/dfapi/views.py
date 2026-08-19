"""REST view: sleep, shell out to `df`, return the parsed output as JSON.

Deliberately sets **no** ``Cache-Control`` header — caching is the job of the
nginx layer in front of this app (see ``docs/design.md``).
"""

import subprocess
import time

from django.conf import settings
from django.http import JsonResponse

from .df import parse_df


def df_view(request):
    # Configurable artificial latency (README: default 1ms) so caching has a
    # visible effect under load.
    time.sleep(settings.SLEEP_MS / 1000.0)

    result = subprocess.run(["df"], capture_output=True, text=True)
    filesystems = parse_df(result.stdout)

    return JsonResponse(
        {"filesystems": filesystems},
        json_dumps_params={"indent": 2},
    )
