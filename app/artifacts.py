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
from urllib.parse import unquote, urlsplit, urlunsplit


_STANDALONE_MEDIA = re.compile(r"^\s*[`\"'*_]{0,3}MEDIA:\s*(.+?)[`\"'*_]{0,3}\s*$", re.IGNORECASE)
_INLINE_MEDIA = re.compile(r"MEDIA:\s*((?:(?:https://)|(?:~?/|/))[^\s`\"']+)", re.IGNORECASE)
_MARKDOWN_LINK = re.compile(r"\[([^\]\r\n]+)\]\(([^\s)]+)\)", re.IGNORECASE)
_BARE_REFERENCE = re.compile(
    r"(?<![A-Za-z0-9_:/+.-])(?:"
    r"(?:https?://|sandbox:|file://)[^\s<>\[\]()`\"']+|"
    r"(?:~?/|\.\.?/|[A-Za-z]:[\\/])[^\s<>\[\]()`\"']+)",
    re.IGNORECASE,
)
_IMAGE_MIME_PREFIX = "image/"
_LOGGER = logging.getLogger(__name__)

_DOWNLOADABLE_EXTENSIONS = frozenset({
    ".7z", ".apng", ".avif", ".bmp", ".csv", ".doc", ".docx", ".epub", ".gif",
    ".gz", ".heic", ".heif", ".ico", ".jpeg", ".jpg", ".json", ".md", ".odf",
    ".ods", ".odt", ".pdf", ".png", ".ppt", ".pptx", ".rar", ".rtf", ".svg",
    ".tar", ".tif", ".tiff", ".txt", ".webp", ".xls", ".xlsx", ".xml", ".zip",
})
_TRAILING_URL_PUNCTUATION = ".,;:!?，。；：！？"
_LOCAL_REFERENCE_SCHEMES = frozenset({"file", "sandbox"})


@dataclass(frozen=True)
class _Artifact:
    path: Path | None
    expires_at: float
    mime_type: str
    remote_url: str = ""


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

    def _issue(
        self,
        *,
        path: Path | None,
        name: str,
        mime_type: str,
        size: int,
        remote_url: str = "",
    ) -> dict[str, object]:
        token = secrets.token_urlsafe(32)
        with self._lock:
            self._prune()
            self._items[token] = _Artifact(
                path=path,
                expires_at=self.clock() + self.ttl_seconds,
                mime_type=mime_type,
                remote_url=remote_url,
            )
        return {
            "token": token,
            "name": name,
            "mime_type": mime_type,
            "size": size,
            "is_image": mime_type.startswith(_IMAGE_MIME_PREFIX),
        }

    def register(self, raw_path: str | Path) -> dict[str, object]:
        path = Path(raw_path).expanduser().resolve(strict=True)
        if not self._is_allowed(path):
            raise OSError("file is outside the artifact allowlist")
        if not path.is_file() or not os.access(path, os.R_OK):
            raise OSError("file is not readable")
        size = path.stat().st_size
        if size > self.max_bytes:
            raise OSError("file exceeds artifact size limit")
        mime_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        return self._issue(path=path, name=path.name, mime_type=mime_type, size=size)

    def register_remote_url(self, raw_url: str) -> dict[str, object]:
        value = str(raw_url or "").strip()
        if len(value) > 8192:
            raise ValueError("remote artifact URL is too long")
        parsed = urlsplit(value)
        if (
            parsed.scheme.lower() != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
        ):
            raise ValueError("remote artifact must use an HTTPS URL without credentials")
        name = Path(unquote(parsed.path)).name
        if not name:
            raise ValueError("remote artifact URL has no filename")
        remote_url = urlunsplit(("https", parsed.netloc, parsed.path, parsed.query, ""))
        mime_type = mimetypes.guess_type(name)[0] or "application/octet-stream"
        return self._issue(
            path=None,
            name=name,
            mime_type=mime_type,
            size=0,
            remote_url=remote_url,
        )

    def resolve(self, token: str) -> _Artifact:
        with self._lock:
            self._prune()
            item = self._items.get(str(token))
        if item is None:
            raise KeyError("artifact token missing or expired")
        if item.path is not None and (not item.path.is_file() or not os.access(item.path, os.R_OK)):
            raise KeyError("artifact no longer readable")
        return item


def _clean_candidate(value: str) -> str:
    return value.strip().strip("`\"'").strip()


def _diagnostic_candidate(value: str) -> str:
    if value.lower().startswith(("http://", "https://")):
        parsed = urlsplit(value)
        host = parsed.hostname or "invalid-host"
        return urlunsplit((parsed.scheme, host, parsed.path, "", ""))[:1000]
    return value[:1000]


def _implicit_attachment_reference(value: str) -> str:
    candidate = _clean_candidate(value).rstrip(_TRAILING_URL_PUNCTUATION)
    if re.match(r"^[A-Za-z]:[\\/]", candidate):
        return candidate if Path(unquote(candidate)).suffix.lower() in _DOWNLOADABLE_EXTENSIONS else ""
    parsed = urlsplit(candidate)
    scheme = parsed.scheme.lower()
    if scheme == "https":
        if not parsed.hostname:
            return ""
        suffix = Path(unquote(parsed.path)).suffix.lower()
        return candidate if suffix in _DOWNLOADABLE_EXTENSIONS else ""
    if scheme in _LOCAL_REFERENCE_SCHEMES:
        local_path = _local_path_from_reference(candidate)
        if local_path is None or local_path.suffix.lower() not in _DOWNLOADABLE_EXTENSIONS:
            return ""
        return candidate
    if scheme:
        return ""
    try:
        local_path = Path(unquote(candidate)).expanduser()
    except (OSError, ValueError):
        return ""
    return candidate if local_path.suffix.lower() in _DOWNLOADABLE_EXTENSIONS else ""


def _local_path_from_reference(value: str) -> Path | None:
    candidate = _clean_candidate(value)
    if re.match(r"^[A-Za-z]:[\\/]", candidate):
        return Path(unquote(candidate)).expanduser()
    parsed = urlsplit(candidate)
    scheme = parsed.scheme.lower()
    if scheme not in _LOCAL_REFERENCE_SCHEMES:
        if scheme:
            return None
        return Path(unquote(candidate)).expanduser()
    if parsed.query or parsed.fragment:
        return None
    if parsed.netloc and parsed.netloc.lower() not in {"", "localhost"}:
        return None
    path = unquote(parsed.path)
    if not path:
        return None
    # Keep local references testable on Windows while preserving POSIX paths in production.
    if os.name == "nt" and re.match(r"^/[A-Za-z]:[\\/]", path):
        path = path[1:]
    return Path(path).expanduser()


def _extract_media(text: str, registry: ArtifactRegistry) -> tuple[str, list[dict[str, object]]]:
    artifacts: list[dict[str, object]] = []
    seen: set[str] = set()
    output: list[str] = []

    def register(candidate: str) -> bool:
        normalized_candidate = _clean_candidate(candidate)
        try:
            if normalized_candidate.lower().startswith("https://"):
                identity = normalized_candidate
                if identity in seen:
                    return True
                artifact = registry.register_remote_url(normalized_candidate)
            else:
                local_path = _local_path_from_reference(normalized_candidate)
                if local_path is None:
                    raise ValueError("unsupported attachment reference")
                resolved = local_path.resolve(strict=True)
                identity = str(resolved)
                if identity in seen:
                    return True
                artifact = registry.register(resolved)
        except (OSError, RuntimeError, ValueError) as exc:
            _LOGGER.warning(
                "MEDIA attachment rejected: candidate=%r error=%s detail=%s",
                _diagnostic_candidate(normalized_candidate),
                type(exc).__name__,
                exc,
            )
            return False
        seen.add(identity)
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

        line = _INLINE_MEDIA.sub(replace_inline, line)

        def replace_markdown_link(match: re.Match[str]) -> str:
            candidate = _implicit_attachment_reference(match.group(2))
            if not candidate:
                return match.group(0)
            if not register(candidate):
                return f"[附件不可用：{match.group(1).strip() or '未知文件'}]"
            return match.group(1).strip()

        line = _MARKDOWN_LINK.sub(replace_markdown_link, line)

        def replace_bare_reference(match: re.Match[str]) -> str:
            raw_candidate = match.group(0)
            candidate = _implicit_attachment_reference(raw_candidate)
            if not candidate:
                return raw_candidate
            if not register(candidate):
                return f"[附件不可用：{Path(unquote(urlsplit(candidate).path)).name or '未知文件'}]"
            return raw_candidate[len(candidate):]

        output.append(_BARE_REFERENCE.sub(replace_bare_reference, line).rstrip())

    cleaned = "\n".join(line for line in output if line.strip()).strip()
    return cleaned, artifacts


def _decorate_text_container(container: dict, registry: ArtifactRegistry) -> None:
    key = "text" if isinstance(container.get("text"), str) else "content"
    text = container.get(key)
    if not isinstance(text, str):
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
