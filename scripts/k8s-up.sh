#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."

cluster="restaurant-api"
secret_file="k8s/overlays/local/secrets.env"
secret_example="k8s/overlays/local/secrets.env.example"

# Si no existe secrets.env se crea desde la plantilla. La plantilla trae valores de
# desarrollo validos; se recomienda cambiarlos para ambientes compartidos.
if [ ! -f "$secret_file" ]; then
  cp "$secret_example" "$secret_file"
  echo "Se creo $secret_file desde el ejemplo."
fi

docker build -t restaurant-api:local .
if ! kind get clusters | grep -qx "$cluster"; then
  kind create cluster --name "$cluster" --config k8s/overlays/local/kind-config.yaml
fi
kind load docker-image restaurant-api:local --name "$cluster"
kubectl --context kind-restaurant-api apply -k k8s/overlays/local
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=available deployment/postgres --timeout=180s
kubectl --context kind-restaurant-api wait -n restaurant-api --for=condition=available deployment/keycloak --timeout=300s
kubectl --context kind-restaurant-api rollout restart deployment/restaurant-api -n restaurant-api
kubectl --context kind-restaurant-api rollout status deployment/restaurant-api -n restaurant-api --timeout=180s
kubectl --context kind-restaurant-api get pods -n restaurant-api
echo "API disponible en http://localhost:8081"
