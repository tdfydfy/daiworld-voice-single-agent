#!/usr/bin/env bash
set -euo pipefail

release_dir=/root/release-migration/daiworld-voice-single-agent
staging_dir=/home/admin/daiworld-voice-agent-update-20260811
target_file="$release_dir/app/native_main.py"
staged_file="$staging_dir/native_main.py"
backup_file="$target_file.bak.$(date +%Y%m%d%H%M%S)"
service_name=daiworld-voice-single-agent.service

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
systemctl restart "$service_name"

agents_code=000
models_code=000
for attempt in $(seq 1 60); do
  if systemctl is-active --quiet "$service_name"; then
    agents_code=$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' \
      http://127.0.0.1:8845/api/agents || printf '000')
    models_code=$(curl --max-time 5 -s -o /dev/null -w '%{http_code}' \
      'http://127.0.0.1:8845/api/hermes/model/options?profile=hexiaoma' || printf '000')
    if test "$agents_code" = 401 && test "$models_code" = 401; then
      trap - ERR
      printf 'Conversation/provider update deployed; backup=%s\n' "$backup_file"
      exit 0
    fi
  fi
  sleep 1
done

printf 'Conversation/provider update verification failed: service=%s agents=%s models=%s\n' \
  "$(systemctl is-active "$service_name" || true)" "$agents_code" "$models_code" >&2
exit 1
