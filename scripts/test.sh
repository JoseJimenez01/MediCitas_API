#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker compose up -d --build --wait
docker compose -f docker-compose.yml -f docker-compose.tests.yml --profile tests run --build --rm tests
