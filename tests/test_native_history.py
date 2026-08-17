import json

import httpx
import pytest

from app.artifacts import ArtifactRegistry, transform_hermes_message
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


@pytest.mark.anyio
async def test_history_contract_preserves_reasoning_tool_calls_results_and_timestamps():
    messages = [
        {"id": 1, "role": "user", "content": "核对计划", "timestamp": 1700000000.0},
        {
            "id": 2,
            "role": "assistant",
            "content": "",
            "reasoning_content": "先读取计划。",
            "tool_calls": [
                {
                    "id": "call-plan",
                    "type": "function",
                    "function": {
                        "name": "read_file",
                        "arguments": json.dumps({"path": "docs/PLAN.md"}, ensure_ascii=False),
                    },
                }
            ],
            "timestamp": 1700000001.0,
        },
        {
            "id": 3,
            "role": "tool",
            "tool_call_id": "call-plan",
            "tool_name": "read_file",
            "content": json.dumps(
                {"success": True, "message": "读取完成", "duration_s": 0.35},
                ensure_ascii=False,
            ),
            "timestamp": 1700000001.35,
        },
        {
            "id": 4,
            "role": "assistant",
            "content": "计划已核对。",
            "reasoning_content": "整理结论。",
            "timestamp": 1700000002.0,
        },
    ]

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/messages"):
            return httpx.Response(200, json={"messages": messages, "pagination": {"has_more": False}})
        return httpx.Response(200, json={"id": "stored-tools", "model": "gpt-5.6-sol"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        result = await fetch_hermes_session_detail(
            client,
            "http://hermes.local",
            "internal-token",
            "stored-tools",
        )

    assert result["messages"] == messages
    transformed = json.loads(transform_hermes_message(
        json.dumps({"result": {"messages": result["messages"]}}, ensure_ascii=False),
        ArtifactRegistry(),
    ))["result"]["messages"]
    assert transformed[1]["reasoning_content"] == "先读取计划。"
    assert transformed[1]["tool_calls"][0]["id"] == "call-plan"
    assert transformed[2]["role"] == "tool"
    assert transformed[2]["tool_call_id"] == "call-plan"
    assert transformed[2]["timestamp"] == 1700000001.35
