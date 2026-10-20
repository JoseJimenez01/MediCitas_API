#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
docker build --target tests -t restaurant-api-tests:local .
kind load docker-image restaurant-api-tests:local --name restaurant-api
kubectl --context kind-restaurant-api delete job medical-integration -n restaurant-api --ignore-not-found
kubectl --context kind-restaurant-api apply -f k8s/tests/medical-integration-job.yaml
deadline=$(( $(date +%s) + 300 ))
result=1
while :; do
    conditions=$(kubectl --context kind-restaurant-api get job medical-integration -n restaurant-api -o 'jsonpath={range .status.conditions[*]}{.type}={.status}{"\n"}{end}')
    case "$conditions" in
        *Complete=True*) result=0; break ;;
        *Failed=True*) printf '%s\n' 'El Job de pruebas fallo.'; break ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
        printf '%s\n' 'Se agoto el tiempo de espera del Job de pruebas.'
        break
    fi
    sleep 2
done
kubectl --context kind-restaurant-api logs -n restaurant-api job/medical-integration
exit "$result"
