$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$files = @("-f", "docker-compose.yml", "-f", "tests/k6/docker-compose.k6.yml")
$marker = "persist-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$date = (Get-Date).ToUniversalTime().AddDays(10).ToString("yyyy-MM-dd")

docker compose @files up -d --wait
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

docker compose @files --profile tests run --rm `
  -e PERSISTENCE_MARKER=$marker `
  -e PERSISTENCE_DATE=$date `
  k6 run /scripts/persistence-create.js
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# No usar -v. Porue el volumen debe sobrevivir
docker compose @files down
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

docker compose @files up -d --wait
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

docker compose @files --profile tests run --rm `
  -e PERSISTENCE_MARKER=$marker `
  -e PERSISTENCE_DATE=$date `
  k6 run /scripts/persistence-verify.js
exit $LASTEXITCODE
