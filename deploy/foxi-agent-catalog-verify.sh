#!/usr/bin/env bash
set -euo pipefail

printf 'sudo user: '
whoami
printf 'service: '
systemctl is-active daiworld-voice-single-agent.service
printf 'agent route: '
curl --max-time 3 -sS -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1:8845/api/agents
