# Running

Cara menjalankan stack ini di dua target: Compose untuk development, dan cluster kind untuk Kubernetes. Bentuk sistemnya dijelaskan di [ARCHITECTURE.md](ARCHITECTURE.md), alasan tiap pilihan di [DECISION.md](DECISION.md), dan hasil pengukurannya di [RESULTS.md](RESULTS.md).

## Prasyarat

| Yang dijalankan | Yang harus ada |
|---|---|
| Compose stack | `docker` dengan plugin `compose` |
| Kubernetes di kind | `kind`, `kubectl`, `helm`, `docker` |
| Load test terpisah | `k6` |
| Skrip clean-slate | kesepuluh binary yang dicek preflight-nya: `kind`, `kubectl`, `helm`, `docker`, `jq`, `sed`, `tee`, `curl`, `timeout`, `k6` |

Kedua target menarik image aplikasi dari GHCR. Repo image-nya private, jadi `docker login ghcr.io` harus sudah pernah dijalankan dan entrinya ada di `~/.docker/config.json`.

Nilai konfigurasi keduanya berasal dari satu file, `compose/.env`, yang tidak ikut di repo:

```bash
cp compose/.env.example compose/.env    # isi dulu nilai yang kosong
```

## Development stack

```bash
cd compose
docker compose up -d
docker compose exec garage /garage bucket website --allow assets
```

Bisa diakses di `admin.localhost:8080`, `catalog.localhost:8080`, dan `assets.localhost:8080`. `*.localhost` resolve ke loopback di browser dan curl tanpa entri di hosts file ([RFC 6761](https://www.rfc-editor.org/rfc/rfc6761)).

Perintah Garage di atas adalah langkah sekali jalan setiap volume dibuat ulang, dan tidak bisa digabungkan ke `docker compose up`. Alasannya ada di [DECISION.md](DECISION.md).

## Kubernetes di kind

### 1. Cluster dan resource bootstrap

```bash
kind create cluster --config k8s/kind-config.yaml

kubectl apply -f k8s/namespace.yaml
kubectl create secret docker-registry ghcr-pull-secret \
  --from-file=.dockerconfigjson="$HOME/.docker/config.json" -n default
kubectl apply -f k8s/ingress-nginx/deploy.yaml
kubectl apply -f k8s/network-policies/
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s
```

`k8s/namespace.yaml` memasang label Pod Security Admission `restricted` pada namespace, dan di-apply sebelum Pod mana pun dibuat.

### 2. Secret

Keempatnya dibuat imperatif dari `compose/.env` yang sama. Tidak ada manifest Secret berisi nilai asli yang ikut di-commit.

```bash
set -a && . compose/.env && set +a

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
```

### 3. Instalasi chart, dua tahap

Instalasi pertama ke cluster kosong berjalan dua tahap, karena hook migrasi akan jalan sebelum PostgreSQL ada. Mekanismenya di [ARCHITECTURE.md](ARCHITECTURE.md#4-deployment-lifecycle).

```bash
helm upgrade --install games-catalog k8s/chart -n default --set bootstrapOnly=true
kubectl wait --for=condition=Ready pod/postgres-0 -n default --timeout=180s

helm upgrade games-catalog k8s/chart -n default --set bootstrapOnly=false
kubectl exec garage-0 -n default -- /garage bucket website --allow assets
```

`--set` dari revisi sebelumnya terbawa ke `helm upgrade` yang tidak menyebutkannya, jadi tahap kedua wajib menulis `bootstrapOnly=false` secara eksplisit.

Rilis berikutnya cukup satu `helm upgrade`. NetworkPolicy berada di luar chart dan di-apply terpisah setiap kali berubah.

### 4. metrics-server

HPA membaca CPU dari metrics-server, yang tidak disertakan kind dan tidak dipasang chart. Tanpa langkah ini HPA tetap terbentuk tapi utilisasinya `<unknown>` dan tidak akan pernah scale:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.9.0/components.yaml
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
```

Patch itu diperlukan karena sertifikat kubelet di kind self-signed dan tidak dipercaya metrics-server.

### 5. Endpoint

| Host | Isi |
|---|---|
| `admin.localhost` | dashboard admin, dan API di `/api` |
| `catalog.localhost` | katalog publik, dan API di `/api` |
| `grafana.localhost` | Grafana |
| `assets.localhost` | website endpoint object storage |

## Membangun ulang dari nol

Urutan di atas adalah prosedur deploy yang dijalankan operator. [`scripts/clean-slate-test.sh`](scripts/clean-slate-test.sh) menjalankan urutan yang sama ditambah penghapusan total di awal, pre-pull image, asersi di tiap tahap, dan load test yang mengukur respons autoscaler.

Keduanya sengaja tidak digabung: yang satu untuk memakai, yang satu untuk membuktikan semuanya bisa dibangun ulang dari nol. Apa yang di-assert skrip itu dan angka yang dihasilkannya ada di [RESULTS.md](RESULTS.md).
