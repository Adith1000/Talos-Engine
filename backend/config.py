"""
config.py

Central configuration: environment variables, defaults, and constants.
All runtime settings are loaded here once and imported by other modules.
"""

import os
from dotenv import load_dotenv

load_dotenv()


# ─── Git / Repository ────────────────────────────────────────────────────────

REPO_URL: str = os.getenv("REPO_URL", "")
GIT_TOKEN: str = os.getenv("GIT_TOKEN", "")
BRANCH: str = os.getenv("BRANCH", "main")


# ─── Docker ──────────────────────────────────────────────────────────────────

DOCKER_IMAGE: str = os.getenv("DOCKER_IMAGE", "alpine/git:latest")
CONTAINER_CLONE_DIR: str = "/repo"
CONTAINER_TIMEOUT: int = int(os.getenv("CONTAINER_TIMEOUT", "300"))


# ─── FastAPI Server ───────────────────────────────────────────────────────────

API_HOST: str = os.getenv("API_HOST", "0.0.0.0")
API_PORT: int = int(os.getenv("API_PORT", "8000"))

_raw_origins = os.getenv("CORS_ORIGINS", "http://localhost:5173,http://localhost:3000")
CORS_ORIGINS: list[str] = [o.strip() for o in _raw_origins.split(",") if o.strip()]


# ─── Pipeline capability registry ─────────────────────────────────────────────
# These are the single source of truth shared (conceptually) with the frontend.
# Keep the keys stable; the YAML compiler dispatches on them.

SUPPORTED_FRAMEWORKS: set[str] = {"playwright", "cypress", "jest", "vitest", "none"}
SUPPORTED_DEPLOY_TARGETS: set[str] = {"vercel", "github-pages", "aws-s3", "none"}

# Which secret names each deploy target expects. Used for validation + UI hints.
TARGET_SECRETS: dict[str, list[str]] = {
    "vercel": ["VERCEL_TOKEN", "VERCEL_ORG_ID", "VERCEL_PROJECT_ID"],
    "github-pages": [],  # uses the built-in GITHUB_TOKEN
    "aws-s3": ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_S3_BUCKET"],
    "none": [],
}


# ─── Validation helper ────────────────────────────────────────────────────────

def validate_required() -> None:
    """Raise SystemExit if mandatory env vars are missing (used by CLI entry-point)."""
    missing = [name for name, val in [("GIT_TOKEN", GIT_TOKEN), ("REPO_URL", REPO_URL)] if not val]
    if missing:
        raise SystemExit(f"Error: missing required environment variables: {', '.join(missing)}")