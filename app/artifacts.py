from __future__ import annotations

from dataclasses import dataclass
import json
import logging
import mimetypes
import os
from pathlib import Path
import re
import secrets
import tempfile
import threading
import time
from typing import Callable, Iterable


_STANDALONE_MEDIA = re.compile(r"^\s*[`\"'*_]{0,3}MEDIA:\s*(.+?)[`\"'*_]{0,3}\s*$", re.IGNORECASE)
_INLINE_MEDIA = re.compile(r"MEDIA:\s*((?:~?/|/)[^\s`\"']+)", re.IGNORECASE)
_IMAGE_MIME_PREFIX = "image/"
_LOGGER = logging.getLogger(__name__)


@dataclass(frozen=True)
class _Artifact:
    path: Path
    expires_at: float
    mime_type: str


_SENSITIVE_NAMES = frozenset({
    ".env", ".env.local", ".env.production", "credentials.json", "secret.json",
    "id_rsa", "id_ed25519", "authorized_keys", "known_hosts",
})
_SENSITIVE_PARTS = frozenset({".git", ".ssh", ".hermes"})


class ArtifactRegistry:
    """Short-lived opaque handles for explicitly selected, allowed files."""

    def __init__(
        self,
        ttl_seconds: float = 900,
        clock: Callable[[], float] = time.time,
        allowed_roots: Iterable[str | Path] | None = None,
        max_bytes: int = 50 * 1024 * 1024,
    ) -> None:
        self.ttl_seconds = float(ttl_seconds)
        self.clock = clock
        configured_roots = allowed_roots if allowed_roots is not None else (tempfile.gettempdir(),)
        self.allowed_roots = tuple(Path(root).expanduser().resolve() for root in configured_roots)
        self.max_bytes = int(max_bytes)
        self._items: dict[str, _Artifact] = {}
        self._lock = threading.Lock()

    def _prune(self) -> None:
        now = self.clock()
        for token, item in list(self._items.items()):
            if item.expires_at <= now:
                self._items.pop(token, None)

    def _is_allowed(self, path: Path) -> bool:
        if not self.allowed_roots:
            return True
        if path.name.lower() in _SENSITIVE_NAMES or any(part.lower() in _SENSITIVE_PARTS for part in path.parts):
            return False
        return any(path == root or root in path.parents for root in self.allowed_roots)

    def register(self, raw_path: str | Path) -> dict[str, object]:
        path = Path(raw_path).expanduser().resolve(strict=True)
        if not self._is_allowed(path):
            raise OSError("file is outside the artifact allowlist")
        if not path.is_file() or not os.access(path, os.R_OK):
            raise OSError("file is not readable")
        size = path.stat().st_size
        if size > self.max_bytes:
            raise OSError("file exceeds artifact size limit")
        token = secrets.token_urlsafe(32)
        mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        with self._lock:
            self._prune()
            self._items[token] = _Artifact(
                path=path, expires_at=self.clock() + self.ttl_seconds, mime_type=mime_type
            )
        return {
            "token": token,
            "name": path.name,
            "mime_type": mime_type,
            "size": size,
            "is_image": mime_type.startswith(_IMAGE_MIME_PREFIX),
        }

    def resolve(self, token: str) -> _Artifact:
        with self._lock:
            self._prune()
            item = self._items.get(str(token))
        if item is None:
            raise KeyError("artifact token missing or expired")
        if not item.path.is_file() or not os.access(item.path, os.R_OK):
            raise KeyError("artifact no longer readable")
        return item


def _clean_candidate(value: str) -> str:
    return value.strip().strip("`\"'").strip()


def _extract_media(text: str, registry: ArtifactRegistry) -> tuple[str, list[dict[str, object]]]:
    artifacts: list[dict[str, object]] = []
    seen: set[Path] = set()
    output: list[str] = []

    def register(candidate: str) -> bool:
        normalized_candidate = _clean_candidate(candidate)
        try:
            resolved = Path(normalized_candidate).expanduser().resolve(strict=True)
            if resolved in seen:
                return True
            artifact = registry.register(resolved)
        except (OSError, RuntimeError, ValueError) as exc:
            _LOGGER.warning(
                "MEDIA attachment rejected: candidate=%r error=%s detail=%s",
                normalized_candidate[:1000],
                type(exc).__name__,
                exc,
            )
            return False
        seen.add(resolved)
        artifacts.append(artifact)
        return True

    for line in str(text or "").splitlines():
        standalone = _STANDALONE_MEDIA.match(line)
        if standalone:
            candidate = _clean_candidate(standalone.group(1))
            if register(candidate):
                continue
            output.append(f"[附件不可用：{Path(candidate).name or '未知文件'}]")
            continue

        def replace_inline(match: re.Match[str]) -> str:
            candidate = match.group(1)
            return "" if register(candidate) else f"[附件不可用：{Path(candidate).name or '未知文件'}]"

        output.append(_INLINE_MEDIA.sub(replace_inline, line).rstrip())

    cleaned = "\n".join(line for line in output if line.strip()).strip()
    return cleaned, artifacts


def _decorate_text_container(container: dict, registry: ArtifactRegistry) -> None:
    key = "text" if isinstance(container.get("text"), str) else "content"
    text = container.get(key)
    if not isinstance(text, str) or "MEDIA:" not in text.upper():
        return
    cleaned, artifacts = _extract_media(text, registry)
    container[key] = cleaned
    if isinstance(container.get("rendered"), str):
        container["rendered"] = cleaned
    if artifacts:
        container["artifacts"] = artifacts


def _add_provider_label(frame: dict, provider_label: str) -> bool:
    label = str(provider_label or "").strip()
    if not label:
        return False
    changed = False

    def decorate(container: object) -> None:
        nonlocal changed
        if not isinstance(container, dict):
            return
        if container.get("provider_label") or container.get("provider_name"):
            return
        container["provider_label"] = label
        changed = True

    result = frame.get("result")
    if isinstance(result, dict):
        decorate(result.get("info"))
        messages = result.get("messages")
        if isinstance(messages, list):
            for stored_message in messages:
                if isinstance(stored_message, dict) and stored_message.get("role") == "assistant":
                    decorate(stored_message)

    if frame.get("method") == "event":
        params = frame.get("params")
        if isinstance(params, dict) and params.get("type") == "session.info":
            decorate(params.get("payload"))
    return changed


def transform_hermes_message(
    message: str,
    registry: ArtifactRegistry,
    provider_label: str = "",
) -> str:
    """Attach artifact metadata to Hermes live and resumed assistant messages."""

    try:
        frame = json.loads(message)
    except (TypeError, json.JSONDecodeError):
        return message
    if not isinstance(frame, dict):
        return message

    changed = _add_provider_label(frame, provider_label)

    result = frame.get("result")
    if isinstance(result, dict) and isinstance(result.get("messages"), list):
        for stored_message in result["messages"]:
            if not isinstance(stored_message, dict) or stored_message.get("role") != "assistant":
                continue
            before = stored_message.get("text")
            _decorate_text_container(stored_message, registry)
            changed = changed or stored_message.get("text") != before or bool(stored_message.get("artifacts"))
        if changed:
            return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
        return message

    if frame.get("method") != "event":
        return json.dumps(frame, ensure_ascii=False, separators=(",", ":")) if changed else message
    params = frame.get("params")
    if not isinstance(params, dict) or params.get("type") != "message.complete":
        return json.dumps(frame, ensure_ascii=False, separators=(",", ":")) if changed else message
    payload = params.get("payload")
    if not isinstance(payload, dict):
        return message
    before = payload.get("text")
    _decorate_text_container(payload, registry)
    if payload.get("text") == before and not payload.get("artifacts") and not changed:
        return message
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
