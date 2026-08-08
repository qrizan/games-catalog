#!/usr/bin/env bash
# clean-slate test: k8s/ + compose/, cleanup dulu lalu provisioning sequential
set -euo pipefail
cd "$(dirname "$0")/.."
NODE=games-catalog-control-plane

echo "### 1. cleanup ###"
kind delete cluster --name games-catalog || true
(cd compose && docker compose down -v) || true
for img in \
  "ghcr.io/qrizan/nestjs-swagger-prisma:0.0.1-rc.4@sha256:c61d246641e8a8cf7401dbce370c25c0c9047bce2dd303a8b05f90eb557f0870" \
  "ghcr.io/qrizan/react-shadcn-redux:0.0.1-rc.2@sha256:b456481cb65f1e2d6b066194f8db7f01663a334e0e17faad18c1411ca76f0985" \
  "ghcr.io/qrizan/nextjs-chakra-reactquery:0.0.1-rc.4@sha256:300b04d4792603c857a05fe2cfcbe6ddecb5afa36f9cf362b663e24921d829d8" \
  "postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15" \
  "nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de"; do
  docker rmi "$img" 2>/dev/null || true
done

echo "### 2. cluster kind ###"
kind create cluster --config k8s/kind-config.yaml
kubectl config current-context
kubectl cluster-info --context kind-games-catalog

echo "### 3. pre-pull image ke node, sequential ###"
GHCR_AUTH=$(jq -r '.auths["ghcr.io"].auth' "$HOME/.docker/config.json")
declare -A IMAGES=(
  [ingress-controller]="registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1"
  [webhook-certgen]="registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9@sha256:01038e7de14b78d702d2849c3aad72fd25903c4765af63cf16aa3398f5d5f2dd"
  [metrics-server]="registry.k8s.io/metrics-server/metrics-server:v0.9.0"
  [postgres]="postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
  [api]="ghcr.io/qrizan/nestjs-swagger-prisma:0.0.1-rc.4@sha256:c61d246641e8a8cf7401dbce370c25c0c9047bce2dd303a8b05f90eb557f0870"
  [admin]="ghcr.io/qrizan/react-shadcn-redux:0.0.1-rc.2@sha256:b456481cb65f1e2d6b066194f8db7f01663a334e0e17faad18c1411ca76f0985"
  [public]="ghcr.io/qrizan/nextjs-chakra-reactquery:0.0.1-rc.4@sha256:300b04d4792603c857a05fe2cfcbe6ddecb5afa36f9cf362b663e24921d829d8"
)
ORDER=(ingress-controller webhook-certgen metrics-server postgres api admin public)
for name in "${ORDER[@]}"; do
  img="${IMAGES[$name]}"
  echo "--- pull: $name ---"
  start=$(date +%s)
  ok=0
  if [[ "$img" == ghcr.io/* ]]; then
    timeout 1200 docker exec "$NODE" crictl pull --auth "$GHCR_AUTH" "$img" || ok=$?  # registry privat
  else
    timeout 1200 docker exec "$NODE" crictl pull "$img" || ok=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  if [[ "$ok" -ne 0 ]]; then
    echo "GAGAL: $name setelah ${elapsed}s (exit $ok)"
    exit 1
  fi
  echo "OK: $name (${elapsed}s)"
done

echo "### 4. imagePullSecrets, ingress-nginx, NetworkPolicy ###"
kubectl create secret docker-registry ghcr-pull-secret \
  --from-file=.dockerconfigjson="$HOME/.docker/config.json" -n default   # $HOME, bukan ~
kubectl apply -f k8s/ingress-nginx/deploy.yaml
kubectl apply -f k8s/network-policies/
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

echo "### 5. secret Postgres + JWT ###"
set -a; source compose/.env; set +a
kubectl create secret generic postgres-credentials -n default \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB"
kubectl create secret generic api-secrets -n default \
  --from-literal=JWT_SECRET="$JWT_SECRET"

echo "### 6. helm bootstrap dua tahap ###"
helm upgrade --install games-catalog k8s/chart --namespace default --set bootstrapOnly=true
kubectl wait --for=condition=Ready pod/postgres-0 -n default --timeout=180s
kubectl exec postgres-0 -n default -- pg_isready

helm upgrade games-catalog k8s/chart --namespace default --set bootstrapOnly=false --timeout 5m   # eksplisit, tidak reset otomatis
helm get values games-catalog -n default   # harus: bootstrapOnly: false

echo "### 7. verifikasi ###"
kubectl rollout status deployment/api -n default --timeout=120s
kubectl rollout status deployment/admin -n default --timeout=120s
kubectl rollout status deployment/public -n default --timeout=120s
kubectl get pods,hpa,ingress -n default
for url in "admin.localhost/" "admin.localhost/api/health/ready" "catalog.localhost/" "catalog.localhost/api/health/ready"; do
  code=000
  for i in $(seq 1 10); do   # retry: ingress-nginx sync lag setelah endpoint baru Ready
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [[ "$code" == "200" ]] && break
    sleep 3
  done
  echo "$url -> $code"
done

echo "### 8. metrics-server ###"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
sleep 30
kubectl top pods -n default

echo "### k8s selesai. k6 manual: k6 run k8s/k6/load-test.js"
echo "### buka 'kubectl get hpa api -n default -w' dulu di terminal lain ###"

echo "### 9. compose/ ###"
cd compose
time docker compose pull
time docker compose up -d
docker compose ps
for url in "admin.localhost:8080/" "admin.localhost:8080/api/health/ready" "catalog.localhost:8080/" "catalog.localhost:8080/api/health/ready"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
  echo "$url -> $code"
done
echo "### compose selesai ###"
