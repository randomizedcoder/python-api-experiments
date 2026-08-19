"""Table-driven tests for `dfapi.df.parse_df` plus a couple of view-level tests.

Cases are organized explicitly into positive / negative / boundary / corner
groups so coverage of each category is visible at a glance.
"""

import pytest

from dfapi.df import parse_df

# Canonical GNU df header line, reused across cases.
HEADER = "Filesystem     1K-blocks    Used Available Use% Mounted on"


# --------------------------------------------------------------------------- #
# (name, df_output, expected_rows)
# --------------------------------------------------------------------------- #
CASES = [
    # ----- POSITIVE ----------------------------------------------------------
    (
        "positive-single-fs",
        f"{HEADER}\n/dev/sda1  123456789 1234567 98765432   2% /",
        [
            {
                "filesystem": "/dev/sda1",
                "blocks": 123456789,
                "used": 1234567,
                "available": 98765432,
                "use_percent": 2,
                "mounted_on": "/",
            }
        ],
    ),
    (
        "positive-multiple-fs",
        (
            f"{HEADER}\n"
            "/dev/sda1  100 40 60 40% /\n"
            "tmpfs      200 10 190  5% /run\n"
            "/dev/sdb1  300 30 270 10% /data"
        ),
        [
            {"filesystem": "/dev/sda1", "blocks": 100, "used": 40, "available": 60, "use_percent": 40, "mounted_on": "/"},
            {"filesystem": "tmpfs", "blocks": 200, "used": 10, "available": 190, "use_percent": 5, "mounted_on": "/run"},
            {"filesystem": "/dev/sdb1", "blocks": 300, "used": 30, "available": 270, "use_percent": 10, "mounted_on": "/data"},
        ],
    ),
    # ----- NEGATIVE ----------------------------------------------------------
    ("negative-empty-string", "", []),
    ("negative-whitespace-only", "   \n\t\n  ", []),
    ("negative-header-only", HEADER, []),
    ("negative-garbage-text", "this is not df output at all", []),
    (
        "negative-non-numeric-columns",
        f"{HEADER}\n/dev/sda1  lots some none huge% /",
        [],
    ),
    (
        "negative-too-few-columns",
        f"{HEADER}\n/dev/sda1 100 40",
        [],
    ),
    # ----- BOUNDARY ----------------------------------------------------------
    (
        "boundary-zero-percent",
        f"{HEADER}\n/dev/sda1 100 0 100 0% /",
        [{"filesystem": "/dev/sda1", "blocks": 100, "used": 0, "available": 100, "use_percent": 0, "mounted_on": "/"}],
    ),
    (
        "boundary-full-100-percent",
        f"{HEADER}\n/dev/sda1 100 100 0 100% /",
        [{"filesystem": "/dev/sda1", "blocks": 100, "used": 100, "available": 0, "use_percent": 100, "mounted_on": "/"}],
    ),
    (
        "boundary-huge-values",
        f"{HEADER}\n/dev/sda1 99999999999999 88888888888888 11111111111111 89% /big",
        [
            {
                "filesystem": "/dev/sda1",
                "blocks": 99999999999999,
                "used": 88888888888888,
                "available": 11111111111111,
                "use_percent": 89,
                "mounted_on": "/big",
            }
        ],
    ),
    # ----- CORNER ------------------------------------------------------------
    (
        "corner-wrapped-long-device-name",
        # GNU df wraps a long device name onto its own line; numbers follow.
        f"{HEADER}\n/dev/mapper/very-long-volume-group-name-lv\n           100 40 60 40% /var",
        [
            {
                "filesystem": "/dev/mapper/very-long-volume-group-name-lv",
                "blocks": 100,
                "used": 40,
                "available": 60,
                "use_percent": 40,
                "mounted_on": "/var",
            }
        ],
    ),
    (
        "corner-mount-point-with-spaces",
        f"{HEADER}\n/dev/sdc1 100 40 60 40% /mnt/my drive",
        [
            {
                "filesystem": "/dev/sdc1",
                "blocks": 100,
                "used": 40,
                "available": 60,
                "use_percent": 40,
                "mounted_on": "/mnt/my drive",
            }
        ],
    ),
    (
        "corner-mixed-whitespace-and-tabs",
        f"{HEADER}\n/dev/sda1\t100\t 40\t60   40%\t/",
        [{"filesystem": "/dev/sda1", "blocks": 100, "used": 40, "available": 60, "use_percent": 40, "mounted_on": "/"}],
    ),
    (
        "corner-trailing-blank-lines",
        f"{HEADER}\n/dev/sda1 100 40 60 40% /\n\n\n",
        [{"filesystem": "/dev/sda1", "blocks": 100, "used": 40, "available": 60, "use_percent": 40, "mounted_on": "/"}],
    ),
    (
        "corner-pseudo-filesystems",
        (
            f"{HEADER}\n"
            "overlay 100 40 60 40% /\n"
            "tmpfs   200 0 200 0% /dev/shm"
        ),
        [
            {"filesystem": "overlay", "blocks": 100, "used": 40, "available": 60, "use_percent": 40, "mounted_on": "/"},
            {"filesystem": "tmpfs", "blocks": 200, "used": 0, "available": 200, "use_percent": 0, "mounted_on": "/dev/shm"},
        ],
    ),
]


@pytest.mark.parametrize("name, output, expected", CASES, ids=[c[0] for c in CASES])
def test_parse_df(name, output, expected):
    assert parse_df(output) == expected


# --------------------------------------------------------------------------- #
# View-level tests (require Django settings; provided by pytest-django).
# --------------------------------------------------------------------------- #
FAKE_DF = "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/sda1 100 40 60 40% /\n"


class _FakeCompleted:
    stdout = FAKE_DF
    returncode = 0


def test_view_returns_json_without_cache_control(client, monkeypatch):
    monkeypatch.setattr("dfapi.views.subprocess.run", lambda *a, **k: _FakeCompleted())

    response = client.get("/api/df/")

    assert response.status_code == 200
    assert response["Content-Type"].startswith("application/json")
    # The app must NOT set caching headers — that is nginx's job.
    assert not response.has_header("Cache-Control")
    payload = response.json()
    assert payload["filesystems"][0]["mounted_on"] == "/"


def test_view_honors_sleep_ms(client, monkeypatch, settings):
    settings.SLEEP_MS = 7
    recorded = {}
    monkeypatch.setattr("dfapi.views.subprocess.run", lambda *a, **k: _FakeCompleted())
    monkeypatch.setattr("dfapi.views.time.sleep", lambda seconds: recorded.setdefault("seconds", seconds))

    client.get("/api/df/")

    assert recorded["seconds"] == pytest.approx(7 / 1000.0)
