#!/usr/bin/env bash
set -euo pipefail

log_file=/home/admin/foxi-profile-catalog-rollout.log
exec > >(tee -a "$log_file") 2>&1
printf '\n=== rollout %s ===\n' "$(date --iso-8601=seconds)"

# Run on foxi as root, for example:
# sudo bash /home/admin/foxi-profile-catalog-rollout.sh
release_dir=/root/release-migration/daiworld-voice-single-agent
staged_file=/home/admin/daiworld-voice-agent-update/native_main.py
target_file="$release_dir/app/native_main.py"
env_file=/root/daiworld-voice-agent/.env
dashboard_dropin_dir=/root/.config/systemd/user/hermes-dashboard.service.d
dashboard_dropin="$dashboard_dropin_dir/20-voice-adapter.conf"
service_name=daiworld-voice-single-agent.service
stamp=$(date +%Y%m%d%H%M%S)
backup_file="$target_file.bak.$stamp"
env_backup="$env_file.bak.$stamp"
dropin_backup="$dashboard_dropin.bak.$stamp"

test -f "$staged_file"
test -f "$target_file"
test -f "$env_file"
"$release_dir/.venv/bin/python" -m py_compile "$staged_file"

install -o root -g root -m 0644 "$target_file" "$backup_file"
install -o root -g root -m 0600 "$env_file" "$env_backup"
dropin_existed=false
if test -f "$dashboard_dropin"; then
  dropin_existed=true
  install -o root -g root -m 0644 "$dashboard_dropin" "$dropin_backup"
fi

rollback() {
  install -o root -g root -m 0644 "$backup_file" "$target_file" || true
  install -o root -g root -m 0600 "$env_backup" "$env_file" || true
  if test "$dropin_existed" = true; then
    install -o root -g root -m 0644 "$dropin_backup" "$dashboard_dropin" || true
  else
    rm -f "$dashboard_dropin"
  fi
  XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
    systemctl --user daemon-reload || true
  XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
    systemctl --user restart hermes-dashboard.service || true
  systemctl enable --now \
    hermes-native-default.socket \
    hermes-native-hexiaoma.socket \
    hermes-native-hexiaoxin.socket || true
  systemctl daemon-reload || true
  systemctl restart "$service_name" || true
}
trap rollback ERR

install -o root -g root -m 0644 "$staged_file" "$target_file"
mkdir -p "$dashboard_dropin_dir"
printf '%s\n' \
  '[Service]' \
  'ExecStart=' \
  'ExecStart=/bin/bash -lc '\''set -a; . /root/daiworld-voice-agent/.env; export HERMES_DASHBOARD_SESSION_TOKEN="$VOICE_ACCESS_TOKEN"; exec /root/hermes-agent/venv/bin/python -m hermes_cli.main dashboard --host 127.0.0.1 --port 9119 --skip-build --no-open'\''' \
  > "$dashboard_dropin"
chmod 0600 "$dashboard_dropin"

XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
  systemctl --user daemon-reload
XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
  systemctl --user restart hermes-dashboard.service

dashboard_status=000
for attempt in $(seq 1 60); do
  dashboard_status=$(curl --max-time 3 -sS -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:9119/api/status || true)
  if test "$dashboard_status" = 200; then
    break
  fi
  sleep 1
done
test "$dashboard_status" = 200
set -a
. "$env_file"
set +a
test -n "${VOICE_ACCESS_TOKEN:-}"
status_payload=$(curl --max-time 10 -fsS http://127.0.0.1:9119/api/status)
"$release_dir/.venv/bin/python" -c 'import json,sys; data=json.loads(sys.argv[1]); profiles=data.get("profiles"); assert isinstance(profiles,list) and len(profiles) >= 4, data' "$status_payload"
model_status=$(curl --max-time 10 -sS -o /dev/null -w '%{http_code}' \
  -H "X-Hermes-Session-Token: $VOICE_ACCESS_TOKEN" \
  'http://127.0.0.1:9119/api/model/options?profile=default')
test "$model_status" = 200

# Discovery is authoritative. Keep old URL variables for fallback, but remove
# the static catalog override from the Adapter environment.
sed -i '/^HERMES_AGENTS_JSON=/d' "$env_file"
sed -i '/^HERMES_GATEWAY_URL=/d' "$env_file"
sed -i '/^HERMES_PROFILE_CATALOG_ENABLED=/d' "$env_file"
sed -i '/^HERMES_DASHBOARD_SESSION_TOKEN_FILE=/d' "$env_file"
printf '%s\n' \
  'HERMES_GATEWAY_URL=http://127.0.0.1:9119' \
  'HERMES_PROFILE_CATALOG_ENABLED=true' >> "$env_file"

systemctl daemon-reload
systemctl restart "$service_name"

status_code=000
for attempt in $(seq 1 60); do
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

set -a
. "$env_file"
set +a
payload=$(curl --max-time 10 -fsS -H "X-Voice-Token: $VOICE_ACCESS_TOKEN" http://127.0.0.1:8845/api/agents)
"$release_dir/.venv/bin/python" -c 'import json,sys; data=json.loads(sys.argv[1]); agents=data.get("agents"); assert isinstance(agents,list) and len(agents) >= 4, data' "$payload"

trap - ERR
printf 'Profile catalog rollout succeeded; adapter_backup=%s env_backup=%s\n' "$backup_file" "$env_backup"

# The shared official Dashboard is healthy, so the old per-Profile web
# backends are no longer needed. Hermes gateway processes are untouched.
systemctl disable --now \
  hermes-native-default.socket \
  hermes-native-hexiaoma.socket \
  hermes-native-hexiaoxin.socket || true
systemctl stop \
  hermes-native-profile@default.service \
  hermes-native-profile@hexiaoma.service \
  hermes-native-profile@hexiaoxin.service \
  hermes-native-proxy@default.service \
  hermes-native-proxy@hexiaoma.service \
  hermes-native-proxy@hexiaoxin.service || true
