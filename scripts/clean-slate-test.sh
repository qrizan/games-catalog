#!/usr/bin/env bash
# clean-slate test: k8s/ + compose/, cleanup dulu lalu provisioning sequential
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"
NODE=games-catalog-control-plane

# Log ditulis ke .partial dulu dan baru menggantikan output.txt kalau run selesai sukses. 
# Tanpa ini, run yang gagal di tengah menimpa bukti run terakhir yang baik.
# absolut: langkah 9 cd ke compose/ dan tidak kembali, path relatif membuat mv di trap salah alamat
OUTPUT_LOG_FINAL="$REPO_ROOT/scripts/output.txt"
OUTPUT_LOG="$REPO_ROOT/scripts/output.txt.partial"
DOCKER_CONFIG_JSON="$HOME/.docker/config.json"

# --- preflight ---------------------------------------------------------------
# seluruhnya dijalankan sebelum langkah destruktif mana pun dan sebelum output dialihkan. 
# konsekuensinya disengaja: kalau prasyarat kurang, cluster lama tetap utuh dan output.txt run sebelumnya tidak tertimpa.
MISSING=()
for bin in kind kubectl helm docker jq sed tee curl timeout k6; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    MISSING+=("$bin")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "GAGAL: perintah tidak ditemukan: ${MISSING[*]}"
  exit 1
fi
if [[ ! -f compose/.env ]]; then
  echo "GAGAL: compose/.env tidak ada, salin dari compose/.env.example lalu isi nilainya"
  exit 1
fi
set -a; source compose/.env; set +a
if [[ ! -f "$DOCKER_CONFIG_JSON" ]]; then
  echo "GAGAL: $DOCKER_CONFIG_JSON tidak ada, jalankan 'docker login ghcr.io' dulu"
  exit 1
fi
# -e: jq keluar non-zero kalau hasilnya null, jadi key yang tidak ada ikut tertangkap
GHCR_AUTH=$(jq -er '.auths["ghcr.io"].auth' "$DOCKER_CONFIG_JSON") \
  || { echo "GAGAL: entri auth ghcr.io tidak ada di $DOCKER_CONFIG_JSON, jalankan 'docker login ghcr.io' dulu"; exit 1; }

# kind membuat docker network-nya dengan --ipv6 walau ipFamily di config ipv4
# (kubernetes-sigs/kind#2496). Di host tanpa default route IPv6, node jadi punya
# alamat IPv6 tapi tidak bisa keluar: registry.k8s.io punya A dan AAAA sekaligus,
# containerd sesekali menempuh AAAA lalu mati "network is unreachable" di tengah
# pull. Racy, jadi bisa lolos beberapa run sebelum muncul.
if ! ip -6 route show default | grep -q .; then
  if docker network inspect kind >/dev/null 2>&1 \
     && [[ "$(docker network inspect kind -f '{{.EnableIPv6}}')" == "true" ]]; then
    echo "GAGAL: host tidak punya default route IPv6, tapi docker network 'kind' IPv6-nya aktif."
    echo "       Pull dari registry.k8s.io akan gagal acak di tengah jalan. Perbaiki dulu:"
    echo "         kind delete cluster --name games-catalog"
    echo "         docker network rm kind"
    echo "         docker network create kind"
    exit 1
  fi
fi

# --- redact log --------------------------------------------------------------
# Seluruh output disalin ke scripts/output.txt sebagai bukti yang ikut di-commit.
# Nilai rahasia disamarkan dari cara tulisnya, bukan disunting setelahnya:
# "garage bucket website" mencetak access key bucket ke stdout dengan sendirinya.
#
# Daftar variabel dibaca dari compose/.env, tidak diketik ulang di sini. Daftar
# manual berarti secret baru di .env diam-diam lolos sampai ada yang ingat
# menambahkannya; dibaca langsung, kelas kesalahan itu tidak ada.
mapfile -t REDACT_VARS < <(sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' compose/.env)
REDACT_VARS+=(GHCR_AUTH)   # bukan dari .env, dibaca dari config docker di preflight
if [[ ${#REDACT_VARS[@]} -lt 2 ]]; then
  echo "GAGAL: tidak ada variabel terbaca dari compose/.env, redact log tidak bisa dijamin"
  exit 1
fi
REDACT_ARGS=()
REDACT_COUNT=0   # dihitung terpisah: tiap nilai menyumbang dua elemen ke REDACT_ARGS
SKIPPED_VARS=()
for v in "${REDACT_VARS[@]}"; do
  val="${!v:-}"
  # nilai <8 karakter dilewati: sependek itu ikut cocok sebagai substring nama
  # host/resource dan akan merusak log tanpa menutup rahasia apa pun
  if [[ ${#val} -lt 8 ]]; then
    SKIPPED_VARS+=("$v")
  fi
  if [[ ${#val} -ge 8 ]]; then
    REDACT_COUNT=$((REDACT_COUNT + 1))
    # metachar BRE di-escape dulu; tanpa ini nilai ber-"." atau "*" jadi wildcard
    # (over-redact) dan yang ber-"[" gagal cocok sama sekali (under-redact)
    esc=$(printf '%s' "$val" | sed 's/[][\.*^$|]/\\&/g')
    REDACT_ARGS+=(-e "s|${esc}|<REDACTED:${v}>|g")
  fi
done
# sed -u supaya baris diteruskan saat itu juga, bukan menunggu buffer penuh
if [[ ${#REDACT_ARGS[@]} -gt 0 ]]; then
  exec > >(sed -u "${REDACT_ARGS[@]}" | tee "$OUTPUT_LOG") 2>&1
else
  exec > >(tee "$OUTPUT_LOG") 2>&1
fi

finish() {
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    # rename dalam filesystem yang sama: fd yang sedang terbuka ikut pindah inode,
    # jadi baris apa pun setelah ini tetap masuk ke file yang benar
    mv -f "$OUTPUT_LOG" "$OUTPUT_LOG_FINAL"
  else
    echo "GAGAL: run berhenti dengan exit $rc. Log run ini ada di $OUTPUT_LOG;"
    echo "       $OUTPUT_LOG_FINAL dari run sukses terakhir tidak diubah."
  fi
}
trap finish EXIT

echo "### 0. preflight ###"
echo "OK: kind, kubectl, helm, docker, jq, sed, tee, curl, timeout, k6 tersedia"
echo "OK: compose/.env terbaca, kredensial ghcr.io ditemukan"
echo "OK: $REDACT_COUNT nilai disamarkan di log ini"
echo "CATATAN: ${SKIPPED_VARS[*]:-tidak ada} dilewati karena <8 karakter, nilainya akan tampil apa adanya"

echo "### 1. cleanup ###"
# hapus cluster, stack compose, image yang di-pin — supaya langkah 3/9 pull dari registry, bukan cache lokal
kind delete cluster --name games-catalog || true
(cd compose && docker compose down -v) || true
for img in \
  "ghcr.io/qrizan/nestjs-swagger-prisma:0.0.2@sha256:5d4e2db57864f8ab0da3523333bf16e84cafcb10daa36ebcb4c869f95a4b0640" \
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
# allocatable node: dasar maxReplicas HPA di values.yaml
kubectl get node "$NODE" -o custom-columns=NODE:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory

echo "### 3. pre-pull image ke node, sequential ###"
# GHCR_AUTH sudah dibaca di preflight supaya ikut daftar redact log
declare -A IMAGES=(
  [ingress-controller]="registry.k8s.io/ingress-nginx/controller:v1.15.1@sha256:594ceea76b01c592858f803f9ff4d2cb40542cae2060410b2c95f75907d659e1"
  [webhook-certgen]="registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.9@sha256:01038e7de14b78d702d2849c3aad72fd25903c4765af63cf16aa3398f5d5f2dd"
  [metrics-server]="registry.k8s.io/metrics-server/metrics-server:v0.9.0@sha256:25d291fde59974547bac6f07fa9d6cf6f5bedd1f19d60c893311c5e741e0a42f"
  [postgres]="postgres:18-alpine@sha256:9a8afca54e7861fd90fab5fdf4c42477a6b1cb7d293595148e674e0a3181de15"
  [api]="ghcr.io/qrizan/nestjs-swagger-prisma:0.0.2@sha256:5d4e2db57864f8ab0da3523333bf16e84cafcb10daa36ebcb4c869f95a4b0640"
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
kubectl apply -f k8s/namespace.yaml   # PSA restricted, harus sebelum Pod apa pun dibuat di default
# create+apply, bukan create polos: create polos gagal AlreadyExists kalau
# langkah ini pernah dijalankan ulang terhadap cluster yang sudah hidup
kubectl create secret docker-registry ghcr-pull-secret \
  --from-file=.dockerconfigjson="$DOCKER_CONFIG_JSON" -n default \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/ingress-nginx/deploy.yaml
kubectl apply -f k8s/network-policies/
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

echo "### 5. secret Postgres + JWT + Garage + Grafana ###"
# compose/.env sudah di-source di kepala skrip untuk keperluan redact log
kubectl create secret generic postgres-credentials -n default \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic api-secrets -n default \
  --from-literal=JWT_SECRET="$JWT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic garage-credentials -n default \
  --from-literal=GARAGE_RPC_SECRET="$GARAGE_RPC_SECRET" \
  --from-literal=GARAGE_ADMIN_TOKEN="$GARAGE_ADMIN_TOKEN" \
  --from-literal=GARAGE_DEFAULT_ACCESS_KEY="$GARAGE_DEFAULT_ACCESS_KEY" \
  --from-literal=GARAGE_DEFAULT_SECRET_KEY="$GARAGE_DEFAULT_SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic grafana-credentials -n default \
  --from-literal=GF_SECURITY_ADMIN_USER="$GF_SECURITY_ADMIN_USER" \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD="$GF_SECURITY_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

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
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url") || code=000
    [[ "$code" == "200" ]] && break
    sleep 3
  done
  if [[ "$code" != "200" ]]; then
    echo "GAGAL: $url -> $code (harus 200)"
    exit 1
  fi
  echo "OK: $url -> $code"
done
# tidak ada index.html di bucket, jadi 404 yang diharapkan di root
code=000
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "assets.localhost/") || code=000
  [[ "$code" == "404" ]] && break
  sleep 3
done
if [[ "$code" != "404" ]]; then
  echo "GAGAL: assets.localhost/ -> $code (harus 404, tidak ada index.html)"
  exit 1
fi
echo "OK: assets.localhost/ -> $code (tidak ada index.html)"

# Avatar default diunggah saat registrasi pertama, bukan saat start. Registrasi di sini
# yang memicunya, lalu pengambilan lewat website endpoint membuktikan jalur tulis
# api -> garage dan jalur baca browser -> garage sama-sama hidup.
code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "admin.localhost/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"cleanslate\",\"email\":\"cleanslate-$(date +%s)@example.com\",\"password\":\"CleanSlate123!\"}") || code=000
if [[ "$code" != "2"* ]]; then
  echo "GAGAL: register -> $code (harus 2xx)"
  exit 1
fi
echo "OK: register -> $code"

code=000
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "assets.localhost/avatar/default.png") || code=000
  [[ "$code" == "200" ]] && break
  sleep 3
done
if [[ "$code" != "200" ]]; then
  echo "GAGAL: assets.localhost/avatar/default.png -> $code (harus 200)"
  exit 1
fi
echo "OK: assets.localhost/avatar/default.png -> $code"

echo "### 8. metrics-server ###"
# prasyarat HPA - api-hpa.yaml butuh ini untuk baca metrik CPU pod
# pin ke v0.9.0 (sama dengan image yang di-pre-pull), bukan "latest" — hindari drift versi antara pre-pull dan manifest
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
# "op":"add" ke args/- menambah tanpa syarat, jadi patch dua kali menumpuk flag.
# Dijaga dengan pengecekan lebih dulu supaya langkah ini aman diulang.
if kubectl get deployment metrics-server -n kube-system \
     -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  echo "OK: metrics-server sudah punya --kubelet-insecure-tls, patch dilewati"
else
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
ok=1
expected=$(kubectl get pods -n default --no-headers | wc -l) || { echo "GAGAL: kubectl get pods gagal, tidak bisa hitung jumlah pod"; exit 1; }
got=0
for i in $(seq 1 15); do   # retry: metrics-server perlu satu siklus scrape kubelet dulu per pod
  got=$(kubectl top pods -n default --no-headers 2>/dev/null | wc -l) || got=0
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

echo "### 8b. load test k6 + respons HPA ###"
kubectl get hpa api -n default
k6 run k8s/k6/load-test.js   # threshold http_req_failed<1% jadi gate lewat set -e
kubectl get hpa api -n default   # scale-down stabilization 300s, puncak masih terbaca di sini
replicas=$(kubectl get deployment api -n default -o jsonpath='{.status.replicas}') || { echo "GAGAL: kubectl get deployment api gagal"; exit 1; }
if [[ "$replicas" -le 1 ]]; then
  echo "GAGAL: replica api tetap $replicas setelah beban, HPA tidak merespons"
  exit 1
fi
echo "OK: replica api $replicas setelah beban"

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
  state=$(docker inspect -f '{{.State.Status}}' "$cname") || { echo "GAGAL: docker inspect $cname gagal (container mungkin tidak ada)"; exit 1; }
  if [[ "$state" != "running" ]]; then
    echo "GAGAL: $svc state=$state (harus running)"
    exit 1
  fi
  if [[ -n "${EXPECT_HEALTHY[$svc]:-}" ]]; then
    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cname") || { echo "GAGAL: docker inspect $cname gagal saat cek health"; exit 1; }
    if [[ "$health" != "healthy" ]]; then
      echo "GAGAL: $svc health=$health (harus healthy)"
      exit 1
    fi
    echo "OK: $svc running, healthy"
  else
    echo "OK: $svc running"
  fi
done
mstate=$(docker inspect -f '{{.State.Status}}' compose-migrate-1) || { echo "GAGAL: docker inspect compose-migrate-1 gagal"; exit 1; }
mexit=$(docker inspect -f '{{.State.ExitCode}}' compose-migrate-1) || { echo "GAGAL: docker inspect compose-migrate-1 gagal saat cek exit code"; exit 1; }
if [[ "$mstate" != "exited" || "$mexit" != "0" ]]; then
  echo "GAGAL: migrate state=$mstate exitcode=$mexit (harus exited/0)"
  exit 1
fi
echo "OK: migrate exited 0"

echo "### 9d. verifikasi endpoint ###"
for url in "admin.localhost:8080/" "admin.localhost:8080/api/health/ready" "catalog.localhost:8080/" "catalog.localhost:8080/api/health/ready"; do
  code=000
  for i in $(seq 1 10); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url") || code=000
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
  code=$(curl -s -o /dev/null -w "%{http_code}" "assets.localhost:8080/") || code=000
  [[ "$code" == "404" ]] && break
  sleep 2
done
if [[ "$code" != "404" ]]; then
  echo "GAGAL: assets.localhost:8080/ -> $code (harus 404, tidak ada index.html)"
  exit 1
fi
echo "OK: assets.localhost:8080/ -> $code (tidak ada index.html)"

code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "admin.localhost:8080/api/auth/register" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"cleanslate\",\"email\":\"cleanslate-$(date +%s)@example.com\",\"password\":\"CleanSlate123!\"}") || code=000
if [[ "$code" != "2"* ]]; then
  echo "GAGAL: register -> $code (harus 2xx)"
  exit 1
fi
echo "OK: register -> $code"

code=000
for i in $(seq 1 10); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "assets.localhost:8080/avatar/default.png") || code=000
  [[ "$code" == "200" ]] && break
  sleep 2
done
if [[ "$code" != "200" ]]; then
  echo "GAGAL: assets.localhost:8080/avatar/default.png -> $code (harus 200)"
  exit 1
fi
echo "OK: assets.localhost:8080/avatar/default.png -> $code"

echo "### compose selesai, semua service terkonfirmasi ###"
