import argparse
import hashlib
import os
import re
import shutil
import uuid
from pathlib import Path

from audio_pipeline.scripts.db import (
    get_connection,
    get_import_job,
    mark_import_item_failed,
)

MUSIC_ROOT = Path("/opt/musicapp/music/Songs")


def safe_name(value):
    if value is None:
        return None
    value = re.sub(r"[/\\\x00-\x1f]", "-", str(value))
    value = re.sub(r"\s+", " ", value).strip(" .")
    return value or None


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def get_items(job_id):
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT id, original_filename, title, album,
                       local_file_path, sha256, status
                FROM import_items
                WHERE job_id = %s
                  AND status IN ('validated', 'warning')
                  AND song_id IS NULL
                ORDER BY id
                """,
                (job_id,),
            )
            return cursor.fetchall()
    finally:
        connection.close()


def update_path(item_id, path):
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE import_items
                SET local_file_path = %s, updated_at = NOW()
                WHERE id = %s
                  AND status IN ('validated', 'warning')
                  AND song_id IS NULL
                """,
                (str(path), item_id),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("Import item path update failed")
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def choose_destination(folder, title, suffix, expected_hash):
    base = folder / f"{title}{suffix}"

    if not base.exists():
        return base

    if base.is_file() and sha256_file(base) == expected_hash:
        return base

    candidate = folder / f"{title}-{expected_hash[:12]}{suffix}"

    if candidate.exists():
        if candidate.is_file() and sha256_file(candidate) == expected_hash:
            return candidate
        raise RuntimeError(
            f"Unique destination conflict: {candidate}"
        )

    return candidate


def store_item(item):
    item_id, filename, title, album, source, expected, status = item

    title = safe_name(title)
    album = safe_name(album)

    if not title or not album or not source or not expected:
        raise ValueError("Missing required storage metadata")

    source = Path(source)
    expected = expected.lower()

    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("Invalid SHA-256 value")

    suffix = source.suffix.lower() or ".mp3"

    if suffix != ".mp3":
        raise ValueError(f"Unsupported audio format: {suffix}")

    folder = MUSIC_ROOT / album

    # Verify source before creating or changing anything.
    if not source.is_file():
        raise FileNotFoundError(f"Source missing: {source}")

    if sha256_file(source) != expected:
        raise RuntimeError("Source SHA-256 mismatch")

    folder.mkdir(parents=True, exist_ok=True)
    destination = choose_destination(folder, title, suffix, expected)

    if destination == source:
        update_path(item_id, destination)
        return destination, "already stored"

    if destination.exists():
        update_path(item_id, destination)
        return destination, "already stored"

    temporary = folder / (
        f".{destination.name}.{uuid.uuid4().hex}.part"
    )

    try:
        shutil.copy2(source, temporary)

        if sha256_file(temporary) != expected:
            raise RuntimeError("Copied audio SHA-256 mismatch")

        # Exclusive creation prevents replacing an existing file.
        try:
            os.link(temporary, destination)
        except FileExistsError:
            if not destination.is_file() or sha256_file(destination) != expected:
                raise RuntimeError(
                    "Destination changed during storage; no overwrite"
                )

        if sha256_file(destination) != expected:
            raise RuntimeError("Final audio SHA-256 mismatch")

        update_path(item_id, destination)

    finally:
        temporary.unlink(missing_ok=True)

    return destination, "stored"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job-id", type=int, required=True)
    args = parser.parse_args()

    if get_import_job(args.job_id) is None:
        raise RuntimeError(f"Import job {args.job_id} not found")

    items = get_items(args.job_id)
    stored = 0
    reused = 0
    failed = 0
    unrecorded = 0

    for item in items:
        item_id = item[0]
        try:
            path, result = store_item(item)
            print(f"[{item_id}] {result}: {path}", flush=True)
            if result == "stored":
                stored += 1
            else:
                reused += 1

        except Exception as error:
            failed += 1
            reason = f"Storage failure: {error}"
            print(f"[{item_id}] FAILED: {reason}", flush=True)

            try:
                mark_import_item_failed(item_id, reason)
            except Exception as db_error:
                unrecorded += 1
                print(
                    f"[{item_id}] DATABASE UPDATE FAILED: {db_error}",
                    flush=True,
                )

    print(
        f"Job {args.job_id}: stored={stored}, "
        f"reused={reused}, failed={failed}, "
        f"unrecorded={unrecorded}",
        flush=True,
    )

    if unrecorded:
        raise RuntimeError(
            f"{unrecorded} storage failures could not be recorded"
        )


if __name__ == "__main__":
    main()
