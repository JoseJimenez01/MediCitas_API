$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
docker build --target tests -t restaurant-api-tests:local .
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kind load docker-image restaurant-api-tests:local --name restaurant-api
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api delete job medical-integration -n restaurant-api --ignore-not-found
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
kubectl --context kind-restaurant-api apply -f k8s/tests/medical-integration-job.yaml
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$deadline = (Get-Date).AddSeconds(300)
$result = 1
while ($true) {
    $jobJson = kubectl --context kind-restaurant-api get job medical-integration -n restaurant-api -o json
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $job = $jobJson | ConvertFrom-Json
    if (@($job.status.conditions) | Where-Object { $_.type -eq "Complete" -and $_.status -eq "True" }) {
        $result = 0
        break
    }
    if (@($job.status.conditions) | Where-Object { $_.type -eq "Failed" -and $_.status -eq "True" }) {
        Write-Host "El Job de pruebas fallo."
        break
    }
    if ((Get-Date) -ge $deadline) {
        Write-Host "Se agoto el tiempo de espera del Job de pruebas."
        break
    }
    Start-Sleep -Seconds 2
}
kubectl --context kind-restaurant-api logs -n restaurant-api job/medical-integration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit $result
