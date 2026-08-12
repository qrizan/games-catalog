# Decisions

Rationale dan trade-off tiap keputusan orkestrasi. Bentuk sistem dan cara kerja mekanismenya ada di [ARCHITECTURE.md](ARCHITECTURE.md), cara menjalankan di [RUNNING.md](RUNNING.md), dan angka hasilnya di [RESULTS.md](RESULTS.md).

## Deploy target

### kind, di laptop dan di dalam runner CI

**Rationale.** Alternatifnya cluster terkelola di cloud atau k3s di VPS. Keduanya berbiaya bulanan berjalan, dan yang ingin dilatih di sini adalah mekanisme Kubernetes, yang identik di kind. kind juga bisa dibangun ulang dari nol di dalam runner CI, sehingga tiap pull request diverifikasi terhadap cluster sungguhan, bukan terhadap hasil render manifest.

**Trade-off.** Perilaku `Service type=LoadBalancer` milik penyedia cloud, StorageClass berbasis disk jaringan, IAM cloud, DNS publik, dan TLS tidak teruji. Tidak ada endpoint yang bisa diakses dari luar dan tidak ada angka uptime yang bisa diklaim. Batas ini disengaja dan konsekuensinya diuraikan di bagian scope pada [README.md](README.md).

## Orchestrator

### Kubernetes

**Rationale.** Alternatifnya Swarm. Tiga hal yang jadi tujuan latihan di sini, isolasi jaringan antar-service, volume yang bertahan melewati restart, dan penambahan replica otomatis di bawah beban, punya primitif langsung di Kubernetes berupa NetworkPolicy, PersistentVolumeClaim, dan HorizontalPodAutoscaler. Swarm tidak menyediakan padanan ketiganya.

**Trade-off.** Kompleksitasnya jauh di atas kebutuhan tiga service. Ingress controller, NetworkPolicy, Pod Security Admission, RBAC, dan HPA masing-masing harus dikonfigurasi dan bisa rusak sendiri-sendiri. Swarm selesai dengan sebagian kecil dari itu.

### Helm

**Rationale.** Alternatifnya raw manifest atau Kustomize. Primitif "tunggu Job selesai sebelum Deployment di-roll" sudah disediakan hook lifecycle Helm. Tanpa Helm, urutan itu diorkestrasi manual dan ditulis ulang lagi di sisi CD.

**Trade-off.** Ada lapisan templating antara sumber dan YAML yang ter-apply, jadi `helm template` perlu dijalankan untuk tahu apa yang dikirim. Helm menyimpan state sendiri berupa release dan revisi, yang bisa bermasalah terpisah dari cluster: mengadopsi resource yang sudah ada butuh anotasi dan label khusus plus satu kali `--force-conflicts`. Timeout hook dipegang client, bukan cluster, jadi proses `helm` bisa keluar sementara Job-nya masih jalan.

## Cluster components

### ingress-nginx dipasang sendiri

**Rationale.** Ingress controller bawaan penyedia cloud menuntut anotasi dan class yang berbeda-beda per penyedia. Dengan controller yang dipasang sendiri, isi objek Ingress ditentukan repo ini dan tetap sama di mana pun chart dijalankan.

**Trade-off.** Upgrade dan patch CVE controller jadi tanggungan sendiri. Integrasi load balancer bawaan cloud tidak dipakai.

### Komponen bawaan distro dimatikan

**Rationale.** Ingress controller, perilaku `Service type=LoadBalancer`, dan StorageClass adalah tiga hal yang paling ingin dipahami mekanismenya. Memakai bawaan distro membuat ketiganya jalan tanpa pernah dikonfigurasi sendiri.

**Trade-off.** Jalan menuju cluster yang berfungsi jadi lebih panjang dengan lebih banyak titik gagal. Ini disengaja.

## Chart structure

### Satu Helm release untuk seluruh stack

**Rationale.** Satu `helm upgrade` per rilis, tanpa mengoordinasikan beberapa release yang bisa saling mendahului. Bentuk ini juga paling sederhana dipanggil dari CD.

**Trade-off.** Blast radius sebesar seluruh stack. Satu values yang salah menggulirkan semuanya, komponen tidak bisa dirilis atau di-rollback sendiri-sendiri, dan Prometheus serta Grafana terikat siklus rilis aplikasi padahal tidak berhubungan.

### NetworkPolicy dan ingress-nginx di luar chart

**Rationale.** Keduanya infra cluster, siklus hidupnya tidak terikat rilis aplikasi. Alasan kedua lebih memaksa: hook `pre-install` berjalan sebelum resource non-hook mana pun, jadi NetworkPolicy yang masuk chart belum ada saat Job migrasi menghubungi database.

**Trade-off.** `helm upgrade` tidak meng-apply policy, jadi policy yang berubah butuh langkah terpisah yang gampang terlupa. Gejalanya bukan error yang jelas melainkan gateway timeout, karena paket di-drop di jaringan dan tidak pernah sampai ke aplikasi. Sudah pernah terjadi sekali.

### Bootstrap dua tahap lewat values flag

**Rationale.** Alternatifnya menjadikan PostgreSQL sebagai hook. Untuk resource yang bukan Job atau Pod, Helm memaknai "ready" sebagai "objeknya berhasil dibuat", yang tidak menjamin database menerima koneksi. Hook `pre-install` juga berhenti dikelola Helm pada upgrade berikutnya. Templating kondisional tidak menyentuh semantik hook.

**Trade-off.** Instalasi pertama jadi dua perintah, dan CD harus tahu soal flag ini. `--set` dari revisi sebelumnya terbawa ke upgrade yang tidak menyebutkannya, jadi flag itu wajib ditulis eksplisit tiap kali.

## Database migration

### Job terpisah dengan Helm hook

**Rationale.** Prisma tidak mendukung migrasi konkuren dari proses berbeda. Sebagai initContainer di tiap pod, replica lebih dari satu langsung berarti race. Di Compose polanya sama dengan mekanisme berbeda: satu service sekali jalan yang di-gate `service_completed_successfully`.

**Trade-off.** Migrasi yang gagal memblokir seluruh rilis, dan tidak ada rollback otomatis untuk migrasi yang telanjur separuh jalan. Karena timeout hook dipegang client, pull image yang lambat bisa menggagalkan `helm upgrade` walau Job-nya sendiri sukses.

## Routing

### Routing host-based

**Rationale.** Alternatifnya path prefix per aplikasi. Dashboard admin adalah SPA dengan router di root; memindahkannya ke sub-path menuntut rebuild dan republish image. Host-based juga melatih mekanisme yang sama dengan Ingress berbasis host.

**Trade-off.** Jumlah hostname yang dikelola bertambah. Di lingkungan lokal ini gratis karena `*.localhost` resolve sendiri; di luar itu tiap host butuh record DNS dan sertifikatnya sendiri.

### Config nginx Compose ditulis manual

**Rationale.** Config yang digenerate dari label container menyembunyikan mekanisme yang ingin dilatih.

**Trade-off.** Menambah service berarti menyunting config dengan tangan. Tidak ada service discovery.

## Object storage

### Garage satu node

**Rationale.** S3-compatible, satu binary, cukup untuk skala demo, portabel antara Compose dan Kubernetes.

**Trade-off.** Satu node berarti tidak ada redundansi, dan ekosistemnya jauh lebih tipis dibanding MinIO atau S3. Nama bucket terikat ke hostname publiknya karena Garage meresolusi website endpoint lewat pencocokan nama bucket terhadap `root_domain`, jadi penamaan bucket dan host tidak bisa diputuskan terpisah.

### Endpoint S3 tidak diberi ingress

**Rationale.** Jalur tulis hanya dari dalam network dan berkredensial, jalur baca publik tanpa kredensial. Permukaan tulis tidak pernah terekspos ke luar.

**Trade-off.** Browser tidak bisa upload langsung lewat presigned URL, jadi API mem-proxy seluruh byte-nya dan menanggung beban itu.

### Satu langkah manual diterima

**Rationale.** Mengaktifkan akses website pada bucket butuh node key yang tersimpan di metadata directory node yang sedang berjalan. Pola job sekali-jalan dari container terpisah sudah dicoba dan gagal karena itu.

**Trade-off.** Klaim "satu perintah dari nol" jadi tidak sepenuhnya benar di kedua target, dan langkah ini harus diingat tiap kali volume dibuat ulang.

### Database menyimpan object key, bukan URL

**Rationale.** URL dirakit saat response disusun, dari base URL yang datang dari env. Host penyimpanan bisa berubah antar-target tanpa migrasi data, konsisten dengan larangan mem-*bake* hostname ke dalam image.

**Trade-off.** Perakitan itu harus ditulis di tiap tempat field-nya dibaca, enam titik di API. Mekanisme bawaan ORM untuk menghitung field saat baca tidak bisa dipakai karena tidak boleh menimpa field skalar yang sudah ada dan tidak berlaku pada relasi bersarang, yang justru salah satu tempat field itu muncul.

### Avatar default diunggah aplikasi, bukan lewat langkah bootstrap

**Rationale.** Berkasnya ikut di dalam image aplikasi dan bukan di dalam container object storage, jadi langkah bootstrap manual harus berupa exec ke container aplikasi dengan skrip inline, terulang di tiap target. Aplikasi mengunggahnya sendiri pada registrasi pertama, hanya kalau pemeriksaan keberadaan objek menjawab 404.

**Trade-off.** Satu pemeriksaan tambahan pada registrasi pertama tiap proses. Ditaruh di jalur registrasi dan bukan saat start supaya proses tetap bisa naik tanpa object storage; harganya, salah konfigurasi baru terlihat pada registrasi pertama, bukan saat container start.

### Postgres dan endpoint S3 di-publish ke loopback pada Compose

**Rationale.** Skrip seeding memakai dependensi pengembangan yang dibuang saat image dibangun, jadi tidak ada container yang bisa menjalankannya. Seeding dijalankan dari host, dan itu butuh kedua port terjangkau dari sana.

**Trade-off.** Dua port terbuka di antarmuka loopback mesin pengembang. Alternatifnya mem-publish image tahap build khusus atau memasukkan perkakas demo ke image produksi, keduanya menambah artefak yang harus dirawat demi kebutuhan yang hanya ada di pengembangan lokal.

## Secrets

### Kubernetes Secret polos dulu, SOPS menyusul

**Rationale.** Secret bawaan Kubernetes adalah base64, bukan enkripsi. Mekanisme injeksi env dibuktikan dulu sebelum menambah lapisan enkripsi. SOPS dipilih untuk nanti karena bekerja terhadap file di repo, sehingga tidak mengikat cluster ke secret manager milik satu penyedia.

**Trade-off.** Sampai itu dikerjakan, nilai secret tersimpan tanpa enkripsi di etcd dan tidak ada riwayat perubahan yang bisa diaudit.

### Secret dibuat imperatif

**Rationale.** Alternatifnya manifest Secret yang ikut di repo. Dengan cara imperatif tidak ada file berisi nilai asli di repo, jadi tidak ada yang bisa ter-commit karena kelalaian.

**Trade-off.** State cluster tidak bisa direproduksi dari git saja. Membangun ulang butuh file `.env` lokal yang hidup di luar repo, dan file itu jadi satu-satunya sumber nilai yang tidak bisa diverifikasi dari repo.

## State

### Data demo ephemeral, tanpa backup

**Rationale.** Skrip clean-slate menghapus cluster dan volume sampai habis karena reproducibility yang sedang diuji. Memperlakukan data sebagai persisten bertentangan dengan itu.

**Trade-off.** Isi demo harus dibuat ulang lewat aplikasi tiap kali stack dibangun ulang, karena Job migrasi hanya membentuk skema dan tidak menjalankan seed.

### Storage monitoring pakai emptyDir

**Rationale.** Konsep persistent volume sudah dibuktikan dua kali lewat PostgreSQL dan Garage. Riwayat metrik di cluster yang dihapus berkala tidak punya apa pun untuk dilindungi.

**Trade-off.** Riwayat metrik hilang tiap pod restart. Tidak ada tren jangka panjang yang bisa ditunjukkan, dan dashboard selalu mulai dari kosong.

## Monitoring

### Prometheus dan Grafana ditulis sendiri

**Rationale.** Chart bundel menghasilkan monitoring yang jalan tanpa pemahaman komponennya. Scrape config, alert rule, RBAC, dan provisioning Grafana ditulis satu per satu.

**Trade-off.** Cakupannya jauh lebih sempit daripada bundel siap pakai: tidak ada metrik node, kubelet, maupun control plane, dan tidak ada koleksi dashboard bawaan. Scrape config dan RBAC jadi tanggungan sendiri tiap versinya berubah.

### Service discovery berbasis anotasi pod

**Rationale.** Pola standar yang tidak menambah CRD dan tidak menuntut operator berjalan lebih dulu.

**Trade-off.** Aturan relabeling ditulis tangan. Menambah target berarti menyunting config lalu men-deploy ulang, bukan membuat satu objek baru.

### Tanpa Alertmanager

**Rationale.** Tidak ada tujuan notifikasi nyata untuk dituju.

**Trade-off.** Alert hanya terlihat kalau ada yang membuka halamannya. Tidak ada grouping, silencing, maupun routing, dan pengiriman notifikasi tidak bisa didemokan.

## Autoscaling

### HPA berbasis CPU

**Rationale.** Beban di sini murni HTTP request-response sinkron, bukan event-driven, jadi scale-to-zero berbasis queue milik KEDA tidak menjawab kebutuhan apa pun. Prometheus Adapter menambah komponen dan menyebarkan debugging ke tiga tempat.

**Trade-off.** CPU cuma proksi dari beban sebenarnya. Scaling berdasarkan request per detik atau panjang antrean tidak tersedia, dan metrics-server jadi dependensi tambahan di luar chart.

## Supply chain

### Image dikonsumsi lewat digest

**Rationale.** Tag bisa dipindahkan ke konten lain; digest adalah kontennya. Tag tetap ditulis berdampingan supaya terbaca manusia.

**Trade-off.** Digest tiap image aplikasi dipin di tiga file dan sampai lima tempat: chart values, Compose file, dan skrip clean-slate yang menyebutnya dua kali. Penyuntingannya sekarang dilakukan satu skrip yang dipanggil dari pipeline rilis, jadi tidak lagi manual, tapi konsistensi antar-tempat itu tetap sesuatu yang harus dijaga alat, bukan sifat bawaan bentuknya. Patch keamanan juga tidak pernah terambil sendiri.

## Delivery

### CD push-based, GitOps ditunda

**Rationale.** ArgoCD dan Flux adalah abstraksi di atas `kubectl` dan `helm` yang belum terbukti jalan manual di sini. Abstraksi baru masuk setelah lapisan di bawahnya terbukti.

**Trade-off.** Tidak ada deteksi drift, dan git tidak jadi sumber kebenaran atas apa yang benar-benar berjalan. Biaya berikutnya belum tertanggung karena rantai ini berhenti sebelum rollout: begitu step itu ditambahkan, CI harus memegang kredensial cluster, yaitu secret yang hidup di luar cluster.

### CD berhenti di pull request, bukan rollout

**Rationale.** Alternatifnya menjalankan `helm upgrade` langsung dari workflow rilis. Tidak ada cluster yang berjalan permanen untuk dituju: cluster lokal mati bersama mesinnya, cluster di runner hidup selama satu job, dan tidak ada target lain di luar keduanya. Yang bisa diotomatiskan adalah bagian yang paling sering dikerjakan, yaitu menaikkan digest di seluruh tempat ia dipin lalu membuktikan versi barunya bisa di-deploy di cluster sekali pakai.

**Trade-off.** Ini belum continuous deployment dalam arti penuh, karena rilis tidak sampai ke lingkungan berjalan tanpa campur tangan manusia. Selama pull request belum di-merge, digest yang tercatat di repo berbeda dari yang benar-benar berjalan.

### Trigger lintas-repo pakai GitHub App

**Rationale.** Token bawaan workflow tidak memicu workflow run di repo lain. Di antara dua opsi yang tersisa, token instalasi GitHub App tidak terikat akun pribadi dan tidak menuntut rotasi berkala seperti personal access token.

**Trade-off.** Setup di depan lebih panjang, dan private key App itu sendiri jadi secret baru yang harus disimpan dan dirotasi.

