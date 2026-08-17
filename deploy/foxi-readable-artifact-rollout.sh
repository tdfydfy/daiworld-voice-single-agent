#!/usr/bin/env bash
set -euo pipefail

release_dir=/root/release-migration/daiworld-voice-single-agent
staging_dir=/home/admin/daiworld-voice-readable-artifacts-20260817
service_name=daiworld-voice-single-agent.service
drop_in_dir=/etc/systemd/system/daiworld-voice-single-agent.service.d
policy_file="$drop_in_dir/readable-artifacts.conf"
timestamp=$(date +%Y%m%d%H%M%S)
artifacts_backup="$release_dir/app/artifacts.py.bak.$timestamp"
native_backup="$release_dir/app/native_main.py.bak.$timestamp"
policy_backup="$staging_dir/readable-artifacts.conf.bak.$timestamp"
policy_existed=false

test -f "$staging_dir/artifacts.py"
test -f "$staging_dir/native_main.py"
"$release_dir/.venv/bin/python" -m py_compile \
  "$staging_dir/artifacts.py" "$staging_dir/native_main.py"

install -o root -g root -m 0644 "$release_dir/app/artifacts.py" "$artifacts_backup"
install -o root -g root -m 0644 "$release_dir/app/native_main.py" "$native_backup"
if test -f "$policy_file"; then
  install -o admin -g admin -m 0600 "$policy_file" "$policy_backup"
  policy_existed=true
fi

rollback() {
  install -o root -g root -m 0644 "$artifacts_backup" "$release_dir/app/artifacts.py"
  install -o root -g root -m 0644 "$native_backup" "$release_dir/app/native_main.py"
  if test "$policy_existed" = true; then
    install -o root -g root -m 0644 "$policy_backup" "$policy_file"
  else
    rm -f "$policy_file"
  fi
  systemctl daemon-reload || true
  systemctl restart "$service_name" || true
}
trap rollback ERR

install -o root -g root -m 0644 "$staging_dir/artifacts.py" "$release_dir/app/artifacts.py"
install -o root -g root -m 0644 "$staging_dir/native_main.py" "$release_dir/app/native_main.py"
install -d -o root -g root -m 0755 "$drop_in_dir"
cat >"$policy_file" <<'EOF'
[Service]
Environment=VOICE_ARTIFACT_ALLOW_ALL_READABLE=true
EOF
chmod 0644 "$policy_file"

(
  cd "$release_dir"
  VOICE_ARTIFACT_ALLOW_ALL_READABLE=true "$release_dir/.venv/bin/python" - <<'PY'
import json
import tempfile

from app.native_main import NativeSettings, artifact_delivery_instructions, create_native_app
from app.artifacts import transform_hermes_message

app = create_native_app(NativeSettings())
registry = app.state.artifact_registry
assert registry.allowed_roots == ()
assert registry.register("app/artifacts.py")["name"] == "artifacts.py"
instructions = artifact_delivery_instructions(registry.allowed_roots)
assert "Any absolute path readable by Hermes can be delivered" in instructions
assert "MEDIA:<absolute-path-or-https-url>" in instructions
assert "Never copy it to a web root" in instructions
frame = json.dumps({
    "method": "event",
    "params": {
        "type": "message.complete",
        "payload": {
            "text": "文档：https://show.example.test/files/report.docx?signature=opaque",
        },
    },
})
payload = json.loads(transform_hermes_message(frame, registry))["params"]["payload"]
assert "show.example.test" not in payload["text"]
assert payload["artifacts"][0]["name"] == "report.docx"
with tempfile.NamedTemporaryFile(suffix=".docx") as report:
    sandbox_frame = json.dumps({
        "method": "event",
        "params": {
            "type": "message.complete",
            "payload": {
                "text": f"[下载 Word 文件](sandbox:{report.name})",
            },
        },
    })
    sandbox_payload = json.loads(
        transform_hermes_message(sandbox_frame, registry)
    )["params"]["payload"]
    assert "sandbox:" not in sandbox_payload["text"]
    assert sandbox_payload["artifacts"][0]["name"].endswith(".docx")
PY
)

systemctl daemon-reload
systemctl restart "$service_name"

status_code=000
for _ in $(seq 1 60); do
  if systemctl is-active --quiet "$service_name"; then
    status_code=$(curl --max-time 3 -sS -o /dev/null -w '%{http_code}' \
      http://127.0.0.1:8845/api/agents || true)
  fi
  if test "$status_code" = 401; then
    break
  fi
  sleep 1
done

test "$status_code" = 401
systemctl is-active --quiet "$service_name"
main_pid=$(systemctl show "$service_name" -p MainPID --value)
tr '\0' '\n' <"/proc/$main_pid/environ" | grep -qx 'VOICE_ARTIFACT_ALLOW_ALL_READABLE=true'
trap - ERR

printf 'Readable artifact rollout succeeded; pid=%s artifacts_backup=%s native_backup=%s sha256=' \
  "$main_pid" "$artifacts_backup" "$native_backup"
sha256sum "$release_dir/app/artifacts.py" "$release_dir/app/native_main.py" | awk '{print $1}'
