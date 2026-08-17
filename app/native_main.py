from __future__ import annotations

import asyncio
from dataclasses import dataclass
import hmac
import json
import os
from pathlib import Path
import re
import tempfile
import unicodedata
from typing import Callable
from urllib.parse import quote, urlencode

import httpx
import websockets
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

from .artifacts import ArtifactRegistry, transform_hermes_message

WEB_DIR = Path(__file__).resolve().parent.parent / "web_native"
MAX_TRANSCRIBE_BODY = 25 * 1024 * 1024
MAX_SPEAK_BODY = 1 * 1024 * 1024
MAX_WS_MESSAGE = 16 * 1024 * 1024
BACKEND_WS_OPEN_TIMEOUT_SECONDS = 45
GATEWAY_HEARTBEAT_INTERVAL_SECONDS = 25.0
GATEWAY_HEARTBEAT_FRAME = json.dumps(
    {
        "jsonrpc": "2.0",
        "method": "event",
        "params": {
            "type": "gateway.heartbeat",
            "session_id": "",
            "payload": {},
        },
    },
    separators=(",", ":"),
)
AGENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
GENERIC_PROVIDER_NAMES = {
    "",
    "custom",
    "openaiapi",
    "openaicompatible",
    "openaicompatibleapi",
}
DEFAULT_VOICE_INSTRUCTIONS = (
    "This is a voice conversation. Answer concisely and naturally for listening. "
    "Avoid Markdown headings, tables, and emphasis unless the user asks for them. "
    "When the full screen response must contain code, files, or long technical detail, "
    "also provide a short plain-language speech_text summary."
)


def artifact_delivery_instructions(allowed_roots: tuple[Path, ...]) -> str:
    if not allowed_roots:
        return (
            "Attachment delivery requirement: save the final image or file as a readable regular "
            "file, then include exactly one standalone line in the final response in the form "
            "MEDIA:<absolute-path>. Any absolute path readable by Hermes can be delivered; "
            "relative, missing, unreadable, and oversized files are rejected."
        )
    staging_root = allowed_roots[0]
    return (
        "Attachment delivery requirement: before sending an image or file, copy the final "
        f"artifact to a readable regular file under {staging_root} using a unique filename. "
        "Then include exactly one standalone line in the final response in the form "
        "MEDIA:<absolute-path>. "
        f"Only MEDIA paths under {staging_root} can be delivered; paths elsewhere are rejected."
    )


def has_semantic_content(text: object) -> bool:
    """Return whether text contains a Unicode letter or number."""
    value = str(text or "")
    return any(unicodedata.category(char)[0] in {"L", "N"} for char in value)


def normalize_asr_transcript_frame(message: str) -> str:
    """Keep ASR frame shape while marking punctuation-only final text empty."""
    try:
        frame = json.loads(message)
    except (TypeError, json.JSONDecodeError):
        return message
    if not isinstance(frame, dict) or frame.get("type") != "transcript":
        return message
    if frame.get("final") is not True or not isinstance(frame.get("text"), str):
        return message
    if has_semantic_content(frame["text"]):
        return message
    frame["text"] = ""
    frame["interim"] = False
    frame["final"] = True
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))


@dataclass(frozen=True)
class AgentDefinition:
    id: str
    name: str
    url: str
    is_default: bool = False
    avatar_url: str = ""
    provider_label: str = ""
    instructions: str = DEFAULT_VOICE_INSTRUCTIONS

    def public_dict(self) -> dict[str, object]:
        result: dict[str, object] = {
            "id": self.id,
            "name": self.name,
            "is_default": self.is_default,
        }
        if self.avatar_url:
            result["avatar_url"] = self.avatar_url
        return result


def _legacy_agents() -> list[AgentDefinition]:
    return [
        AgentDefinition(
            id="default",
            name="赫准行",
            url=os.getenv("HERMES_DEFAULT_URL", "http://127.0.0.1:9120"),
            is_default=True,
            provider_label=os.getenv("HERMES_DEFAULT_PROVIDER_LABEL", ""),
        ),
        AgentDefinition(
            id="hexiaoma",
            name="赫小码",
            url=os.getenv("HERMES_HEXIAOMA_URL", "http://127.0.0.1:9121"),
            provider_label=os.getenv("HERMES_HEXIAOMA_PROVIDER_LABEL", ""),
        ),
        AgentDefinition(
            id="hexiaoxin",
            name="赫小新",
            url=os.getenv("HERMES_HEXIAOXIN_URL", "http://127.0.0.1:9122"),
            provider_label=os.getenv("HERMES_HEXIAOXIN_PROVIDER_LABEL", ""),
        ),
    ]


def _load_agents() -> list[AgentDefinition]:
    raw = os.getenv("HERMES_AGENTS_JSON")
    if raw is None:
        return _legacy_agents()
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError("HERMES_AGENTS_JSON must be valid JSON") from exc
    rows = parsed.get("agents") if isinstance(parsed, dict) else parsed
    if not isinstance(rows, list):
        raise ValueError("HERMES_AGENTS_JSON must be an array or an object with an agents array")

    agents: list[AgentDefinition] = []
    seen_ids: set[str] = set()
    default_count = 0
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError(f"agent at index {index} must be an object")
        agent_id = str(row.get("id", "")).strip()
        name = str(row.get("name", "")).strip()
        url = str(row.get("url", "")).strip().rstrip("/")
        if not AGENT_ID_PATTERN.fullmatch(agent_id):
            raise ValueError(f"invalid agent id at index {index}")
        if agent_id in seen_ids:
            raise ValueError(f"duplicate agent id: {agent_id}")
        if not name or not url:
            raise ValueError(f"agent {agent_id} requires name and url")
        is_default = row.get("is_default") is True
        default_count += int(is_default)
        seen_ids.add(agent_id)
        agents.append(AgentDefinition(
            id=agent_id,
            name=name,
            url=url,
            is_default=is_default,
            avatar_url=str(row.get("avatar_url", "") or "").strip(),
            provider_label=str(row.get("provider_label", "") or "").strip(),
            instructions=str(row.get("instructions", DEFAULT_VOICE_INSTRUCTIONS) or "").strip(),
        ))
    if default_count > 1:
        raise ValueError("only one agent may be marked as default")
    if agents and default_count == 0:
        first = agents[0]
        agents[0] = AgentDefinition(
            id=first.id,
            name=first.name,
            url=first.url,
            is_default=True,
            avatar_url=first.avatar_url,
            provider_label=first.provider_label,
            instructions=first.instructions,
        )
    return agents


def _load_hermes_token() -> str:
    token_file = os.getenv("HERMES_DASHBOARD_SESSION_TOKEN_FILE", "").strip()
    if not token_file:
        return os.getenv("HERMES_DASHBOARD_SESSION_TOKEN", "")
    try:
        token = Path(token_file).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValueError("cannot read HERMES_DASHBOARD_SESSION_TOKEN_FILE") from exc
    prefix = "HERMES_DASHBOARD_SESSION_TOKEN="
    if token.startswith(prefix):
        token = token[len(prefix):].strip()
    if not token:
        raise ValueError("HERMES_DASHBOARD_SESSION_TOKEN_FILE is empty")
    return token


def _hermes_profile_agents(payload: object, backend_url: str) -> list[AgentDefinition]:
    """Convert Hermes' public status profile list into the Adapter catalog."""
    rows: object = payload.get("profiles") if isinstance(payload, dict) else payload
    if not isinstance(rows, list):
        raise ValueError("Hermes profile catalog must contain a profiles array")

    agents: list[AgentDefinition] = []
    seen_ids: set[str] = set()
    default_count = 0
    for row in rows:
        if isinstance(row, str):
            profile = {"name": row}
        elif isinstance(row, dict):
            profile = row
        else:
            continue
        agent_id = str(profile.get("name") or profile.get("id") or "").strip()
        if not AGENT_ID_PATTERN.fullmatch(agent_id) or agent_id in seen_ids:
            continue
        display_name = str(
            profile.get("display_name") or profile.get("label") or agent_id
        ).strip()
        if not display_name:
            display_name = agent_id
        is_default = profile.get("is_default") is True or agent_id == "default"
        default_count += int(is_default)
        seen_ids.add(agent_id)
        agents.append(AgentDefinition(
            id=agent_id,
            name=display_name,
            url=backend_url.rstrip("/"),
            is_default=is_default,
            avatar_url=str(profile.get("avatar_url") or "").strip(),
            provider_label=str(
                profile.get("provider") or profile.get("provider_label") or ""
            ).strip(),
        ))
    if default_count > 1:
        # Older Hermes responses may mark both the name and flag as default.
        first_default = next((agent.id for agent in agents if agent.is_default), "")
        agents = [
            AgentDefinition(
                id=agent.id,
                name=agent.name,
                url=agent.url,
                is_default=agent.id == first_default,
                avatar_url=agent.avatar_url,
                provider_label=agent.provider_label,
                instructions=agent.instructions,
            )
            for agent in agents
        ]
    if agents and not any(agent.is_default for agent in agents):
        first = agents[0]
        agents[0] = AgentDefinition(
            id=first.id,
            name=first.name,
            url=first.url,
            is_default=True,
            avatar_url=first.avatar_url,
            provider_label=first.provider_label,
            instructions=first.instructions,
        )
    if not agents:
        raise ValueError("Hermes profile catalog is empty or invalid")
    return agents


async def fetch_hermes_profiles(
    client: httpx.AsyncClient,
    backend_url: str,
) -> list[AgentDefinition]:
    response = await client.get(f"{backend_url.rstrip('/')}/api/status")
    if response.status_code != 200:
        raise RuntimeError(f"Hermes profile catalog HTTP {response.status_code}")
    return _hermes_profile_agents(response.json(), backend_url)


def inject_session_instructions(
    message: str,
    instructions: str,
    required_instructions: str = "",
) -> str:
    try:
        frame = json.loads(message)
    except (json.JSONDecodeError, TypeError):
        return message
    if not isinstance(frame, dict) or frame.get("method") != "session.create":
        return message
    params = frame.get("params")
    if not isinstance(params, dict):
        return message
    client_value = params.get("instructions")
    client_instructions = client_value.strip() if isinstance(client_value, str) else ""
    sections: list[str] = []
    for value in (instructions.strip(), client_instructions, required_instructions.strip()):
        if value and value not in sections:
            sections.append(value)
    if not sections:
        return message
    params["instructions"] = "\n\n".join(sections)
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))


PROFILE_SCOPED_SESSION_METHODS = {
    "session.create",
    "session.list",
    "session.resume",
    "session.delete",
}


def inject_session_profile(message: str, profile: str) -> str:
    if not profile:
        return message
    try:
        frame = json.loads(message)
    except (json.JSONDecodeError, TypeError):
        return message
    if not isinstance(frame, dict) or frame.get("method") not in PROFILE_SCOPED_SESSION_METHODS:
        return message
    params = frame.get("params")
    if params is None:
        params = {}
        frame["params"] = params
    if not isinstance(params, dict) or params.get("profile"):
        return message
    params["profile"] = profile
    return json.dumps(frame, ensure_ascii=False, separators=(",", ":"))


def _provider_token(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value or "").strip().lower())


def _provider_id(row: dict) -> str:
    for key in ("slug", "id", "provider"):
        value = str(row.get(key, "") or "").strip()
        if value:
            return value
    return ""


def decorate_model_options(payload: dict, configured_label: str = "") -> dict:
    """Expose concrete provider aliases without leaking provider credentials."""

    result = dict(payload)
    raw_providers = payload.get("providers")
    if not isinstance(raw_providers, list):
        return result

    providers: list[dict] = []
    marked_active: list[str] = []
    for raw_provider in raw_providers:
        if not isinstance(raw_provider, dict):
            continue
        provider = dict(raw_provider)
        provider_id = _provider_id(provider)
        provider_name = str(provider.get("name", "") or "").strip()
        if (
            provider_id
            and _provider_token(provider_name) in GENERIC_PROVIDER_NAMES
            and _provider_token(provider_id) not in GENERIC_PROVIDER_NAMES
        ):
            provider["name"] = provider_id
        if any(provider.get(key) is True for key in (
            "active", "current", "selected", "is_active", "is_current", "is_default"
        )):
            marked_active.append(provider_id or str(provider.get("name", "") or "").strip())
        providers.append(provider)

    result["providers"] = providers
    active_label = str(configured_label or "").strip()
    if not active_label:
        for key in (
            "active_provider_label", "provider_label", "current_provider",
            "active_provider", "default_provider", "provider",
        ):
            candidate = str(payload.get(key, "") or "").strip()
            if candidate and _provider_token(candidate) not in GENERIC_PROVIDER_NAMES:
                active_label = candidate
                break
    if not active_label:
        marked_active = [value for value in marked_active if value]
        if len(marked_active) == 1 and _provider_token(marked_active[0]) not in GENERIC_PROVIDER_NAMES:
            active_label = marked_active[0]
    if not active_label and len(providers) == 1:
        only_id = _provider_id(providers[0])
        if only_id and _provider_token(only_id) not in GENERIC_PROVIDER_NAMES:
            active_label = only_id

    if active_label:
        result["active_provider_label"] = active_label
        if len(providers) == 1:
            only_provider = providers[0]
            if _provider_token(only_provider.get("name")) in GENERIC_PROVIDER_NAMES:
                only_provider["name"] = active_label
    return result


async def fetch_hermes_session_detail(
    client: httpx.AsyncClient,
    backend_url: str,
    hermes_token: str,
    session_id: str,
    profile: str = "",
) -> dict:
    encoded = quote(str(session_id), safe="")
    headers = {"X-Hermes-Session-Token": hermes_token}
    params = {"profile": profile} if profile else None
    session_response, messages_response = await asyncio.gather(
        client.get(
            f"{backend_url.rstrip('/')}/api/sessions/{encoded}",
            headers=headers,
            params=params,
        ),
        client.get(
            f"{backend_url.rstrip('/')}/api/sessions/{encoded}/messages",
            headers=headers,
            params=params,
        ),
    )
    session_response.raise_for_status()
    messages_response.raise_for_status()
    session = session_response.json()
    transcript = messages_response.json()
    return {
        "session": session,
        "messages": transcript.get("messages") or [],
        "pagination": transcript.get("pagination") or {},
    }


class NativeSettings:
    def __init__(self) -> None:
        self.access_token = os.getenv("VOICE_ACCESS_TOKEN", "")
        self.hermes_token = _load_hermes_token()
        self.cookie_secure = os.getenv("VOICE_COOKIE_SECURE", "").lower() in {"1", "true", "yes"}
        self.backend_on_demand = os.getenv("HERMES_BACKEND_ON_DEMAND", "").lower() in {
            "1", "true", "yes"
        }
        self.profile_catalog_enabled = os.getenv("HERMES_PROFILE_CATALOG_ENABLED", "true").lower() in {
            "1", "true", "yes"
        } and os.getenv("HERMES_AGENTS_JSON") is None
        self.catalog_base_url = (
            os.getenv("HERMES_GATEWAY_URL")
            or "http://127.0.0.1:9119"
        ).strip().rstrip("/")
        self.catalog_lock = asyncio.Lock()
        self.catalog_attempted = not self.profile_catalog_enabled
        self.catalog_error = ""
        self.agents = _load_agents()
        self.backends = {agent.id: agent.url for agent in self.agents}
        self.provider_labels = {agent.id: agent.provider_label for agent in self.agents}
        self.instructions = {agent.id: agent.instructions for agent in self.agents}

    def replace_agents(self, agents: list[AgentDefinition]) -> None:
        self.agents = agents
        self.backends = {agent.id: agent.url for agent in agents}
        self.provider_labels = {agent.id: agent.provider_label for agent in agents}
        self.instructions = {agent.id: agent.instructions for agent in agents}


def create_native_app(settings: NativeSettings | None = None) -> FastAPI:
    settings = settings or NativeSettings()
    app = FastAPI(title="Daiworld Native Hermes Web", version="0.2.0-native-open-source")
    app.state.settings = settings
    allow_all_readable_artifacts = os.getenv(
        "VOICE_ARTIFACT_ALLOW_ALL_READABLE", ""
    ).lower() in {"1", "true", "yes"}
    artifact_roots = [] if allow_all_readable_artifacts else [
        item.strip()
        for item in os.getenv("VOICE_ARTIFACT_ROOTS", tempfile.gettempdir()).split(os.pathsep)
        if item.strip()
    ]
    try:
        artifact_max_bytes = int(os.getenv("VOICE_ARTIFACT_MAX_BYTES", str(50 * 1024 * 1024)))
    except ValueError:
        artifact_max_bytes = 50 * 1024 * 1024
    artifact_registry = ArtifactRegistry(
        ttl_seconds=900,
        allowed_roots=artifact_roots,
        max_bytes=artifact_max_bytes,
    )
    app.state.artifact_registry = artifact_registry
    required_artifact_instructions = artifact_delivery_instructions(
        artifact_registry.allowed_roots
    )

    def require_access(token: str) -> None:
        if not settings.access_token or not hmac.compare_digest(token, settings.access_token):
            raise HTTPException(status_code=401, detail="访问口令错误")

    def websocket_token(ws: WebSocket, query_token: str) -> str:
        return query_token or ws.cookies.get("voice_session", "")

    async def ensure_agent_catalog(force: bool = False) -> None:
        if not settings.profile_catalog_enabled:
            return
        if settings.catalog_attempted and not force:
            return
        async with settings.catalog_lock:
            if settings.catalog_attempted and not force:
                return
            try:
                async with httpx.AsyncClient(timeout=15) as client:
                    agents = await fetch_hermes_profiles(
                        client,
                        settings.catalog_base_url,
                    )
                known_agents = {agent.id: agent for agent in settings.agents}
                agents = [
                    AgentDefinition(
                        id=agent.id,
                        name=known_agents.get(agent.id, agent).name,
                        url=agent.url,
                        is_default=agent.is_default,
                        avatar_url=known_agents.get(agent.id, agent).avatar_url,
                        provider_label=known_agents.get(agent.id, agent).provider_label,
                        instructions=known_agents.get(agent.id, agent).instructions,
                    )
                    for agent in agents
                ]
                settings.replace_agents(agents)
                settings.catalog_error = ""
            except Exception as exc:
                # Preserve the last usable catalog. A retry only happens through
                # an explicit refresh request or after the Adapter restarts.
                settings.catalog_error = str(exc)
            finally:
                settings.catalog_attempted = True

    @app.post("/api/auth/session")
    async def auth_session(request: Request, x_voice_token: str = Header(default="")) -> Response:
        require_access(x_voice_token)
        response = Response(content='{"status":"ok"}', media_type="application/json")
        response.set_cookie(
            "voice_session",
            settings.access_token,
            max_age=3600,
            httponly=True,
            secure=settings.cookie_secure or request.url.scheme == "https",
            samesite="strict",
            path="/",
        )
        return response

    def backend(profile: str) -> str:
        if profile not in settings.backends:
            raise HTTPException(status_code=400, detail="未知Hermes Profile")
        return settings.backends[profile].rstrip("/")

    def enforce_body_limit(request: Request, limit: int) -> None:
        raw_length = request.headers.get("content-length")
        if raw_length is None:
            return
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="无效的Content-Length") from exc
        if length < 0 or length > limit:
            raise HTTPException(status_code=413, detail="请求体过大")

    @app.get("/api/health")
    async def health(x_voice_token: str = Header(default="")) -> dict:
        require_access(x_voice_token)
        if settings.backend_on_demand:
            return {
                "status": "ok",
                "mode": "hermes-native-on-demand",
                "profiles": {
                    profile: {"ok": None, "state": "on-demand"}
                    for profile in settings.backends
                },
            }
        states: dict[str, dict] = {}
        async with httpx.AsyncClient(timeout=8) as client:
            for profile in settings.backends:
                try:
                    response = await client.get(
                        f"{backend(profile)}/api/status",
                        headers={"X-Hermes-Session-Token": settings.hermes_token},
                    )
                    states[profile] = {
                        "ok": response.status_code == 200,
                        "status": response.json() if response.status_code == 200 else None,
                    }
                except Exception as exc:
                    states[profile] = {"ok": False, "error": str(exc)}
        return {"status": "ok", "mode": "hermes-native", "profiles": states}

    @app.get("/api/agents")
    async def agent_catalog(
        refresh: bool = False,
        x_voice_token: str = Header(default=""),
    ) -> dict:
        require_access(x_voice_token)
        await ensure_agent_catalog(force=refresh)
        return {"agents": [agent.public_dict() for agent in settings.agents]}

    @app.post("/api/audio/transcribe")
    async def transcribe(
        request: Request,
        profile: str,
        x_voice_token: str = Header(default=""),
    ) -> Response:
        require_access(x_voice_token)
        enforce_body_limit(request, MAX_TRANSCRIBE_BODY)
        body = await request.body()
        async with httpx.AsyncClient(timeout=120) as client:
            response = await client.post(
                f"{backend(profile)}/api/audio/transcribe",
                params={"profile": profile},
                headers={
                    "X-Hermes-Session-Token": settings.hermes_token,
                    "Content-Type": request.headers.get("content-type", "application/json"),
                },
                content=body,
            )
        return Response(
            response.content,
            status_code=response.status_code,
            media_type=response.headers.get("content-type", "application/json"),
        )

    @app.post("/api/audio/speak")
    async def speak(
        request: Request,
        profile: str,
        x_voice_token: str = Header(default=""),
    ) -> Response:
        require_access(x_voice_token)
        enforce_body_limit(request, MAX_SPEAK_BODY)
        body = await request.body()
        async with httpx.AsyncClient(timeout=180) as client:
            response = await client.post(
                f"{backend(profile)}/api/audio/speak",
                params={"profile": profile},
                headers={
                    "X-Hermes-Session-Token": settings.hermes_token,
                    "Content-Type": "application/json",
                },
                content=body,
            )
        return Response(
            response.content,
            status_code=response.status_code,
            media_type=response.headers.get("content-type", "application/json"),
        )

    @app.get("/api/hermes/model/options")
    async def hermes_model_options(
        profile: str,
        x_voice_token: str = Header(default=""),
    ) -> dict:
        require_access(x_voice_token)
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.get(
                f"{backend(profile)}/api/model/options",
                params={"profile": profile},
                headers={"X-Hermes-Session-Token": settings.hermes_token},
            )
            if response.status_code != 200:
                raise HTTPException(
                    status_code=502,
                    detail="Hermes模型列表读取失败",
                )
            payload = response.json()
            if not isinstance(payload, dict):
                raise HTTPException(status_code=502, detail="Hermes模型列表格式错误")
            return decorate_model_options(payload, settings.provider_labels[profile])

    @app.post("/api/hermes/model/set")
    async def hermes_model_set(
        request: Request,
        profile: str,
        x_voice_token: str = Header(default=""),
    ) -> dict:
        require_access(x_voice_token)
        body = await request.json()
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(
                f"{backend(profile)}/api/model/set",
                params={"profile": profile},
                json=body,
                headers={"X-Hermes-Session-Token": settings.hermes_token},
            )
            if response.status_code != 200:
                raise HTTPException(
                    status_code=502,
                    detail="Hermes模型切换失败",
                )
            return response.json()

    @app.get("/api/hermes/sessions/{session_id}")
    async def hermes_session_detail(
        session_id: str,
        profile: str,
        x_voice_token: str = Header(default=""),
    ) -> dict:
        require_access(x_voice_token)
        try:
            async with httpx.AsyncClient(timeout=60) as client:
                detail = await fetch_hermes_session_detail(
                    client,
                    backend(profile),
                    settings.hermes_token,
                    session_id,
                    profile,
                )
        except httpx.HTTPStatusError as exc:
            status = 404 if exc.response.status_code == 404 else 502
            raise HTTPException(status_code=status, detail="Hermes历史详情读取失败") from exc
        frame = json.dumps({"result": {"messages": detail["messages"]}}, ensure_ascii=False)
        detail["messages"] = json.loads(
            transform_hermes_message(frame, artifact_registry, settings.provider_labels[profile])
        )["result"]["messages"]
        return detail

    async def relay_ws(
        client_ws: WebSocket,
        upstream_url: str,
        transform_text: Callable[[str], str] | None = None,
        transform_client_text: Callable[[str], str] | None = None,
        heartbeat_interval: float | None = None,
    ) -> None:
        await client_ws.accept()
        try:
            async with websockets.connect(
                upstream_url,
                max_size=MAX_WS_MESSAGE,
                open_timeout=BACKEND_WS_OPEN_TIMEOUT_SECONDS,
                ping_interval=20,
            ) as upstream:
                client_send_lock = asyncio.Lock()

                async def send_client_text(message: str) -> None:
                    async with client_send_lock:
                        await client_ws.send_text(message)

                async def send_client_bytes(message: bytes) -> None:
                    async with client_send_lock:
                        await client_ws.send_bytes(message)

                async def client_to_upstream() -> None:
                    while True:
                        message = await client_ws.receive()
                        if message.get("text") is not None:
                            outgoing = (transform_client_text(message["text"])
                                        if transform_client_text else message["text"])
                            if len(outgoing.encode("utf-8")) > MAX_WS_MESSAGE:
                                await client_ws.close(code=1009)
                                return
                            await upstream.send(outgoing)
                        elif message.get("bytes") is not None:
                            if len(message["bytes"]) > MAX_WS_MESSAGE:
                                await client_ws.close(code=1009)
                                return
                            await upstream.send(message["bytes"])
                        else:
                            return

                async def upstream_to_client() -> None:
                    async for message in upstream:
                        if isinstance(message, bytes):
                            await send_client_bytes(message)
                        else:
                            await send_client_text(transform_text(message) if transform_text else message)

                async def heartbeat_to_client() -> None:
                    if heartbeat_interval is None:
                        return
                    while True:
                        await asyncio.sleep(heartbeat_interval)
                        await send_client_text(GATEWAY_HEARTBEAT_FRAME)

                tasks = {
                    asyncio.create_task(client_to_upstream()),
                    asyncio.create_task(upstream_to_client()),
                }
                if heartbeat_interval is not None:
                    tasks.add(asyncio.create_task(heartbeat_to_client()))
                done, pending = await asyncio.wait(
                    tasks, return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
                await asyncio.gather(*done, return_exceptions=True)
        except (WebSocketDisconnect, websockets.ConnectionClosed):
            pass
        finally:
            try:
                await client_ws.close()
            except Exception:
                pass

    @app.websocket("/api/hermes/ws")
    async def hermes_ws(ws: WebSocket, profile: str, token: str = "") -> None:
        try:
            require_access(websocket_token(ws, token))
            base = backend(profile).replace("http://", "ws://").replace("https://", "wss://")
        except HTTPException:
            await ws.close(code=4401)
            return
        query = urlencode({"token": settings.hermes_token, "profile": profile})
        await relay_ws(
            ws,
            f"{base}/api/ws?{query}",
            transform_text=lambda message: transform_hermes_message(
                message,
                artifact_registry,
                settings.provider_labels[profile],
            ),
            transform_client_text=lambda message: inject_session_instructions(
                inject_session_profile(message, profile),
                settings.instructions[profile],
                required_artifact_instructions,
            ),
            heartbeat_interval=GATEWAY_HEARTBEAT_INTERVAL_SECONDS,
        )

    @app.websocket("/api/audio/speak-stream")
    async def speak_stream(ws: WebSocket, profile: str, token: str = "") -> None:
        try:
            require_access(websocket_token(ws, token))
            base = backend(profile).replace("http://", "ws://").replace("https://", "wss://")
        except HTTPException:
            await ws.close(code=4401)
            return
        query = urlencode({"token": settings.hermes_token, "profile": profile})
        await relay_ws(ws, f"{base}/api/audio/speak-stream?{query}")

    @app.websocket("/api/audio/transcribe-stream")
    async def transcribe_stream(ws: WebSocket, profile: str, token: str = "") -> None:
        try:
            require_access(websocket_token(ws, token))
            base = backend(profile).replace("http://", "ws://").replace("https://", "wss://")
        except HTTPException:
            await ws.close(code=4401)
            return
        query = urlencode({"token": settings.hermes_token, "profile": profile})
        await relay_ws(
            ws,
            f"{base}/api/audio/transcribe-stream?{query}",
            transform_text=normalize_asr_transcript_frame,
        )

    @app.get("/api/artifacts/{token}")
    async def artifact(token: str, download: bool = False) -> FileResponse:
        try:
            item = artifact_registry.resolve(token)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="附件不存在或已过期") from exc
        is_image = item.mime_type.startswith("image/")
        return FileResponse(
            item.path,
            media_type=item.mime_type,
            filename=item.path.name if download or not is_image else None,
            headers={
                "Cache-Control": "private, no-store",
                "X-Content-Type-Options": "nosniff",
                "Content-Security-Policy": "default-src 'none'; sandbox",
            },
        )

    @app.get("/")
    async def index() -> FileResponse:
        return FileResponse(WEB_DIR / "index.html", headers={"Cache-Control": "no-store"})

    app.mount("/assets", StaticFiles(directory=WEB_DIR), name="native-assets")
    return app


app = create_native_app()
