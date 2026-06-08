"""
secrets_manager.py

Sets repository secrets on GitHub via the REST API so the generated workflow's
"${{ secrets.X }}" references actually resolve.

GitHub requires each secret value to be encrypted client-side with the repo's
public key using a libsodium *sealed box* before upload. We use PyNaCl for that.

Docs: https://docs.github.com/en/rest/actions/secrets
"""

from __future__ import annotations

import base64
from urllib.parse import urlparse

import requests
from nacl import encoding, public

_API = "https://api.github.com"


def _owner_repo(repo_url: str) -> tuple[str, str]:
    path = urlparse(repo_url).path.strip("/")
    if path.endswith(".git"):
        path = path[:-4]
    parts = path.split("/")
    if len(parts) < 2:
        raise ValueError(f"Cannot parse owner/repo from {repo_url!r}")
    return parts[0], parts[1]


def _headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def _encrypt(public_key_b64: str, secret_value: str) -> str:
    """Seal `secret_value` against the repo's base64 public key."""
    pk = public.PublicKey(public_key_b64.encode("utf-8"), encoding.Base64Encoder())
    sealed = public.SealedBox(pk).encrypt(secret_value.encode("utf-8"))
    return base64.b64encode(sealed).decode("utf-8")


def set_repo_secrets(repo_url: str, token: str, secrets: dict[str, str]) -> list[str]:
    """
    Upload each name->value pair as an Actions repository secret.
    Returns the list of secret names that were written.
    Raises requests.HTTPError on API failure.
    """
    if not secrets:
        return []

    owner, repo = _owner_repo(repo_url)
    h = _headers(token)

    key_resp = requests.get(
        f"{_API}/repos/{owner}/{repo}/actions/secrets/public-key", headers=h, timeout=30
    )
    key_resp.raise_for_status()
    key_data = key_resp.json()
    public_key, key_id = key_data["key"], key_data["key_id"]

    written: list[str] = []
    for name, value in secrets.items():
        if value is None or value == "":
            continue
        payload = {"encrypted_value": _encrypt(public_key, value), "key_id": key_id}
        put = requests.put(
            f"{_API}/repos/{owner}/{repo}/actions/secrets/{name}",
            headers=h, json=payload, timeout=30,
        )
        put.raise_for_status()
        written.append(name)

    return written