# Results

Apa yang diverifikasi, bagaimana verifikasinya dijalankan, dan angka yang keluar darinya. Cara menjalankan sendiri ada di [RUNNING.md](RUNNING.md).

Batas yang berlaku atas seluruh angka di sini: tidak ada satu pun yang berasal dari sistem yang berjalan permanen. Semuanya lahir dari run yang bisa diulang di mesin lokal atau di runner CI, dan tiap baris menyebut asalnya. Alasan batas itu ada di bagian scope pada [README.md](README.md).

## Skrip clean-slate

[`scripts/clean-slate-test.sh`](scripts/clean-slate-test.sh) menghapus cluster dan Compose stack sampai habis, termasuk image yang dipin, lalu me-rebuild keduanya dari nol dan meng-assert hasilnya. Seluruh output disalin apa adanya ke [`scripts/output.txt`](scripts/output.txt), yang ikut di-commit sebagai bukti.

Prasyarat divalidasi sebelum apa pun dihapus: sepuluh binary (`kind`, `kubectl`, `helm`, `docker`, `jq`, `sed`, `tee`, `curl`, `timeout`, `k6`), lalu `compose/.env`, lalu entri auth `ghcr.io`. Kalau ada yang kurang, cluster yang sedang jalan tidak disentuh dan `output.txt` run sebelumnya tidak tertimpa.

Log run yang gagal ditulis ke file terpisah dan hanya dipindahkan menjadi `scripts/output.txt` kalau skrip exit 0. Isi file itu karena itu selalu run yang sukses penuh.

### Di mana asersinya

Skrip berjalan dari tahap `### 0` sampai `### 9d`. Lima di antaranya meng-assert, sisanya menyiapkan. Penanda ini sama dengan yang ada di log dan yang dirujuk tabel angka di bawah.

| Tahap | Yang di-assert |
|---|---|
| `### 7` | 5 endpoint Ingress balas `200`, `assets.localhost` balas `404`, registrasi `201` lalu avatar `200` |
| `### 8` | jumlah pod yang terbaca metrics-server sama dengan jumlah pod yang `Running` |
| `### 8b` | threshold k6 terpenuhi, dan replica `api` benar-benar naik setelah beban |
| `### 9c` | container Compose `healthy` dan `migrate` exit 0 |
| `### 9d` | endpoint yang sama seperti `### 7` kecuali Grafana yang tidak berjalan di Compose, kali ini lewat proxy |

Dua tahap di ujung skrip yang menentukan nilainya. Tahap 0 memvalidasi prasyarat **sebelum** tahap 1 menghapus apa pun, karena kegagalan setelah penghapusan berarti kehilangan cluster tanpa mendapat hasil apa pun. Tahap `### 9d` mengulang asersi tahap `### 7` di target yang berbeda, sehingga perbedaan perilaku antara Compose dan cluster tertangkap, bukan diasumsikan tidak ada.

### Redact nilai rahasia

Nilai dari `compose/.env` dan token auth GHCR di-redact saat log ditulis, bukan disunting setelahnya. Perintah bootstrap Garage mencetak access key bucket ke stdout dengan sendirinya, jadi tanpa redact nilai itu masuk riwayat git tiap kali log di-commit.

Yang di-redact hanya nilai sepanjang delapan karakter atau lebih, karena nilai yang lebih pendek ikut cocok sebagai substring nama host dan resource, dan menyamarkannya merusak log tanpa menutup rahasia apa pun. Variabel yang dilewati aturan itu disebut namanya di blok `### 0. preflight` pada log, jadi tidak ada yang di-skip diam-diam.

## Pemeriksaan otomatis di GitHub Actions

Dua dari tiga workflow di [`.github/workflows/`](.github/workflows/) menjalankan sebagian pemeriksaan yang sama pada tiap push ke `main` dan tiap pull request. Yang ketiga menangani rilis dan diuraikan di [RELEASE.md](RELEASE.md).

- `ci.yml` menjalankan `helm lint`, lalu meng-assert bahwa tahap bootstrap merender tepat dua resource, jalur normal merender tepat 29, dan tidak ada manifest Secret di dalam chart.
- `kind-deploy.yml` membuat cluster kind di dalam runner, menjalankan bootstrap dua tahap, menunggu rollout kelima Deployment, lalu memeriksa kelima endpoint Ingress. Secret di sana dibuat dari nilai acak yang ikut terbuang bersama cluster.

Cakupannya lebih sempit daripada skrip clean-slate. Runner tidak menjalankan Compose stack, tidak memasang metrics-server, dan tidak menjalankan load test, jadi objek HPA terbentuk tanpa metrik di belakangnya. Durasi pull juga tidak dibandingkan, karena bandwidth runner bukan properti sistem ini.

Yang dibuktikan runner adalah chart ini bisa di-deploy dari nol tanpa mesin lokal mana pun. Pada run pertama, jarak dari job start sampai endpoint terakhir membalas `200` adalah 2 menit 24 detik, terbaca dari stempel waktu log job tersebut.

## Angka dari satu run clean-slate

Cluster kind satu node di laptop. Semua baris di tabel berikut berasal dari satu run yang sama.

Tabel ini snapshot, bukan angka yang berlaku selamanya. `scripts/output.txt` selalu berisi log run sukses terakhir, jadi tiap kali file itu berganti, angka di sini ikut diperbarui dalam commit yang sama. Kalau angkanya tidak cocok dengan log, tabelnya yang salah.

Rujukan memakai penanda tahap di dalam log (`### 6`, `### 7`, dan seterusnya), bukan nomor baris, supaya tidak basi saat log ditulis ulang.

| Yang diukur | Hasil | Sumber di `scripts/output.txt` |
|---|---|---|
| Allocatable node kind | 8 CPU, 16139784Ki memory | `### 2`, output `kubectl get node` |
| Helm tahap 1 (install) sampai tahap 2 (upgrade) selesai | 13 detik | `### 6`, selisih dua baris `LAST DEPLOYED` |
| Umur pod saat seluruh `rollout status` selesai | `postgres-0` 76 detik, enam pod lain 46 detik | `### 7`, output `kubectl get pods` |
| Endpoint lewat Ingress yang membalas `200` | 5 dari 5 | `### 7`, baris `OK:` |
| Root `assets.localhost` tanpa `index.html` | `404`, sesuai harapan | `### 7`, baris `OK:` |
| Registrasi lewat Ingress, lalu avatar defaultnya diambil dari object storage | `201` lalu `200` | `### 7`, baris `OK:` |
| Pod yang terbaca metrics-server | 7 dari 7 | `### 8` |
| Load test k6, ramp 0 sampai 100 VU selama 3 menit | 104.967 iterasi, 0,00% request gagal (5 dari 104.967), 582,8 req/s | `### 8b`, blok `TOTAL RESULTS` |
| Latency di bawah beban itu | p95 56,99 ms, median 3,55 ms, max 5,37 detik | `### 8b`, `http_req_duration` |
| Respons HPA terhadap beban | replica 1 naik ke 5, CPU 368% terhadap target 60% | `### 8b`, dua output `kubectl get hpa` |
| `docker compose pull` dari nol | 18 menit 0 detik | `### 9`, output `time` |
| `docker compose up -d` | 28,7 detik | `### 9`, output `time` |
| Container Compose `running` dan `healthy` | 6 running, 5 di antaranya healthy, `migrate` exit 0 | `### 9c` |
| Registrasi dan pengambilan avatar yang sama di Compose | `201` lalu `200` | `### 9d`, baris `OK:` |

### Cara membaca dua angka di tabel itu

**76 detik** adalah umur pod tertua saat perintah dijalankan, bukan stopwatch dari perintah pertama. Pembacaan yang bisa dipertanggungjawabkan: dari pod pertama dibuat sampai seluruh Deployment selesai rollout, kurang dari 76 detik, dengan image sudah di-pre-pull ke node.

**Durasi pull image** ada di `### 3` dan `### 9` tapi sengaja tidak dijadikan angka hasil. Yang diukur di situ adalah bandwidth koneksi saat run berlangsung, bukan properti sistem ini.

## Pemakaian resource saat idle

Beberapa menit setelah start, tanpa trafik dari luar, dari `### 8`:

| Pod | CPU | Memory |
|---|---|---|
| `postgres` | 46m | 64Mi |
| `grafana` | 42m | 167Mi |
| `api` | 12m | 67Mi |
| `prometheus` | 7m | 97Mi |
| `public` | 2m | 62Mi |
| `garage` | 2m | 44Mi |
| `admin` | 1m | 13Mi |

## Load test

Beban dijalankan dengan [`k8s/k6/load-test.js`](k8s/k6/load-test.js) terhadap `catalog.localhost/api/public/games`, lewat Ingress dan bukan lewat port-forward. Nilai `maxReplicas: 5` pada HPA berangkat dari 8 allocatable CPU di baris pertama tabel di atas.

Threshold `http_req_failed` di dalam skenario k6 membuat k6 exit non-zero kalau kegagalan melewati batas, jadi load test ini adalah gate, bukan sekadar pengukuran. Setelah beban selesai, skrip meng-assert bahwa jumlah replica benar-benar naik; kalau HPA tidak merespons, run dinyatakan gagal.
