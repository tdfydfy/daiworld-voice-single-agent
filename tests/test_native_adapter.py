import asyncio
import json
import time

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import native_main
from app.native_main import (
    NativeSettings,
    create_native_app,
    has_semantic_content,
    normalize_asr_transcript_frame,
)


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


def test_asr_semantic_boundary_rewrites_punctuation_only_final_without_dropping_frame():
    assert has_semantic_content("。 ,……！？---_") is False
    assert has_semantic_content("🙂©™") is False
    assert has_semantic_content("版本 2.0") is True
    assert has_semantic_content("Ⅷ") is True

    punctuation = json.dumps({
        "type": "transcript",
        "text": " ，……！？ ",
        "interim": False,
        "final": True,
    }, ensure_ascii=False)
    filtered = json.loads(normalize_asr_transcript_frame(punctuation))
    assert filtered == {
        "type": "transcript",
        "text": "",
        "interim": False,
        "final": True,
    }

    ordinary = json.dumps({
        "type": "transcript",
        "text": "好的。",
        "interim": False,
        "final": True,
    }, ensure_ascii=False)
    assert normalize_asr_transcript_frame(ordinary) == ordinary

    interim = json.dumps({
        "type": "transcript",
        "text": "……",
        "interim": True,
        "final": False,
    }, ensure_ascii=False)
    assert normalize_asr_transcript_frame(interim) == interim


def test_agent_catalog_uses_structured_config_and_hides_private_fields(monkeypatch):
    monkeypatch.setenv("HERMES_AGENTS_JSON", json.dumps({
        "agents": [
            {
                "id": "writer",
                "name": "写作助手",
                "url": "http://127.0.0.1:9200",
                "avatar_url": "https://cdn.example.com/writer.png",
                "provider_label": "private-provider",
                "instructions": "private voice policy",
            },
            {
                "id": "coder",
                "name": "代码助手",
                "url": "http://127.0.0.1:9201",
            },
        ],
    }, ensure_ascii=False))
    settings = NativeSettings()
    settings.access_token = "voice-token"
    client = TestClient(create_native_app(settings))

    unauthorized = client.get("/api/agents")
    assert unauthorized.status_code == 401

    response = client.get("/api/agents", headers={"X-Voice-Token": "voice-token"})
    assert response.status_code == 200
    assert response.json() == {
        "agents": [
            {
                "id": "writer",
                "name": "写作助手",
                "is_default": True,
                "avatar_url": "https://cdn.example.com/writer.png",
            },
            {"id": "coder", "name": "代码助手", "is_default": False},
        ],
    }
    serialized = response.text
    assert "9200" not in serialized
    assert "private-provider" not in serialized
    assert "private voice policy" not in serialized


def test_agent_catalog_allows_explicit_empty_state(monkeypatch):
    monkeypatch.setenv("HERMES_AGENTS_JSON", "[]")
    settings = NativeSettings()
    settings.access_token = "voice-token"
    client = TestClient(create_native_app(settings))

    response = client.get("/api/agents", headers={"X-Voice-Token": "voice-token"})
    assert response.json() == {"agents": []}


def test_agent_config_rejects_duplicate_ids_and_defaults(monkeypatch):
    monkeypatch.setenv("HERMES_AGENTS_JSON", json.dumps([
        {"id": "same", "name": "A", "url": "http://a", "is_default": True},
        {"id": "same", "name": "B", "url": "http://b", "is_default": True},
    ]))
    with pytest.raises(ValueError, match="duplicate agent id"):
        NativeSettings()


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
    assert seen["kwargs"]["open_timeout"] == native_main.BACKEND_WS_OPEN_TIMEOUT_SECONDS
    assert upstream.sent == [json.dumps({"jsonrpc": "2.0", "method": "ping"})]


def test_gateway_websocket_emits_downstream_heartbeat(monkeypatch):
    upstream = FakeUpstream([json.dumps({"method": "event", "params": {"type": "gateway.ready"}})])
    monkeypatch.setattr(native_main, "GATEWAY_HEARTBEAT_INTERVAL_SECONDS", 0.01)
    monkeypatch.setattr(
        native_main.websockets,
        "connect",
        lambda *args, **kwargs: FakeConnect(upstream),
    )
    client = TestClient(make_app())
    auth = client.post("/api/auth/session", headers={"X-Voice-Token": "voice-token"})
    assert auth.status_code == 200

    with client.websocket_connect("/api/hermes/ws?profile=hexiaoma") as websocket:
        assert json.loads(websocket.receive_text())["params"]["type"] == "gateway.ready"
        heartbeat = json.loads(websocket.receive_text())

    assert heartbeat == {
        "jsonrpc": "2.0",
        "method": "event",
        "params": {
            "type": "gateway.heartbeat",
            "session_id": "",
            "payload": {},
        },
    }
    assert upstream.sent == []


def test_websocket_injects_voice_instructions_only_into_session_create(monkeypatch):
    monkeypatch.setenv("HERMES_AGENTS_JSON", json.dumps([
        {
            "id": "writer",
            "name": "写作助手",
            "url": "http://127.0.0.1:9200",
            "is_default": True,
            "instructions": "Keep the spoken answer short.",
        },
    ]))
    settings = NativeSettings()
    settings.access_token = "voice-token"
    settings.hermes_token = "hermes-token"
    upstream = FakeUpstream([
        json.dumps({"method": "event", "params": {"type": "gateway.ready"}}),
    ])
    monkeypatch.setattr(native_main.websockets, "connect", lambda *args, **kwargs: FakeConnect(upstream))
    client = TestClient(create_native_app(settings))
    client.post("/api/auth/session", headers={"X-Voice-Token": "voice-token"})

    with client.websocket_connect("/api/hermes/ws?profile=writer") as websocket:
        websocket.receive_text()
        websocket.send_text(json.dumps({
            "jsonrpc": "2.0",
            "id": "1",
            "method": "session.create",
            "params": {"cols": 100},
        }))
        time.sleep(0.05)

    sent = json.loads(upstream.sent[0])
    assert sent["params"] == {
        "cols": 100,
        "instructions": "Keep the spoken answer short.",
    }


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


def test_on_demand_health_does_not_connect_to_backends(monkeypatch):
    settings = NativeSettings()
    settings.access_token = "voice-token"
    settings.backend_on_demand = True

    class UnexpectedClient:
        def __init__(self, **kwargs):
            raise AssertionError("health must not wake an on-demand backend")

    monkeypatch.setattr(native_main.httpx, "AsyncClient", UnexpectedClient)
    client = TestClient(create_native_app(settings))

    response = client.get("/api/health", headers={"X-Voice-Token": "voice-token"})

    assert response.status_code == 200
    assert response.json()["mode"] == "hermes-native-on-demand"
    assert response.json()["profiles"]["default"] == {
        "ok": None,
        "state": "on-demand",
    }


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
    assert response.json()["active_provider_label"] == "deepseek"
    method, url, kwargs = fake.requests[-1]
    assert method == "GET"
    assert url == "http://127.0.0.1:9121/api/model/options"
    assert kwargs["headers"] == {"X-Hermes-Session-Token": "hermes-token"}


def test_model_options_use_concrete_provider_ids_instead_of_generic_names(monkeypatch):
    fake = FakeHttpClient([
        FakeResponse(200, {
            "current_provider": "waw",
            "providers": [
                {"slug": "open1", "name": "OPENAIAPI", "models": ["model-a"]},
                {"slug": "waw", "name": "OPENAIAPI", "models": ["model-b"]},
            ],
        }),
    ])
    monkeypatch.setattr(native_main.httpx, "AsyncClient", lambda **kwargs: fake)
    client = TestClient(make_app())

    response = client.get(
        "/api/hermes/model/options?profile=hexiaoma",
        headers={"X-Voice-Token": "voice-token"},
    )

    assert response.status_code == 200
    assert response.json()["active_provider_label"] == "waw"
    assert [provider["name"] for provider in response.json()["providers"]] == ["open1", "waw"]


def test_model_options_recognize_hermes_current_provider_shape(monkeypatch):
    fake = FakeHttpClient([
        FakeResponse(200, {
            "provider": "open1",
            "model": "gpt-5.6-sol",
            "providers": [
                {
                    "slug": "openai-api",
                    "name": "openai-api",
                    "is_current": False,
                    "models": ["gpt-5.6-sol"],
                },
                {
                    "slug": "open1",
                    "name": "open1",
                    "is_current": True,
                    "models": ["gpt-5.6-sol"],
                },
                {
                    "slug": "wawapi",
                    "name": "wawapi",
                    "is_current": False,
                    "models": ["gpt-5.6-sol"],
                },
            ],
        }),
    ])
    monkeypatch.setattr(native_main.httpx, "AsyncClient", lambda **kwargs: fake)
    client = TestClient(make_app())

    response = client.get(
        "/api/hermes/model/options?profile=hexiaoma",
        headers={"X-Voice-Token": "voice-token"},
    )

    assert response.status_code == 200
    assert response.json()["active_provider_label"] == "open1"
    assert response.json()["providers"][1]["is_current"] is True


def test_model_options_configured_label_names_single_generic_provider(monkeypatch):
    fake = FakeHttpClient([
        FakeResponse(200, {
            "providers": [
                {"slug": "custom", "name": "OPENAIAPI", "models": ["model-a"]},
            ],
        }),
    ])
    monkeypatch.setattr(native_main.httpx, "AsyncClient", lambda **kwargs: fake)
    client = TestClient(make_app("open1"))

    response = client.get(
        "/api/hermes/model/options?profile=hexiaoma",
        headers={"X-Voice-Token": "voice-token"},
    )

    assert response.status_code == 200
    assert response.json()["active_provider_label"] == "open1"
    assert response.json()["providers"][0]["name"] == "open1"


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
