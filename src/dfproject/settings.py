"""Minimal Django settings for the `df`-API demo.

No database, no auth, no templates — a single JSON view. Tunables come from the
environment (injected from the Nix constants at container build time), with the
README defaults baked in here.
"""

import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent

# Dev/demo only — this app exposes no secrets and stores no state.
SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "insecure-demo-key-not-for-production")
DEBUG = os.environ.get("DJANGO_DEBUG", "0") == "1"
ALLOWED_HOSTS = ["*"]

# Milliseconds to sleep before responding (README default: 1ms).
SLEEP_MS = int(os.environ.get("SLEEP_MS", "1"))

INSTALLED_APPS = [
    "dfapi",
]

MIDDLEWARE = []

ROOT_URLCONF = "dfproject.urls"

TEMPLATES = []

WSGI_APPLICATION = "dfproject.wsgi.application"

# No database is used by this app.
DATABASES = {}

USE_TZ = True

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
