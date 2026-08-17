#!/usr/bin/env bash
set -euo pipefail

release_dir=/root/release-migration/daiworld-voice-single-agent
staging_dir=/home/admin/daiworld-voice-attachment-fix-20260817
target_file="$release_dir/app/native_main.py"
staged_file="$staging_dir/native_main.py"
service_name=daiworld-voice-single-agent.service
backup_file="$target_file.bak.$(date +%Y%m%d%H%M%S)"

test -f "$target_file"
test -f "$staged_file"
"$release_dir/.venv/bin/python" -m py_compile "$staged_file"
install -o root -g root -m 0644 "$target_file" "$backup_file"

rollback() {
  if test -f "$backup_file"; then
    install -o root -g root -m 0644 "$backup_file" "$target_file"
    systemctl restart "$service_name" || true
  fi
}
trap rollback ERR

install -o root -g root -m 0644 "$staged_file" "$target_file"
(
cd "$release_dir"
"$release_dir/.venv/bin/python" - <<'PY'
import json
from pathlib import Path

from app.native_main import artifact_delivery_instructions, inject_session_instructions

message = json.dumps({
    "method": "session.create",
    "params": {"instructions": "mobile preference"},
})
transformed = json.loads(inject_session_instructions(
    message,
    "agent policy",
    artifact_delivery_instructions((Path("/tmp"),)),
))
instructions = transformed["params"]["instructions"]
assert "agent policy" in instructions
assert "mobile preference" in instructions
assert "Attachment delivery requirement" in instructions
assert "MEDIA:<absolute-path>" in instructions
assert "/tmp" in instructions
PY
)

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
trap - ERR

printf 'Attachment delivery rollout succeeded; backup=%s sha256=' "$backup_file"
sha256sum "$target_file" | awk '{print $1}'
