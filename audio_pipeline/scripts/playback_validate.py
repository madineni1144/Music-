import argparse
import os
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

from audio_pipeline.scripts.db import (
    get_connection,
    get_import_job,
)

BASE_URL = os.getenv(
    "MUSICAPP_BASE_URL",
    "http://127.0.0.1:3000",
).rstrip("/")

MUSIC_ROOT = Path("/opt/musicapp/music/Songs").resolve()


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job-id", type=int, required=True)
    return parser.parse_args()


def get_items(job_id):
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT i.id, i.song_id, i.title,
                       i.local_file_path, s.file_path
                FROM import_items i
                JOIN songs s ON s.id = i.song_id
                WHERE i.job_id = %s
                  AND i.status IN ('validated', 'warning')
                ORDER BY i.id
                """,
                (job_id,),
            )
            return cursor.fetchall()
    finally:
        connection.close()


def build_music_url(file_path):
    path = Path(file_path).resolve()

    if not path.is_relative_to(MUSIC_ROOT):
        raise ValueError(f"File outside music library: {path}")

    relative = path.relative_to(MUSIC_ROOT)
    encoded = "/".join(quote(part, safe="") for part in relative.parts)

    return f"{BASE_URL}/music/{encoded}"


def test_playback(url):
    request = Request(
        url,
        headers={
            "Range": "bytes=0-0",
            "User-Agent": "MadineniMusicPlaybackValidator/2.0",
        },
        method="GET",
    )

    try:
        with urlopen(request, timeout=10) as response:
            status = response.status
            content_type = response.headers.get(
                "Content-Type", ""
            ).lower()
            content_range = response.headers.get(
                "Content-Range", ""
            )
            data = response.read(2)
    except HTTPError as error:
        raise RuntimeError(
            f"HTTP {error.code}: {error.reason}"
        ) from error
    except URLError as error:
        raise ConnectionError(
            f"Backend connection failed: {error.reason}"
        ) from error

    if status != 206:
        raise RuntimeError(f"Expected HTTP 206, received {status}")

    if not content_type.startswith("audio/"):
        raise RuntimeError(
            f"Expected audio Content-Type, received {content_type}"
        )

    if not content_range.startswith("bytes 0-0/"):
        raise RuntimeError(
            f"Invalid Content-Range: {content_range}"
        )

    if len(data) != 1:
        raise RuntimeError(
            f"Expected one audio byte, received {len(data)}"
        )


def save_result(item_id, success, reason=None):
    connection = get_connection()
    try:
        with connection.cursor() as cursor:
            if success:
                cursor.execute(
                    """
                    UPDATE import_items
                    SET playback_validated = TRUE,
                        updated_at = NOW()
                    WHERE id = %s
                      AND status IN ('validated', 'warning')
                    """,
                    (item_id,),
                )
            else:
                cursor.execute(
                    """
                    UPDATE import_items
                    SET playback_validated = FALSE,
                        status = 'failed',
                        failure_reason = %s,
                        updated_at = NOW()
                    WHERE id = %s
                      AND status IN ('validated', 'warning')
                    """,
                    (reason, item_id),
                )

            if cursor.rowcount != 1:
                raise RuntimeError(
                    f"Could not save playback result for {item_id}"
                )

        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def check_backend():
    request = Request(
        f"{BASE_URL}/api/health",
        headers={"User-Agent": "MadineniMusicPlaybackValidator/2.0"},
    )

    try:
        with urlopen(request, timeout=10) as response:
            if response.status != 200:
                raise RuntimeError(
                    f"Backend health returned HTTP {response.status}"
                )
    except (HTTPError, URLError) as error:
        raise RuntimeError(
            f"Backend unavailable; no songs were marked failed: {error}"
        ) from error


def main():
    args = parse_arguments()

    if get_import_job(args.job_id) is None:
        raise RuntimeError(f"Import job {args.job_id} not found")

    items = get_items(args.job_id)

    print(f"Playback validation job: {args.job_id}", flush=True)
    print(f"Registered items: {len(items)}", flush=True)

    if not items:
        print("No registered songs to validate.", flush=True)
        return

    check_backend()

    passed = 0
    failed = 0

    for item_id, song_id, title, import_path, song_path in items:
        try:
            if Path(import_path).resolve() != Path(song_path).resolve():
                raise ValueError("Import path and song path differ")

            path = Path(song_path).resolve()

            if not path.is_file():
                raise FileNotFoundError(f"Missing file: {path}")

            url = build_music_url(song_path)
            test_playback(url)

        except ConnectionError as error:
            raise RuntimeError(
                "Backend connection lost during playback validation; "
                "remaining songs were not marked failed"
            ) from error

        except Exception as error:
            reason = f"Playback failure: {error}"
            save_result(item_id, False, reason)
            failed += 1
            print(
                f"[{item_id}] FAILED song_id={song_id}: {reason}",
                flush=True,
            )

        else:
            save_result(item_id, True)
            passed += 1
            print(
                f"[{item_id}] PASS song_id={song_id}: {title}",
                flush=True,
            )

    print(
        f"Playback complete: passed={passed}, failed={failed}",
        flush=True,
    )


if __name__ == "__main__":
    main()
