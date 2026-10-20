#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

kubectl --context kind-restaurant-api -n restaurant-api create configmap k6-scripts \
  --from-file=integration.js=tests/k6/integration.js \
  --from-file=persistence-create.js=tests/k6/persistence-create.js \
  --from-file=persistence-verify.js=tests/k6/persistence-verify.js \
  --dry-run=client -o yaml | kubectl --context kind-restaurant-api apply -f -

kubectl --context kind-restaurant-api delete job k6-integration -n restaurant-api --ignore-not-found
kubectl --context kind-restaurant-api apply -f k8s/tests/k6-integration-job.yaml
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=complete job/k6-integration --timeout=240s
kubectl --context kind-restaurant-api logs -n restaurant-api job/k6-integration
