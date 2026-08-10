from __future__ import annotations

import asyncio
import hmac
import json
import os
from pathlib import Path
from typing import Callable
from urllib.parse import quote, urlencode

import httpx
import websockets
from fastapi import FastAPI, Header, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles

from .artifacts import ArtifactRegistry, transform_hermes_message

WEB_DIR = Path(__file__).resolve().parent.parent / "web_native"
PROFILES = ("default", "hexiaoma", "hexiaoxin")
MAX_TRANSCRIBE_BODY = 25 * 1024 * 1024
MAX_SPEAK_BODY = 1 * 1024 * 1024
MAX_WS_MESSAGE = 16 * 1024 * 1024


async def fetch_hermes_session_detail(
    client: httpx.AsyncClient,
    backend_url: str,
    hermes_token: str,
    session_id: str,
) -> dict:
    encoded = quote(str(session_id), safe="")
    headers = {"X-Hermes-Session-Token": hermes_token}
    session_response, messages_response = await asyncio.gather(
        client.get(f"{backend_url.rstrip('/')}/api/sessions/{encoded}", headers=headers),
        client.get(f"{backend_url.rstrip('/')}/api/sessions/{encoded}/messages", headers=headers),
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
        self.hermes_token = os.getenv("HERMES_DASHBOARD_SESSION_TOKEN", "")
        self.cookie_secure = os.getenv("VOICE_COOKIE_SECURE", "").lower() in {"1", "true", "yes"}
        self.backends = {
            "default": os.getenv("HERMES_DEFAULT_URL", "http://127.0.0.1:9120"),
            "hexiaoma": os.getenv("HERMES_HEXIAOMA_URL", "http://127.0.0.1:9121"),
            "hexiaoxin": os.getenv("HERMES_HEXIAOXIN_URL", "http://127.0.0.1:9122"),
        }
        self.provider_labels = {
            "default": os.getenv("HERMES_DEFAULT_PROVIDER_LABEL", ""),
            "hexiaoma": os.getenv("HERMES_HEXIAOMA_PROVIDER_LABEL", ""),
            "hexiaoxin": os.getenv("HERMES_HEXIAOXIN_PROVIDER_LABEL", ""),
        }


def create_native_app(settings: NativeSettings | None = None) -> FastAPI:
    settings = settings or NativeSettings()
    app = FastAPI(title="Daiworld Native Hermes Web", version="0.2.0-native-open-source")
    artifact_roots = [
        item.strip()
        for item in os.getenv("VOICE_ARTIFACT_ROOTS", "/tmp").split(os.pathsep)
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

    def require_access(token: str) -> None:
        if not settings.access_token or not hmac.compare_digest(token, settings.access_token):
            raise HTTPException(status_code=401, detail="访问口令错误")

    def websocket_token(ws: WebSocket, query_token: str) -> str:
        return query_token or ws.cookies.get("voice_session", "")

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
        if profile not in PROFILES:
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
        states: dict[str, dict] = {}
        async with httpx.AsyncClient(timeout=8) as client:
            for profile in PROFILES:
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
    ) -> None:
        await client_ws.accept()
        try:
            async with websockets.connect(upstream_url, max_size=MAX_WS_MESSAGE, ping_interval=20) as upstream:
                async def client_to_upstream() -> None:
                    while True:
                        message = await client_ws.receive()
                        if message.get("text") is not None:
                            if len(message["text"].encode("utf-8")) > MAX_WS_MESSAGE:
                                await client_ws.close(code=1009)
                                return
                            await upstream.send(message["text"])
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
                            await client_ws.send_bytes(message)
                        else:
                            await client_ws.send_text(transform_text(message) if transform_text else message)

                first = asyncio.create_task(client_to_upstream())
                second = asyncio.create_task(upstream_to_client())
                done, pending = await asyncio.wait(
                    {first, second}, return_when=asyncio.FIRST_COMPLETED
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
        query = urlencode({"token": settings.hermes_token})
        await relay_ws(
            ws,
            f"{base}/api/ws?{query}",
            transform_text=lambda message: transform_hermes_message(
                message,
                artifact_registry,
                settings.provider_labels[profile],
            ),
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
        await relay_ws(ws, f"{base}/api/audio/transcribe-stream?{query}")

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
