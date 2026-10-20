#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

marker="persist-$(date +%s)"
date_value="$(date -u -d '+10 days' +%F 2>/dev/null || date -u -v+10d +%F)"

compose="docker compose -f docker-compose.yml -f tests/k6/docker-compose.k6.yml"

$compose up -d --wait
$compose --profile tests run --rm \
  -e PERSISTENCE_MARKER="$marker" \
  -e PERSISTENCE_DATE="$date_value" \
  k6 run /scripts/persistence-create.js

# Igual, no usar -v. Porque el volumen debe sobrevivir
$compose down
$compose up -d --wait
$compose --profile tests run --rm \
  -e PERSISTENCE_MARKER="$marker" \
  -e PERSISTENCE_DATE="$date_value" \
  k6 run /scripts/persistence-verify.js
