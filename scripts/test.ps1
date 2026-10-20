$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
docker compose up -d --build --wait
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker compose -f docker-compose.yml -f docker-compose.tests.yml --profile tests run --build --rm tests
exit $LASTEXITCODE
