$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$files = @("-f", "docker-compose.yml", "-f", "tests/k6/docker-compose.k6.yml")

docker compose @files up -d --wait
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

docker compose @files --profile tests run --rm k6
exit $LASTEXITCODE
