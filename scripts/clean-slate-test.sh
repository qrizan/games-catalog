#!/usr/bin/env bash
# clean-slate test: k8s/ + compose/, cleanup dulu lalu provisioning sequential
set -euo pipefail
cd "$(dirname "$0")/.."
NODE=games-catalog-control-plane

echo "### 1. cleanup ###"
# hapus cluster, stack compose, image yang di-pin — supaya langkah 3/9 pull dari registry, bukan cache lokal
kind delete cluster --name games-catalog || true
(cd compose && docker compose down -v) || true
for img in \
  "ghcr.io/qrizan/nestjs-swagger-prisma:0.0.1-rc.4@sha256:c61d246641e8a8cf7401dbce370c25c0c9047bce2dd303a8b05f90eb557f0870" \
  "ghcr.io/qrizan/react-shadcn-redux:0.0.1-rc.2@sha256:b456481cb65f1e2d6b066194f8db7f01663a334e0e17faad18c1411ca76f0985" \
  "ghcr.io/qrizan/nextjs-chakra-reactquery:0.0.1-rc.4@sha256:300b04d4792603c857a05fe2cfcbe6ddecb5afa36f9cf362b663e24921d829d8" \
  "postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15" \
  "nginx:1.29-alpine@sha256:5616878291a2eed594aee8db4dade5878cf7edcb475e59193904b198d9b830de" \
  "dxflrs/garage:v2.3.0@sha256:866bd13ed2038ba7e7190e840482bc27234c4afaf77be8cfa439ae088c1e4690"; do
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
  [metrics-server]="registry.k8s.io/metrics-server/metrics-server:v0.9.0@sha256:25d291fde59974547bac6f07fa9d6cf6f5bedd1f19d60c893311c5e741e0a42f"
  [postgres]="postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
  [api]="ghcr.io/qrizan/nestjs-swagger-prisma:0.0.1-rc.4@sha256:c61d246641e8a8cf7401dbce370c25c0c9047bce2dd303a8b05f90eb557f0870"
  [admin]="ghcr.io/qrizan/react-shadcn-redux:0.0.1-rc.2@sha256:b456481cb65f1e2d6b066194f8db7f01663a334e0e17faad18c1411ca76f0985"
  [public]="ghcr.io/qrizan/nextjs-chakra-reactquery:0.0.1-rc.4@sha256:300b04d4792603c857a05fe2cfcbe6ddecb5afa36f9cf362b663e24921d829d8"
  [garage]="dxflrs/garage:v2.3.0@sha256:866bd13ed2038ba7e7190e840482bc27234c4afaf77be8cfa439ae088c1e4690"
  [prometheus]="prom/prometheus:v3.13.2@sha256:508729e0e2d18e11fd742a5a5ca70e557b940a93948c3c95fd0123a6fd538b69"
  [grafana]="grafana/grafana:13.1.3@sha256:ab5cb380e3ff3172d6c8bd2e7cfd31cce977d2881b260e1f5bc089bf0b759b43"
)
ORDER=(ingress-controller webhook-certgen metrics-server postgres api admin public garage prometheus grafana)
for name in "${ORDER[@]}"; do
  img="${IMAGES[$name]}"
  echo "--- pull: $name ---"
  start=$(date +%s)
  ok=0
  if [[ "$img" == ghcr.io/* ]]; then
    timeout 3600 docker exec "$NODE" crictl pull --auth "$GHCR_AUTH" "$img" || ok=$?  # registry privat
  else
    timeout 3600 docker exec "$NODE" crictl pull "$img" || ok=$?
  fi
  elapsed=$(( $(date +%s) - start ))
  if [[ "$ok" -ne 0 ]]; then
    echo "GAGAL: $name setelah ${elapsed}s (exit $ok)"
    exit 1
  fi
  echo "OK: $name (${elapsed}s)"
done

echo "### 4. namespace PSA, imagePullSecrets, ingress-nginx, NetworkPolicy ###"
kubectl apply -f k8s/namespace.yaml   # S-26: PSA restricted, harus sebelum Pod apa pun dibuat di default
kubectl create secret docker-registry ghcr-pull-secret \
  --from-file=.dockerconfigjson="$HOME/.docker/config.json" -n default   # $HOME, bukan ~
kubectl apply -f k8s/ingress-nginx/deploy.yaml
kubectl apply -f k8s/network-policies/
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

echo "### 5. secret Postgres + JWT + Garage + Grafana ###"
set -a; source compose/.env; set +a
kubectl create secret generic postgres-credentials -n default \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB"
kubectl create secret generic api-secrets -n default \
  --from-literal=JWT_SECRET="$JWT_SECRET"
kubectl create secret generic garage-credentials -n default \
  --from-literal=GARAGE_RPC_SECRET="$GARAGE_RPC_SECRET" \
  --from-literal=GARAGE_ADMIN_TOKEN="$GARAGE_ADMIN_TOKEN" \
  --from-literal=GARAGE_DEFAULT_ACCESS_KEY="$GARAGE_DEFAULT_ACCESS_KEY" \
  --from-literal=GARAGE_DEFAULT_SECRET_KEY="$GARAGE_DEFAULT_SECRET_KEY"
kubectl create secret generic grafana-credentials -n default \
  --from-literal=GF_SECURITY_ADMIN_USER="$GF_SECURITY_ADMIN_USER" \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="$GF_SECURITY_ADMIN_PASSWORD"

echo "### 6. helm bootstrap dua tahap ###"
# tahap 1: install postgres saja. tahap 2: upgrade sisanya — migrate jadi hook pre-upgrade,
# bukan pre-install, supaya postgres sudah nyata ada saat migrate jalan
helm upgrade --install games-catalog k8s/chart --namespace default --set bootstrapOnly=true
kubectl wait --for=condition=Ready pod/postgres-0 -n default --timeout=180s
kubectl exec postgres-0 -n default -- pg_isready

helm upgrade games-catalog k8s/chart --namespace default --set bootstrapOnly=false --timeout 5m   # eksplisit, tidak reset otomatis
helm get values games-catalog -n default   # harus: bootstrapOnly: false

echo "### 6b. bootstrap manual Garage: aktifkan website endpoint bucket assets ###"
kubectl wait --for=condition=Ready pod/garage-0 -n default --timeout=180s
kubectl exec garage-0 -n default -- /garage bucket website --allow assets

echo "### 7. verifikasi ###"
# semua Deployment harus rollout sukses, semua endpoint HTTP harus 200
kubectl rollout status deployment/api -n default --timeout=120s
kubectl rollout status deployment/admin -n default --timeout=120s
kubectl rollout status deployment/public -n default --timeout=120s
kubectl rollout status deployment/grafana -n default --timeout=180s   # startupProbe budget 120s, beri margin
kubectl rollout status deployment/prometheus -n default --timeout=120s
kubectl get pods,hpa,ingress -n default
for url in "admin.localhost/" "admin.localhost/api/health/ready" "catalog.localhost/" "catalog.localhost/api/health/ready" "grafana.localhost/api/health"; do
  code=000
  for i in $(seq 1 10); do   # retry: ingress-nginx sync lag setelah endpoint baru Ready
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [[ "$code" == "200" ]] && break
    sleep 3
  done
  if [[ "$code" != "200" ]]; then
    echo "GAGAL: $url -> $code (harus 200)"
    exit 1
  fi
  echo "OK: $url -> $code"
done
# bucket assets kosong sehabis clean-slate, jadi 404 yang diharapkan
code=000
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "assets.localhost/")
  [[ "$code" == "404" ]] && break
  sleep 3
done
if [[ "$code" != "404" ]]; then
  echo "GAGAL: assets.localhost/ -> $code (harus 404, bucket kosong)"
  exit 1
fi
echo "OK: assets.localhost/ -> $code (bucket kosong)"

echo "### 8. metrics-server ###"
# prasyarat HPA — api-hpa.yaml butuh ini untuk baca metrik CPU pod
# pin ke v0.9.0 (sama dengan image yang di-pre-pull), bukan "latest" — hindari drift versi antara pre-pull dan manifest
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
ok=1
expected=$(kubectl get pods -n default --no-headers | wc -l)
got=0
for i in $(seq 1 15); do   # retry: metrics-server perlu satu siklus scrape kubelet dulu per pod
  got=$(kubectl top pods -n default --no-headers 2>/dev/null | wc -l)
  if [[ "$got" -eq "$expected" ]]; then
    ok=0
    break
  fi
  sleep 5
done
if [[ "$ok" -ne 0 ]]; then
  echo "GAGAL: metrics-server hanya mengembalikan $got/$expected pod setelah retry"
  exit 1
fi
kubectl top pods -n default
echo "OK: metrics-server mengembalikan data untuk semua $expected pod"

echo "### k8s selesai. k6 manual: k6 run k8s/k6/load-test.js"
echo "### buka 'kubectl get hpa api -n default -w' dulu di terminal lain ###"

echo "### 9. compose/ ###"
# stack terpisah dari k8s — image sudah dihapus di langkah 1, jadi pull ini juga dari nol
cd compose
time docker compose pull
time docker compose up -d
docker compose ps

echo "### 9b. bootstrap manual Garage: aktifkan website endpoint bucket assets (paritas dengan k8s 6b) ###"
docker compose exec garage /garage bucket website --allow assets

echo "### 9c. verifikasi status container ###"
declare -A EXPECT_HEALTHY=([postgres]=1 [admin]=1 [api]=1 [public]=1 [garage]=1)
for svc in postgres admin api public garage proxy; do
  cname="compose-${svc}-1"
  state=$(docker inspect -f '{{.State.Status}}' "$cname")
  if [[ "$state" != "running" ]]; then
    echo "GAGAL: $svc state=$state (harus running)"
    exit 1
  fi
  if [[ -n "${EXPECT_HEALTHY[$svc]:-}" ]]; then
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cname")
    if [[ "$health" != "healthy" ]]; then
      echo "GAGAL: $svc health=$health (harus healthy)"
      exit 1
    fi
    echo "OK: $svc running, healthy"
  else
    echo "OK: $svc running"
  fi
done
mstate=$(docker inspect -f '{{.State.Status}}' compose-migrate-1)
mexit=$(docker inspect -f '{{.State.ExitCode}}' compose-migrate-1)
if [[ "$mstate" != "exited" || "$mexit" != "0" ]]; then
  echo "GAGAL: migrate state=$mstate exitcode=$mexit (harus exited/0)"
  exit 1
fi
echo "OK: migrate exited 0"

echo "### 9d. verifikasi endpoint ###"
for url in "admin.localhost:8080/" "admin.localhost:8080/api/health/ready" "catalog.localhost:8080/" "catalog.localhost:8080/api/health/ready"; do
  code=000
  for i in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url")
    [[ "$code" == "200" ]] && break
    sleep 2
  done
  if [[ "$code" != "200" ]]; then
    echo "GAGAL: $url -> $code (harus 200)"
    exit 1
  fi
  echo "OK: $url -> $code"
done
code=000
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "assets.localhost:8080/")
  [[ "$code" == "404" ]] && break
  sleep 2
done
if [[ "$code" != "404" ]]; then
  echo "GAGAL: assets.localhost:8080/ -> $code (harus 404, bucket kosong)"
  exit 1
fi
echo "OK: assets.localhost:8080/ -> $code (bucket kosong)"

echo "### compose selesai, semua service terkonfirmasi ###"
