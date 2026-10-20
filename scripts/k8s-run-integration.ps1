$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")

kubectl --context kind-restaurant-api -n restaurant-api create configmap k6-scripts `
  --from-file=integration.js=tests/k6/integration.js `
  --from-file=persistence-create.js=tests/k6/persistence-create.js `
  --from-file=persistence-verify.js=tests/k6/persistence-verify.js `
  --dry-run=client -o yaml | kubectl --context kind-restaurant-api apply -f -
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

kubectl --context kind-restaurant-api delete job k6-integration -n restaurant-api --ignore-not-found
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api apply -f k8s/tests/k6-integration-job.yaml
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=complete job/k6-integration --timeout=240s
$waitCode = $LASTEXITCODE
kubectl --context kind-restaurant-api logs -n restaurant-api job/k6-integration
exit $waitCode
