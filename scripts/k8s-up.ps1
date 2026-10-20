$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
Get-Command docker, kind, kubectl -ErrorAction Stop | Out-Null
$cluster = "restaurant-api"
$secretFile = "k8s/overlays/local/secrets.env"
$secretExample = "k8s/overlays/local/secrets.env.example"

if (-not (Test-Path $secretFile)) {
    Copy-Item $secretExample $secretFile
    Write-Host "Se creo $secretFile desde el ejemplo."
}

if (Select-String -Path $secretFile -Pattern "CAMBIAR_" -Quiet) {
    Write-Host "Edite ${secretFile}: todavia contiene valores CAMBIAR_*."
    exit 1
}

docker build -t restaurant-api:local .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$previousErrorActionPreference = $ErrorActionPreference
try {
    $ErrorActionPreference = "Continue"
    $clusters = @(kind get clusters 2>$null)
    $clustersExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($clustersExitCode -ne 0) { exit $clustersExitCode }
if ($clusters -notcontains $cluster) {
    kind create cluster --name $cluster --config k8s/overlays/local/kind-config.yaml
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

kind load docker-image restaurant-api:local --name $cluster
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

kubectl --context kind-restaurant-api apply -k k8s/overlays/local
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=available deployment/postgres --timeout=180s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=available deployment/keycloak --timeout=300s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api rollout restart deployment/restaurant-api -n restaurant-api
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api rollout status deployment/restaurant-api -n restaurant-api --timeout=180s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api get pods -n restaurant-api
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "API disponible en http://localhost:8081"
