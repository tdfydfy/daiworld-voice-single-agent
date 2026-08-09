import httpx
import pytest

from app.native_main import fetch_hermes_session_detail


@pytest.mark.anyio
async def test_fetch_hermes_session_detail_combines_model_and_timestamps():
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.url.path, request.headers.get("x-hermes-session-token")))
        if request.url.path.endswith("/messages"):
            return httpx.Response(
                200,
                json={
                    "session_id": "stored-1",
                    "messages": [
                        {"id": 1, "role": "user", "content": "你好", "timestamp": 1700000000.0},
                        {"id": 2, "role": "assistant", "content": "你好", "timestamp": 1700000002.5},
                    ],
                    "pagination": {"has_more": False},
                },
            )
        return httpx.Response(200, json={"id": "stored-1", "model": "gpt-5.6-sol", "title": "测试"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await fetch_hermes_session_detail(
            client,
            "http://hermes.local",
            "internal-token",
            "stored-1",
        )

    assert result["session"]["model"] == "gpt-5.6-sol"
    assert result["messages"][1]["timestamp"] == 1700000002.5
    assert seen == [
        ("/api/sessions/stored-1", "internal-token"),
        ("/api/sessions/stored-1/messages", "internal-token"),
    ]
