# games-catalog

Repo orkestrasi untuk tiga aplikasi: REST API, dashboard admin, dan katalog publik. Source code ketiganya ada di repo terpisah dengan riwayat git masing-masing. Repo ini hanya memuat yang men-deploy, menghubungkan, dan mengawasi ketiganya: Compose stack untuk development, Helm chart untuk Kubernetes, Prometheus dan Grafana untuk monitoring, serta skrip clean-slate rebuild.

Seluruhnya dibangun dari primitif Docker dan Kubernetes langsung, tanpa installer cluster siap pakai dan tanpa chart monitoring bundel. Ingress controller, scrape config, objek RBAC, dan NetworkPolicy ditulis dan dikonfigurasi sendiri.

## Dokumentasi

| Dokumen | Menjawab |
|---|---|
| [STRUCTURE.md](STRUCTURE.md) | isi repo, siapa memiliki apa, dan di titik mana ia bertemu ketiga repo aplikasi |
| [RUNNING.md](RUNNING.md) | cara menjalankannya, di Compose maupun di kind |
| [ARCHITECTURE.md](ARCHITECTURE.md) | bagaimana sistemnya bekerja, tujuh sudut pandang dengan diagram |
| [DECISION.md](DECISION.md) | kenapa satu opsi dipilih di antara alternatif, beserta biayanya |
| [RESULTS.md](RESULTS.md) | apa yang diverifikasi, bagaimana, dan angka yang keluar |
| [RELEASE.md](RELEASE.md) | rantai rilis lintas-repo dan di mana ia berhenti |
| [SECURITY.md](SECURITY.md) | postur keamanan yang terpasang, dan yang sengaja tidak |

## Scope

Yang dikerjakan repo ini berhenti di satu batas yang tegas: **cluster Kubernetes yang dibangun dari nol dan diverifikasi otomatis, tanpa target deploy.**

Ada dua tempat stack ini benar-benar berjalan. Pertama, cluster kind di mesin lokal, dibangun ulang dari nol oleh satu skrip yang meng-assert tiap tahapnya dan menyimpan log run terakhir di repo. Kedua, cluster kind di dalam runner GitHub Actions, dibangun ulang pada tiap pull request, dengan Helm chart yang sama dan asersi endpoint yang sama. Chart, NetworkPolicy, dan manifest yang dipakai di keduanya identik.

Yang berada di luar batas itu, beserta akibatnya:

| Di luar scope | Akibat yang harus dibaca apa adanya |
|---|---|
| Cluster terkelola di penyedia cloud | Perilaku `Service type=LoadBalancer` milik cloud, StorageClass berbasis disk jaringan, dan IAM cloud tidak pernah diuji |
| DNS publik dan TLS | Tidak ada sertifikat yang pernah di-issue. Seluruh hostname adalah `*.localhost` |
| Rollout otomatis ke cluster yang menyala terus | Rantai rilis berhenti di pull request berisi bump digest terverifikasi. Merge dan rollout dijalankan manusia |
| Endpoint yang bisa diakses publik | Tidak ada demo langsung. Yang bisa diperiksa orang lain adalah menjalankan sendiri dari repo |

Alasannya biaya, dinyatakan terbuka: cluster terkelola yang menyala 24 jam berbiaya bulanan berjalan, sementara seluruh mekanisme yang ingin dilatih di sini berperilaku sama di kind.

Konsekuensi yang paling penting untuk dinilai jujur: **tidak ada angka uptime, ketersediaan, atau trafik produksi di dokumentasi ini,** karena tidak ada sistem yang berjalan permanen untuk menghasilkannya. Angka yang dimuat hanya yang lahir dari run yang bisa diulang, dan tiap angka menyebut asal runnya.

## Applications

| Repo | Peran | Stack |
|---|---|---|
| [nestjs-swagger-prisma](https://github.com/qrizan/nestjs-swagger-prisma) | REST API | NestJS, Prisma, PostgreSQL |
| [react-shadcn-redux](https://github.com/qrizan/react-shadcn-redux) | Dashboard admin | Vite, React, Redux, shadcn/ui |
| [nextjs-chakra-reactquery](https://github.com/qrizan/nextjs-chakra-reactquery) | Katalog publik | Next.js, Chakra UI, React Query |

Kedua frontend membaca base URL API saat container start, bukan saat build. Digest yang sama karena itu dipakai di Compose dan di cluster dengan nilai env berbeda, tanpa rebuild di antaranya.

## Services

| Service | Image | Port | Host publik | Konfigurasi runtime |
|---|---|---|---|---|
| `api` | `ghcr.io/qrizan/nestjs-swagger-prisma` | 3000 | `admin.localhost/api`, `catalog.localhost/api` | `DATABASE_URL`, `JWT_SECRET`, `JWT_EXPIRES_IN`, `CORS_ORIGINS`, `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_PUBLIC_BASE_URL` |
| `admin` | `ghcr.io/qrizan/react-shadcn-redux` | 8080 | `admin.localhost` | `API_URL` |
| `public` | `ghcr.io/qrizan/nextjs-chakra-reactquery` | 8080 | `catalog.localhost` | `API_URL`, `API_BACKEND_INTERNAL` |
| `postgres` | `postgres` | 5432 | tidak diekspos | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` |
| `garage` | `dxflrs/garage` | 3900 (S3), 3902 (website) | `assets.localhost`, hanya 3902 | `GARAGE_RPC_SECRET`, `GARAGE_ADMIN_TOKEN`, `GARAGE_DEFAULT_ACCESS_KEY`, `GARAGE_DEFAULT_SECRET_KEY`, `GARAGE_DEFAULT_BUCKET` |
| `prometheus` | `prom/prometheus` | 9090 | tidak diekspos | tidak ada |
| `grafana` | `grafana/grafana` | 3000 | `grafana.localhost` | `GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD` |

Tag dan digest tiap image tidak dicantumkan di sini. Yang berlaku ada di [`k8s/chart/values.yaml`](k8s/chart/values.yaml) untuk cluster dan [`compose/docker-compose.yml`](compose/docker-compose.yml) untuk stack development; keduanya disunting oleh skrip yang sama saat rilis baru masuk, lihat [RELEASE.md](RELEASE.md). Semua image dipin ke digest di kedua target.

Object storage punya dua port dengan sifat berbeda: 3900 untuk tulis dari dalam jaringan dengan kredensial, 3902 untuk baca dari browser tanpa kredensial. Hanya 3902 yang diberi ingress. Compose menambahkan reverse proxy nginx di host port 8080, mengisi peran yang dipegang ingress-nginx di cluster. Prometheus dan Grafana tidak berjalan di Compose.

## Not built yet

Rollout otomatis, TLS, dan cluster di penyedia cloud tidak ada karena batas scope di atas, bukan karena pekerjaannya tertunda. Daftar lengkap yang tidak dipasang di sisi keamanan, termasuk enkripsi Secret dan pembatasan egress, ada di [SECURITY.md](SECURITY.md).

Manifest tetap ditulis supaya bisa dipindahkan tanpa restrukturisasi: tidak ada hostname di dalam image, konfigurasi lewat env saat runtime, dan perbedaan antar-target diungkapkan sebagai Helm values. Klaim itu sendiri belum pernah diuji terhadap target lain, karena chart ini hanya pernah dijalankan di kind.
