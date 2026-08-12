# Security

Postur keamanan yang benar-benar terpasang di repo ini, beserta yang sengaja tidak dipasang. Ini bukan kebijakan pelaporan kerentanan.

Semua yang ditulis di sini dibaca dari manifest dan workflow yang ada di repo, bukan dari niat. Yang belum terbukti disebut di bagian terakhir, bukan disamarkan.

Tiap angka di dokumen ini bisa dicek sendiri. Kolom terakhir pada tabel dan catatan di bawah tiap bagian menyebut file yang menjadi sumbernya, jadi klaim di sini tidak perlu dipercaya, cukup diperiksa. Peta file selengkapnya di [STRUCTURE.md](STRUCTURE.md).

## Di titik mana tiap kontrol bekerja

Empat waktu kerja yang berbeda, dan itu yang menentukan apa yang bisa dan tidak bisa ditangkap masing-masing. Kolom terakhir yang paling penting: itu alasan kenapa empat lapis ini tidak saling menggantikan.

| Kapan | Kontrolnya | Yang ditangkap | Yang lolos darinya |
|---|---|---|---|
| Sebelum artefak masuk repo ini | Trivy scan, jalankan container lalu assert ia merespons, `cosign verify` dengan identitas signer eksak, konsumsi lewat digest | CVE yang sudah dikenal, image yang tidak bisa start, image dari sumber yang bukan workflow rilis repo itu | CVE yang terbit setelah scan, dan seluruh kesalahan konfigurasi cluster. Image yang bersih tetap berbahaya kalau dijalankan sebagai root |
| Sebelum manifest ter-apply | Pod Security Admission `restricted` mode `enforce`, dan asersi `ci.yml` bahwa chart tidak memuat `kind: Secret` | manifest yang meminta privilege berlebih, dan manifest Secret yang ikut masuk repo | apa pun yang sah secara manifest tapi salah secara nilai, misalnya policy yang membuka port terlalu lebar |
| Selama container berjalan | `runAsNonRoot` dengan UID eksplisit, `drop: [ALL]`, `seccompProfile: RuntimeDefault`, `requests` dan `limits`, `automountServiceAccountToken: false` | eskalasi ke root, penyalahgunaan capability, satu pod menghabiskan resource node, pencurian token ServiceAccount | proses yang sah di dalam container. Kalau aplikasinya sendiri yang punya lubang, lapisan ini hanya membatasi dampaknya |
| Saat paket bergerak | `default-deny-ingress` tingkat namespace, tujuh policy pembuka jalur, dan port S3 yang tidak diberi Ingress | pergerakan lateral antar-pod, dan akses langsung ke database atau permukaan tulis object storage dari luar | seluruh egress, karena tidak ada policy yang membatasinya. Pod yang sudah dikuasai tetap bisa menghubungi apa pun ke luar |

Baris terakhir kolom terakhir adalah celah terbesar yang diketahui, dan sengaja tidak ditutup. Alasannya ada di bagian akhir dokumen ini.

## Supply chain

| Yang dipasang | Bentuknya | Sumber pemeriksaannya |
|---|---|---|
| Image dikonsumsi lewat digest | `repository:tag@sha256:...`. Tag tetap terbaca manusia, digest yang menentukan apa yang ditarik | [`k8s/chart/values.yaml`](k8s/chart/values.yaml), [`compose/docker-compose.yml`](compose/docker-compose.yml) |
| Scan sebelum publish | Trivy jalan sebelum image di-push | workflow rilis di ketiga repo aplikasi |
| Image dijalankan sebelum di-push | Workflow rilis menjalankan container lalu meminta respons darinya | workflow rilis di ketiga repo aplikasi. Dua image API pernah terbit dalam keadaan tidak bisa start dan keduanya lolos build dan scan, jadi gate ini ada karena kejadian, bukan karena teori |
| Signature, SBOM, provenance | `cosign sign` plus SBOM dan provenance attestation pada tiap image | workflow rilis di ketiga repo aplikasi |
| Verifikasi di sisi konsumen | `cosign verify` dengan identitas signer eksak, yaitu URL workflow rilis repo itu ditambah ref tag itu | step verifikasi pada [`.github/workflows/cd.yml`](.github/workflows/cd.yml) |
| Bump digest tidak bisa separuh jalan | Skrip gagal dengan error kalau masih ada digest lama tersisa di file mana pun | [`.github/scripts/bump-image.py`](.github/scripts/bump-image.py), pemeriksaan setelah seluruh penggantian selesai |

Yang membedakan verifikasi di sini dari sekadar mengecek keberadaan signature: keyless signing bisa dipakai siapa saja lewat mekanisme yang sama, jadi pertanyaan "ada signature yang valid" akan dijawab ya oleh image milik orang lain. Mekanismenya di [ARCHITECTURE.md](ARCHITECTURE.md#1-ecosystem), rantainya di [RELEASE.md](RELEASE.md).

## Kubernetes

### Admission

Namespace diberi label Pod Security Admission `restricted` pada mode `enforce`, `audit`, dan `warn` sekaligus, dan di-apply sebelum Pod mana pun dibuat. Manifest yang melanggar ditolak API server, bukan sekadar dicatat.

Sumber: [`k8s/namespace.yaml`](k8s/namespace.yaml).

### Workload

Berlaku untuk kedelapan workload, termasuk kedua container di Job migrasi:

- `runAsNonRoot` dengan UID dan GID eksplisit, bukan mengandalkan default image
- `capabilities: drop: [ALL]`
- `seccompProfile: RuntimeDefault`
- `requests` dan `limits` untuk CPU dan memory di tiap container

UID-nya berbeda-beda karena diambil dari image masing-masing, dicek dulu ke image atau Dockerfile-nya:

| Workload | UID | Sumber nilainya |
|---|---|---|
| `postgres` | 70 | `id postgres` di dalam container image Alpine |
| `admin` | 101 | `Dockerfile` repo admin, base image nginx unprivileged |
| `grafana` | 472 | user default image resmi Grafana, sama dengan default chart komunitasnya |
| `api`, `public`, `garage`, Job migrasi | 1000 | `Dockerfile` kedua repo untuk `api` dan `public`; untuk Garage dipaksa lewat `securityContext` karena image-nya tidak punya user non-root bawaan |
| `prometheus` | 65534 | user `nobody` di image Prometheus, sama dengan default chart komunitasnya |

Yang berlaku di cluster ada di [`k8s/chart/values.yaml`](k8s/chart/values.yaml); kedelapan template yang memakainya ada di [`k8s/chart/templates/`](k8s/chart/templates/).

Angka `postgres` adalah contoh kenapa ini tidak boleh ditebak: image berbasis Alpine memakai 70, sementara image berbasis Debian memakai 999. Menyalin angka dari contoh di internet menghasilkan pod yang tidak bisa menulis ke volumenya sendiri.

### Service account token

`automountServiceAccountToken: false` di tujuh dari delapan workload. Prometheus satu-satunya pengecualian, karena ia butuh API server untuk service discovery pod, dan ClusterRole-nya dibatasi pada `get`, `list`, dan `watch` untuk `pods` saja.

Sumber: `grep -rn automountServiceAccountToken k8s/chart/templates/` menghasilkan tujuh `false` dan dua `true`, keduanya milik Prometheus, yaitu ServiceAccount di [`prometheus-rbac.yaml`](k8s/chart/templates/prometheus-rbac.yaml) dan Deployment-nya.

### Jaringan

Satu NetworkPolicy `default-deny-ingress` tingkat namespace memblokir seluruh ingress ke pod. Tujuh policy lain membuka tepat satu jalur masing-masing:

| Policy | Membuka |
|---|---|
| `admin-allow-ingress` | namespace ingress-nginx ke `admin` |
| `public-allow-ingress` | namespace ingress-nginx ke `public` |
| `garage-allow-ingress` | namespace ingress-nginx ke port website Garage, dan `api` ke port S3 |
| `grafana-allow-ingress` | namespace ingress-nginx ke `grafana` |
| `api-allow-app` | namespace ingress-nginx, `public`, dan `prometheus` ke `api` |
| `postgres-allow-app` | `api` dan Job migrasi ke `postgres` |
| `prometheus-allow-app` | `grafana` ke `prometheus` |

Sumber: kedelapan file di [`k8s/network-policies/`](k8s/network-policies/), satu policy per file. Semuanya berada di luar Helm chart dan di-apply terpisah; konsekuensinya, dan kenapa bentuknya begitu, ada di [DECISION.md](DECISION.md).

Yang perlu dibaca teliti pada tabel di atas: `postgres-allow-app` memakai `matchExpressions` dengan operator `In` atas nilai `api` dan `migrate`, bukan dua rule terpisah, dan `garage-allow-ingress` memuat dua rule dengan port berbeda dalam satu file.

Diagram jalur mana yang terbuka ada di [ARCHITECTURE.md](ARCHITECTURE.md#3-network-isolation).

## Compose

Ketujuh service memakai `cap_drop: ["ALL"]`, `no-new-privileges`, dan `pids_limit`.

Dua service mendapat `cap_add` terbatas, dan keduanya ditemukan lewat crash-loop nyata, bukan dari daftar bawaan:

| Service | `cap_add` | Kenapa |
|---|---|---|
| `postgres` | `CHOWN`, `SETUID`, `SETGID`, `DAC_OVERRIDE`, `FOWNER` | entrypoint image resmi menyiapkan direktori data sebagai root lalu drop privilege |
| `proxy` | `CHOWN`, `SETUID`, `SETGID` | master process meng-chown direktori temp ke uid nginx sebelum fork worker |

Tiga port di-publish ke host. PostgreSQL pada 5432 dan endpoint S3 pada 3900 diikat ke `127.0.0.1` karena hanya dipakai seeding dari host. Port 8080 milik reverse proxy tidak diikat ke loopback karena itu titik masuk browser, jadi stack development terjangkau dari mesin lain di jaringan yang sama.

Sumber seluruh bagian ini: [`compose/docker-compose.yml`](compose/docker-compose.yml). Ketujuh service, ketujuh `cap_drop`, ketujuh `no-new-privileges`, dan ketujuh `pids_limit` bisa dihitung dari file itu.

## Secret

| Yang dipasang | Sumber pemeriksaannya |
|---|---|
| Dibuat imperatif dengan `kubectl create secret`. Tidak ada manifest Secret berisi nilai asli di repo | perintahnya di [RUNNING.md](RUNNING.md) dan di [`scripts/clean-slate-test.sh`](scripts/clean-slate-test.sh) tahap 5 |
| `ci.yml` meng-assert chart tidak memuat `kind: Secret` sama sekali, jadi aturan itu dipegang alat, bukan kebiasaan | step `Tidak ada Secret di chart` pada [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |
| Pod `api` menerima kunci S3 lewat `secretKeyRef` per kunci, jadi RPC secret dan admin token Garage tidak pernah masuk ke environment-nya walau berada di Secret yang sama | [`api-deployment.yaml`](k8s/chart/templates/api-deployment.yaml), bandingkan dengan `garage-statefulset.yaml` yang memakai `envFrom` untuk seluruh Secret |
| File `.env` tidak pernah ter-track git | `.gitignore`, dan `git log --all -- compose/.env` yang kosong |
| Cluster di runner CI memakai nilai acak yang ikut terbuang bersama clusternya | step pembuatan Secret pada [`kind-deploy.yml`](.github/workflows/kind-deploy.yml) |

Log run clean-slate di-redact di jalur tulis, bukan disunting setelah jadi. Ini bukan kehati-hatian teoretis: perintah bootstrap Garage mencetak access key ke stdout dengan sendirinya, dan log itu ikut di-commit. Detail ambang dan cara kerjanya di [RESULTS.md](RESULTS.md).

## Object storage

Jalur tulis dan jalur baca dipisah di tingkat port. Port S3 hanya menerima koneksi dari dalam cluster dan butuh kredensial; port website menyajikan baca tanpa kredensial. Hanya port website yang diberi Ingress, jadi permukaan tulis tidak pernah terekspos ke luar.

## Yang tidak dipasang

Disebut apa adanya, bukan disembunyikan:

| Tidak ada | Akibatnya | Cara mengeceknya |
|---|---|---|
| Enkripsi Secret | Kubernetes Secret adalah base64. Nilainya tersimpan tanpa enkripsi di etcd dan tidak ada riwayat perubahan yang bisa diaudit. SOPS adalah langkah berikutnya yang direncanakan | tidak ada file SOPS maupun provider KMS di repo |
| Pembatasan egress | Pod bisa menghubungi apa pun ke luar | kedelapan file di `k8s/network-policies/` hanya memuat `policyTypes: [Ingress]` |
| `readOnlyRootFilesystem` | Belum pernah diuji apakah kedelapan image bisa jalan dengannya | `grep -rn readOnlyRootFilesystem k8s/chart/templates/` tidak menghasilkan apa pun |
| Verifikasi SBOM dan provenance dari sisi konsumen | SBOM dan provenance di-publish tapi belum pernah diperiksa saat konsumsi | `cd.yml` hanya memanggil `cosign verify`, tidak `cosign verify-attestation` |
| TLS | Tidak ada sertifikat yang pernah di-issue. Alasannya batas scope, lihat [README.md](README.md) | tidak ada blok `tls:` di objek Ingress mana pun |
| Pemindaian dependency berkala | Scan hanya terjadi saat rilis, jadi CVE yang muncul setelah rilis terakhir tidak terdeteksi | tidak ada `.github/dependabot.yml` di repo mana pun |

## Rentang yang tidak dicakup dokumen ini

Keamanan kode aplikasi, termasuk autentikasi, otorisasi, dan validasi input, berada di repo aplikasi masing-masing. Yang di sini hanya lapisan orkestrasinya: container, cluster, jaringan, secret, dan supply chain image.
