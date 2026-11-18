#!/usr/bin/env bash
# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

DURATION="${DURATION:-60}"
TOP="${TOP:-15}"
NETWORK="${NETWORK:-opentelemetry-demo}"
NAME="weaver-live-check"
ADMIN_PORT="${ADMIN_PORT:-4320}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT="$(mktemp -t weaver-report.XXXXXX)"

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -f "$REPORT"
}
trap cleanup EXIT

for tool in docker jq curl; do
  command -v "$tool" >/dev/null || { echo "${RED}$tool is required${RESET}" >&2; exit 2; }
done
docker inspect otel-collector >/dev/null 2>&1 || { echo "${RED}the demo is not running, start it with 'make start'${RESET}" >&2; exit 2; }

WEAVER_IMAGE="$(grep -oE '^FROM \S*otel/weaver\S*' "$ROOT/src/telemetry-docs/Dockerfile" | head -1 | cut -d' ' -f2)"

echo "${BOLD}Telemetry validation${RESET} ${DIM}(weaver live-check against telemetry-schema/)${RESET}"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --memory 3g --network "$NETWORK" -p "$ADMIN_PORT:$ADMIN_PORT" \
  --mount "type=bind,source=$ROOT/telemetry-schema,target=/home/weaver/source,readonly" \
  "$WEAVER_IMAGE" registry live-check -r source --v2 --include-unreferenced --search-all-attributes \
  --otlp-grpc-address 0.0.0.0 --otlp-grpc-port 4317 --admin-port "$ADMIN_PORT" \
  --format json --no-stream --output http >/dev/null

for _ in $(seq 1 60); do
  curl -sf "localhost:$ADMIN_PORT/health" >/dev/null && break
  sleep 2
done
curl -sf "localhost:$ADMIN_PORT/health" >/dev/null || { echo "${RED}weaver did not start${RESET}" >&2; exit 2; }

echo "${DIM}waiting for the frontend to be healthy...${RESET}"
for _ in $(seq 1 90); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' frontend 2>/dev/null)" = "healthy" ] && break
  sleep 2
done

if [ -t 1 ]; then
  for ((remaining = DURATION; remaining > 0; remaining--)); do
    printf '\r%s  collecting telemetry, %3ds left%s' "$DIM" "$remaining" "$RESET"
    sleep 1
  done
  printf '\r%-60s\r' ""
else
  echo "collecting telemetry for ${DURATION}s..."
  sleep "$DURATION"
fi

echo "${DIM}building report...${RESET}"
curl -sf -m 300 -X POST "localhost:$ADMIN_PORT/stop" >/dev/null
curl -sf -m 300 "localhost:$ADMIN_PORT/report" -o "$REPORT"
curl -s -X POST "localhost:$ADMIN_PORT/shutdown" >/dev/null || true

findings='[.samples[] | .. | objects | select(.type? == "PolicyFinding")]'

jq -r --arg bold "$BOLD" --arg dim "$DIM" --arg red "$RED" --arg yellow "$YELLOW" --arg reset "$RESET" --argjson top "$TOP" "
  $findings as \$f
  | .statistics as \$s
  | def count(id): [\$f[] | select(.id == id)] | length;
    def pad(n): tostring | . + (\" \" * (n - length));
    def lpad(n): tostring | (\" \" * (n - length)) + .;
  \"\(\$s.total_entities_by_type.span // 0) spans, \(\$s.total_entities_by_type.attribute // 0) attributes checked\",
  \"\",
  \"\(\$bold)Findings\(\$reset)\",
  \"  \(\$red)violation  \(\$reset) \(\$s.advice_level_counts.violation // 0)\",
  \"  \(\$yellow)improvement\(\$reset) \(\$s.advice_level_counts.improvement // 0)\",
  \"  information \(\$s.advice_level_counts.information // 0)\",
  \"\",
  \"\(\$bold)Attributes missing from the registry\(\$reset) \(\$dim)(emitted by services, not documented)\(\$reset)\",
  (
    [\$f[] | select(.id == \"missing_attribute\")]
    | group_by(.context.attribute_key)
    | map({key: .[0].context.attribute_key, n: length, spans: ([.[].signal_name] | unique)})
    | sort_by(-.n)
    | .[0:\$top][]
    | \"  \(\$red)\(.key | pad(34))\(\$reset) \(.n | lpad(6))  \(\$dim)e.g. \(.spans[0])\(\$reset)\"
  ),
  \"\",
  \"\(\$bold)Deprecated attributes still in use\(\$reset)\",
  (
    [\$f[] | select(.id == \"deprecated\")]
    | group_by(.context.attribute_key)
    | map({key: .[0].context.attribute_key, n: length, note: (.[0].context.deprecation_note // \"\")})
    | sort_by(-.n)
    | .[0:5][]
    | \"  \(\$yellow)\(.key | pad(34))\(\$reset) \(.n | lpad(6))  \(\$dim)\(.note)\(\$reset)\"
  )
" "$REPORT"

missing="$(jq "$findings | map(select(.id == \"missing_attribute\")) | length" "$REPORT")"
echo
if [ "$missing" -gt 0 ]; then
  echo "${RED}${BOLD}FAILED${RESET} $missing telemetry attributes are not defined in telemetry-schema/"
  exit 1
fi
echo "${GREEN}${BOLD}PASSED${RESET} every attribute is defined in telemetry-schema/"
