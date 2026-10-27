"""Format bounded failure details without credentials or authorization data."""
from __future__ import annotations

import re
from collections.abc import Iterable


_AUTHORIZATION_RE = re.compile(
    r"(?i)(\bauthorization\s*[:=]\s*)(?:[A-Za-z]+\s+)?[^\s,;]+"
)
_BEARER_RE = re.compile(r"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]+")
_QUERY_CREDENTIAL_RE = re.compile(
    r"(?i)(\b(?:access_token|api_key|hf_token|token)\s*=\s*)[^&\s]+"
)


def redact_diagnostic(
    message: object,
    secrets: Iterable[str | None] = (),
    *,
    limit: int = 600,
) -> str:
    """Return one bounded diagnostic line with credentials removed."""
    text = str(message).replace("\r", " ").replace("\n", " ")
    text = _AUTHORIZATION_RE.sub(r"\1<redacted>", text)
    text = _BEARER_RE.sub(r"\1<redacted>", text)
    text = _QUERY_CREDENTIAL_RE.sub(r"\1<redacted>", text)
    for secret in sorted((value for value in secrets if value), key=len, reverse=True):
        text = text.replace(secret, "<redacted>")
    if limit < 1:
        raise ValueError("diagnostic limit must be positive")
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return text
