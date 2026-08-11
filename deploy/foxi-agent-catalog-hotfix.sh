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

for attempt in $(seq 1 20); do
  if systemctl is-active --quiet "$service_name"; then
    status_code=$(curl --max-time 3 -sS -o /dev/null -w '%{http_code}' \
      http://127.0.0.1:8845/api/agents || true)
    if test "$status_code" = 401; then
      trap - ERR
      printf 'Agent Catalog deployed successfully; backup=%s\n' "$backup_file"
      exit 0
    fi
  fi
  sleep 1
done

printf 'Agent Catalog verification failed\n' >&2
exit 1
