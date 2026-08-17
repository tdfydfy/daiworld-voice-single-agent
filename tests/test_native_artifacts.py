import json
import logging
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.artifacts import ArtifactRegistry, transform_hermes_message
from app.native_main import NativeSettings, create_native_app


def _complete(text: str) -> str:
    return json.dumps(
        {
            "jsonrpc": "2.0",
            "method": "event",
            "params": {
                "type": "message.complete",
                "session_id": "s1",
                "payload": {"text": text, "status": "complete"},
            },
        },
        ensure_ascii=False,
    )


def test_explicit_media_tag_registers_any_agent_readable_file(tmp_path: Path):
    report = tmp_path / "方案报告.pdf"
    report.write_bytes(b"%PDF-test")
    registry = ArtifactRegistry(ttl_seconds=600)

    transformed = json.loads(
        transform_hermes_message(_complete(f"报告已生成。\nMEDIA:{report}"), registry)
    )
    payload = transformed["params"]["payload"]

    assert payload["text"] == "报告已生成。"
    assert len(payload["artifacts"]) == 1
    artifact = payload["artifacts"][0]
    assert artifact["name"] == "方案报告.pdf"
    assert artifact["mime_type"] == "application/pdf"
    assert artifact["size"] == len(b"%PDF-test")
    assert "path" not in artifact
    assert registry.resolve(artifact["token"]).path == report.resolve()


def test_artifact_allowlist_rejects_outside_root_and_sensitive_files(tmp_path: Path):
    allowed = tmp_path / "allowed"
    allowed.mkdir()
    safe = allowed / "answer.txt"
    safe.write_text("ok")
    secret = allowed / ".env"
    secret.write_text("TOKEN=secret")
    outside = tmp_path / "outside.txt"
    outside.write_text("no")
    registry = ArtifactRegistry(allowed_roots=[allowed])

    assert registry.register(safe)["name"] == "answer.txt"
    with pytest.raises(OSError):
        registry.register(secret)
    with pytest.raises(OSError):
        registry.register(outside)


def test_unrestricted_registry_allows_any_readable_regular_file(tmp_path: Path):
    readable = tmp_path / ".env"
    readable.write_text("TEST_ONLY=value")
    registry = ArtifactRegistry(allowed_roots=[])

    artifact = registry.register(readable)

    assert artifact["name"] == ".env"
    assert registry.resolve(artifact["token"]).path == readable.resolve()


def test_rejected_media_path_writes_server_diagnostic(caplog: pytest.LogCaptureFixture, tmp_path: Path):
    missing = tmp_path / "missing-image.png"

    with caplog.at_level(logging.WARNING, logger="app.artifacts"):
        payload = json.loads(
            transform_hermes_message(_complete(f"MEDIA:{missing}"), ArtifactRegistry())
        )["params"]["payload"]

    assert payload["text"] == "[附件不可用：missing-image.png]"
    assert "missing-image.png" in caplog.text
    assert "FileNotFoundError" in caplog.text


def test_https_media_url_becomes_an_image_artifact_without_link_text():
    remote_url = "https://show.example.test/assets/logo%20final.png?version=2#preview"
    registry = ArtifactRegistry()

    payload = json.loads(
        transform_hermes_message(_complete(f"图片如下\nMEDIA:{remote_url}"), registry)
    )["params"]["payload"]

    assert payload["text"] == "图片如下"
    artifact = payload["artifacts"][0]
    assert artifact["name"] == "logo final.png"
    assert artifact["mime_type"] == "image/png"
    assert artifact["is_image"] is True
    assert "show.example.test" not in json.dumps(payload)
    issued = registry.resolve(artifact["token"])
    assert issued.path is None
    assert issued.remote_url == "https://show.example.test/assets/logo%20final.png?version=2"


@pytest.mark.parametrize("text", [
    "文档已生成：[下载 Word](https://show.example.test/files/report%20final.docx?signature=opaque)",
    "文档已生成：https://show.example.test/files/report%20final.docx?signature=opaque",
])
def test_https_document_link_becomes_an_artifact_without_exposing_the_domain(text: str):
    registry = ArtifactRegistry()

    payload = json.loads(transform_hermes_message(_complete(text), registry))["params"]["payload"]

    assert "show.example.test" not in payload["text"]
    artifact = payload["artifacts"][0]
    assert artifact["name"] == "report final.docx"
    assert artifact["mime_type"] == (
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    )
    assert artifact["is_image"] is False
    assert registry.resolve(artifact["token"]).remote_url.endswith("?signature=opaque")


def test_plain_web_link_is_not_promoted_to_an_artifact():
    text = "详情：https://show.example.test/articles/report"

    payload = json.loads(transform_hermes_message(_complete(text), ArtifactRegistry()))[
        "params"
    ]["payload"]

    assert payload["text"] == text
    assert "artifacts" not in payload


@pytest.mark.parametrize("remote_url", [
    "http://show.example.test/logo.png",
    "https://user:password@show.example.test/logo.png",
])
def test_unsafe_remote_media_url_is_not_issued(remote_url: str):
    payload = json.loads(
        transform_hermes_message(_complete(f"MEDIA:{remote_url}"), ArtifactRegistry())
    )["params"]["payload"]

    assert "artifacts" not in payload
    assert payload["text"] == "[附件不可用：logo.png]"


def test_artifact_size_limit(tmp_path: Path):
    report = tmp_path / "large.bin"
    report.write_bytes(b"12345")
    registry = ArtifactRegistry(max_bytes=4)

    with pytest.raises(OSError):
        registry.register(report)

def test_image_artifact_is_marked_for_inline_rendering(tmp_path: Path):
    image = tmp_path / "preview.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\n")
    registry = ArtifactRegistry(ttl_seconds=600)

    payload = json.loads(transform_hermes_message(_complete(f"MEDIA:{image}"), registry))["params"]["payload"]

    assert payload["artifacts"][0]["is_image"] is True


def test_resume_response_reissues_artifacts_for_stored_assistant_messages(tmp_path: Path):
    report = tmp_path / "history.txt"
    report.write_text("history artifact")
    frame = json.dumps(
        {
            "jsonrpc": "2.0",
            "id": "resume-1",
            "result": {
                "session_id": "runtime",
                "messages": [
                    {"role": "user", "text": "给我文件"},
                    {"role": "assistant", "text": f"已生成\nMEDIA:{report}"},
                ],
            },
        },
        ensure_ascii=False,
    )
    registry = ArtifactRegistry(ttl_seconds=600)

    result = json.loads(transform_hermes_message(frame, registry))["result"]["messages"]

    assert result[0]["text"] == "给我文件"
    assert result[1]["text"] == "已生成"
    assert result[1]["artifacts"][0]["name"] == "history.txt"


def test_rest_history_content_reissues_artifacts_and_preserves_timestamp(tmp_path: Path):
    report = tmp_path / "rest-history.pdf"
    report.write_bytes(b"%PDF")
    frame = json.dumps(
        {
            "result": {
                "messages": [
                    {
                        "role": "assistant",
                        "content": f"文件如下\nMEDIA:{report}",
                        "timestamp": 1700000000.5,
                    }
                ]
            }
        },
        ensure_ascii=False,
    )

    message = json.loads(transform_hermes_message(frame, ArtifactRegistry()))["result"]["messages"][0]

    assert message["content"] == "文件如下"
    assert message["timestamp"] == 1700000000.5
    assert message["artifacts"][0]["name"] == "rest-history.pdf"


def test_unselected_path_has_no_download_token(tmp_path: Path):
    secret = tmp_path / "secret.txt"
    secret.write_text("secret")
    registry = ArtifactRegistry(ttl_seconds=600)

    transformed = json.loads(transform_hermes_message(_complete("普通文字回答"), registry))

    assert "artifacts" not in transformed["params"]["payload"]
    with pytest.raises(KeyError):
        registry.resolve("not-issued")


def test_artifact_token_expires(tmp_path: Path):
    now = [100.0]
    file = tmp_path / "data.csv"
    file.write_text("a,b\n1,2\n")
    registry = ArtifactRegistry(ttl_seconds=10, clock=lambda: now[0])
    token = registry.register(file)["token"]

    now[0] = 111.0

    with pytest.raises(KeyError):
        registry.resolve(token)


def test_auth_session_uses_http_only_cookie(tmp_path: Path):
    settings = NativeSettings()
    settings.access_token = "test-token"
    app = create_native_app(settings)
    client = TestClient(app)

    denied = client.post("/api/auth/session")
    allowed = client.post("/api/auth/session", headers={"X-Voice-Token": "test-token"})

    assert denied.status_code == 401
    assert allowed.status_code == 200
    cookie = allowed.headers["set-cookie"].lower()
    assert "voice_session=" in cookie
    assert "httponly" in cookie
    assert "samesite=strict" in cookie

def test_artifact_http_route_serves_only_issued_tokens(tmp_path: Path):
    image = tmp_path / "result.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\n")
    settings = NativeSettings()
    settings.access_token = "test-token"
    app = create_native_app(settings)
    artifact = app.state.artifact_registry.register(image)
    client = TestClient(app)

    inline = client.get(f"/api/artifacts/{artifact['token']}")
    download = client.get(f"/api/artifacts/{artifact['token']}?download=1")
    missing = client.get("/api/artifacts/not-issued")

    assert inline.status_code == 200
    assert inline.content == image.read_bytes()
    assert inline.headers["content-type"].startswith("image/png")
    assert inline.headers["x-content-type-options"] == "nosniff"
    assert "default-src 'none'" in inline.headers["content-security-policy"]
    assert "attachment" not in inline.headers.get("content-disposition", "")
    assert download.status_code == 200
    assert "attachment" in download.headers["content-disposition"]
    assert missing.status_code == 404


def test_remote_image_artifact_route_redirects_without_exposing_url_in_metadata():
    settings = NativeSettings()
    settings.access_token = "test-token"
    app = create_native_app(settings)
    remote_url = "https://show.example.test/image/logo.png?signature=opaque"
    artifact = app.state.artifact_registry.register_remote_url(remote_url)
    client = TestClient(app)

    response = client.get(
        f"/api/artifacts/{artifact['token']}",
        follow_redirects=False,
    )

    assert response.status_code == 307
    assert response.headers["location"] == remote_url
    assert response.headers["cache-control"] == "private, no-store"
    assert response.headers["referrer-policy"] == "no-referrer"
