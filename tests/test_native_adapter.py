import asyncio
import json
import time

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import native_main
from app.native_main import NativeSettings, create_native_app


class FakeUpstream:
    def __init__(self, messages):
        self.messages = iter(messages)
        self.sent = []

    async def send(self, message):
        self.sent.append(message)

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            return next(self.messages)
        except StopIteration as exc:
            await asyncio.sleep(0.5)
            raise StopAsyncIteration from exc


class FakeConnect:
    def __init__(self, upstream):
        self.upstream = upstream

    async def __aenter__(self):
        return self.upstream

    async def __aexit__(self, exc_type, exc, tb):
        return False


def make_app(provider_label=""):
    settings = NativeSettings()
    settings.access_token = "voice-token"
    settings.hermes_token = "hermes-token"
    settings.provider_labels["hexiaoma"] = provider_label
    return create_native_app(settings)


def test_websocket_cookie_auth_and_transparent_relay(monkeypatch):
    upstream = FakeUpstream([json.dumps({"method": "event", "params": {"type": "gateway.ready"}})])
    seen = {}

    def connect(url, **kwargs):
        seen["url"] = url
        seen["kwargs"] = kwargs
        return FakeConnect(upstream)

    monkeypatch.setattr(native_main.websockets, "connect", connect)
    client = TestClient(make_app())
    auth = client.post("/api/auth/session", headers={"X-Voice-Token": "voice-token"})
    assert auth.status_code == 200

    with client.websocket_connect("/api/hermes/ws?profile=hexiaoma") as websocket:
        assert json.loads(websocket.receive_text())["params"]["type"] == "gateway.ready"
        websocket.send_text(json.dumps({"jsonrpc": "2.0", "method": "ping"}))
        time.sleep(0.05)

    assert "token=hermes-token" in seen["url"]
    assert "voice-token" not in seen["url"]
    assert seen["kwargs"]["max_size"] == native_main.MAX_WS_MESSAGE
    assert upstream.sent == [json.dumps({"jsonrpc": "2.0", "method": "ping"})]


def test_websocket_adds_configured_provider_label(monkeypatch):
    upstream = FakeUpstream([
        json.dumps({
            "method": "event",
            "params": {
                "type": "session.info",
                "payload": {"model": "model-a", "provider": "custom"},
            },
        })
    ])

    monkeypatch.setattr(native_main.websockets, "connect", lambda *args, **kwargs: FakeConnect(upstream))
    client = TestClient(make_app("open1"))
    client.post("/api/auth/session", headers={"X-Voice-Token": "voice-token"})

    with client.websocket_connect("/api/hermes/ws?profile=hexiaoma") as websocket:
        payload = json.loads(websocket.receive_text())["params"]["payload"]

    assert payload["provider"] == "custom"
    assert payload["provider_label"] == "open1"


def test_websocket_without_cookie_is_rejected():
    client = TestClient(make_app())
    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect("/api/hermes/ws?profile=default"):
            pass
    assert error.value.code == 4401


def test_unknown_profile_is_rejected_before_upstream(monkeypatch):
    called = False

    def connect(*args, **kwargs):
        nonlocal called
        called = True
        raise AssertionError("upstream must not be opened")

    monkeypatch.setattr(native_main.websockets, "connect", connect)
    client = TestClient(make_app())
    client.post("/api/auth/session", headers={"X-Voice-Token": "voice-token"})
    with pytest.raises(WebSocketDisconnect) as error:
        with client.websocket_connect("/api/hermes/ws?profile=unknown"):
            pass
    assert error.value.code == 4401
    assert called is False


def test_large_http_body_is_rejected_before_upstream():
    client = TestClient(make_app())
    response = client.post(
        "/api/audio/speak?profile=default",
        headers={
            "X-Voice-Token": "voice-token",
            "Content-Length": str(native_main.MAX_SPEAK_BODY + 1),
        },
        content=b"x",
    )
    assert response.status_code == 413


class FakeResponse:
    def __init__(self, status_code, payload=None):
        self.status_code = status_code
        self._payload = payload or {}

    def json(self):
        return self._payload


class FakeHttpClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, tb):
        return False

    async def get(self, url, **kwargs):
        self.requests.append(("GET", url, kwargs))
        return self.responses.pop(0) if self.responses else FakeResponse(502)

    async def post(self, url, **kwargs):
        self.requests.append(("POST", url, kwargs))
        return self.responses.pop(0) if self.responses else FakeResponse(502)


def test_model_options_proxy_requires_voice_token_and_forwards_hermes_token(monkeypatch):
    fake = FakeHttpClient([
        FakeResponse(200, {"providers": [{"slug": "deepseek", "models": ["deepseek-v4-pro"]}]}),
    ])
    monkeypatch.setattr(native_main.httpx, "AsyncClient", lambda **kwargs: fake)
    client = TestClient(make_app())

    unauthorized = client.get("/api/hermes/model/options?profile=hexiaoma")
    assert unauthorized.status_code == 401
    assert fake.requests == []

    response = client.get(
        "/api/hermes/model/options?profile=hexiaoma",
        headers={"X-Voice-Token": "voice-token"},
    )
    assert response.status_code == 200
    assert response.json()["providers"][0]["slug"] == "deepseek"
    method, url, kwargs = fake.requests[-1]
    assert method == "GET"
    assert url == "http://127.0.0.1:9121/api/model/options"
    assert kwargs["headers"] == {"X-Hermes-Session-Token": "hermes-token"}


def test_model_set_proxy_posts_body_and_rejects_unknown_profile(monkeypatch):
    fake = FakeHttpClient([FakeResponse(200, {"ok": True, "scope": "main"})])
    monkeypatch.setattr(native_main.httpx, "AsyncClient", lambda **kwargs: fake)
    client = TestClient(make_app())

    response = client.post(
        "/api/hermes/model/set?profile=hexiaoma",
        headers={"X-Voice-Token": "voice-token"},
        json={"scope": "main", "provider": "deepseek", "model": "deepseek-v4-pro"},
    )
    assert response.status_code == 200
    assert response.json()["ok"] is True
    method, url, kwargs = fake.requests[-1]
    assert method == "POST"
    assert url == "http://127.0.0.1:9121/api/model/set"
    assert kwargs["json"] == {"scope": "main", "provider": "deepseek", "model": "deepseek-v4-pro"}

    rejected = client.post(
        "/api/hermes/model/set?profile=unknown",
        headers={"X-Voice-Token": "voice-token"},
        json={"scope": "main", "provider": "deepseek", "model": "deepseek-v4-pro"},
    )
    assert rejected.status_code == 400
