#!/usr/bin/env python3
"""Bump satu image aplikasi ke tag dan digest baru di seluruh tempat ia dipin.

Dipakai .github/workflows/cd.yml, dan bisa dijalankan manual dari root repo:

    python3 .github/scripts/bump-image.py <nama-repo> <tag> <sha256:...>

Digest dipin di tiga file dengan dua bentuk berbeda: values.yaml memisahkan tag
dan digest jadi dua key, sementara compose dan skrip clean-slate memakai satu
string utuh. Keduanya harus berubah bersamaan, jadi keduanya ditangani di sini
dan bukan lewat dua sed terpisah yang bisa jalan sebagian.

Status keluar: 0 berhasil, 2 kalau digest yang diminta sudah terpasang, 1 gagal.
"""

import re
import sys
from pathlib import Path

REGISTRY = "ghcr.io/qrizan"
VALUES = Path("k8s/chart/values.yaml")
PINNED_AS_ONE_STRING = [
    Path("compose/docker-compose.yml"),
    Path("scripts/clean-slate-test.sh"),
]


def die(message):
    print("GAGAL: " + message, file=sys.stderr)
    raise SystemExit(1)


def main():
    if len(sys.argv) != 4:
        die("butuh 3 argumen: <nama-repo> <tag> <digest>")
    repo, new_tag, new_digest = sys.argv[1:]

    if not re.fullmatch(r"sha256:[0-9a-f]{64}", new_digest):
        die("digest tidak berbentuk sha256: " + new_digest)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", new_tag):
        die("tag tidak valid: " + new_tag)

    for path in [VALUES] + PINNED_AS_ONE_STRING:
        if not path.is_file():
            die(str(path) + " tidak ada, jalankan dari root repo")

    # Tag dan digest lama dibaca dari values.yaml, tidak diterima sebagai argumen.
    # Nilai lama yang salah ketik akan diam-diam tidak mengganti apa pun.
    block = re.compile(
        r"(?P<head>repository: "
        + re.escape(REGISTRY + "/" + repo)
        + r"\n)(?P<tag_indent>[ ]+)tag: (?P<tag>\S+)\n(?P<digest_indent>[ ]+)digest: (?P<digest>\S+)"
    )
    values_text = VALUES.read_text()
    found = block.search(values_text)
    if found is None:
        die(str(VALUES) + ": blok image untuk " + repo + " tidak ditemukan")

    old_tag = found.group("tag")
    old_digest = found.group("digest")
    if (old_tag, old_digest) == (new_tag, new_digest):
        print(repo + " sudah dipin ke " + new_tag + " " + new_digest + ", tidak ada yang diubah")
        raise SystemExit(2)

    VALUES.write_text(
        values_text[: found.start()]
        + found.group("head")
        + found.group("tag_indent")
        + "tag: "
        + new_tag
        + "\n"
        + found.group("digest_indent")
        + "digest: "
        + new_digest
        + values_text[found.end() :]
    )
    print(str(VALUES) + ": 1 blok, " + old_tag + " -> " + new_tag)

    old_ref = REGISTRY + "/" + repo + ":" + old_tag + "@" + old_digest
    new_ref = REGISTRY + "/" + repo + ":" + new_tag + "@" + new_digest
    total = 1
    for path in PINNED_AS_ONE_STRING:
        body = path.read_text()
        count = body.count(old_ref)
        if count == 0:
            die(str(path) + ": tidak memuat rujukan ke " + old_ref)
        path.write_text(body.replace(old_ref, new_ref))
        print(str(path) + ": " + str(count) + " rujukan diperbarui")
        total += count

    # Sapuan penutup. Satu tempat yang terlewat berarti stack menjalankan dua
    # versi image sekaligus, dan itu tidak terlihat sampai runtime.
    for path in [VALUES] + PINNED_AS_ONE_STRING:
        if old_digest in path.read_text():
            die(str(path) + ": masih memuat digest lama " + old_digest)

    print("OK: " + repo + " -> " + new_tag + " @ " + new_digest + ", " + str(total) + " tempat")


if __name__ == "__main__":
    main()
