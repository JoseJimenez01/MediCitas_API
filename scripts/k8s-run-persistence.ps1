$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$marker = "persist-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$date = (Get-Date).ToUniversalTime().AddDays(10).ToString("yyyy-MM-dd")

kubectl --context kind-restaurant-api -n restaurant-api create configmap k6-scripts `
  --from-file=integration.js=tests/k6/integration.js `
  --from-file=persistence-create.js=tests/k6/persistence-create.js `
  --from-file=persistence-verify.js=tests/k6/persistence-verify.js `
  --dry-run=client -o yaml | kubectl --context kind-restaurant-api apply -f -

kubectl --context kind-restaurant-api -n restaurant-api create configmap k6-persistence-config `
  --from-literal=PERSISTENCE_MARKER=$marker `
  --from-literal=PERSISTENCE_DATE=$date `
  --dry-run=client -o yaml | kubectl --context kind-restaurant-api apply -f -

kubectl --context kind-restaurant-api delete job k6-persistence-create -n restaurant-api --ignore-not-found
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api apply -f k8s/tests/k6-persistence-create-job.yaml
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=complete job/k6-persistence-create --timeout=180s
if ($LASTEXITCODE -ne 0) {
    kubectl --context kind-restaurant-api logs -n restaurant-api job/k6-persistence-create
    exit 1
}
kubectl --context kind-restaurant-api logs -n restaurant-api job/k6-persistence-create

# Reinicia solo el pod de PostgreSQL. El PVC permanece.
# API y Keycloak se reinician para reestablecer sus pools contra el postgres nuevo
# (Keycloak comparte el mismo postgres y su pool queda roto si no se reinicia;
#  paridad con la prueba de Compose, que reinicia todo el stack).
kubectl --context kind-restaurant-api delete pod -n restaurant-api -l app=postgres
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api rollout restart deploy/restaurant-api -n restaurant-api
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api rollout restart deploy/keycloak -n restaurant-api
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Start-Sleep -Seconds 5
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=ready pod -l app=postgres --timeout=180s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api rollout status deploy/keycloak -n restaurant-api --timeout=240s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api rollout status deploy/restaurant-api -n restaurant-api --timeout=180s
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

kubectl --context kind-restaurant-api delete job k6-persistence-verify -n restaurant-api --ignore-not-found
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api apply -f k8s/tests/k6-persistence-verify-job.yaml
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=complete job/k6-persistence-verify --timeout=180s
$waitCode = $LASTEXITCODE
kubectl --context kind-restaurant-api logs -n restaurant-api job/k6-persistence-verify
exit $waitCode
