#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

docker compose -f docker-compose.yml -f tests/k6/docker-compose.k6.yml up -d --wait
docker compose -f docker-compose.yml -f tests/k6/docker-compose.k6.yml --profile tests run --rm k6
