from pathlib import Path
import argparse
import json
import subprocess

from audio_pipeline.scripts.db import (
    get_pending_import_items,
    get_import_job,
    update_import_item_validation,
)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Validate pending audio import items."
    )
    parser.add_argument(
        "--job-id",
        type=int,
        default=None,
    )
    return parser.parse_args()


def probe_audio(file_path):
    command = [
        "ffprobe",
        "-v", "error",
        "-show_entries",
        "format=duration,size:"
        "format_tags=title,artist,album",
        "-of", "json",
        str(file_path),
    ]

    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        timeout=120,
    )

    if result.returncode != 0:
        return None, result.stderr.strip() or "ffprobe failed"

    try:
        return json.loads(result.stdout), None
    except json.JSONDecodeError as error:
        return None, f"Invalid ffprobe JSON: {error}"


def decode_audio(file_path):
    command = [
        "ffmpeg",
        "-v", "error",
        "-i", str(file_path),
        "-f", "null",
        "-",
    ]

    result = subprocess.run(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        timeout=600,
    )

    message = result.stderr.strip()

    if result.returncode != 0:
        return "FAILED", message or "ffmpeg decoding failed"

    if message:
        return "WARNING", message

    return "OK", None


def save_validation(item_id, status, **fields):
    update_import_item_validation(
        item_id=item_id,
        status=status,
        **fields,
    )


def validate_item(item):
    item_id = item["id"]
    filename = item["original_filename"]
    local_path = item.get("local_file_path")

    print(f"\n[{item_id}] {filename}", flush=True)

    if not local_path:
        save_validation(
            item_id,
            "failed",
            failure_reason="Local file path is missing.",
        )
        return "FAILED"

    file_path = Path(local_path)

    if not file_path.is_file():
        save_validation(
            item_id,
            "failed",
            failure_reason=f"Audio file missing or invalid: {file_path}",
        )
        return "FAILED"

    metadata, error = probe_audio(file_path)

    if error:
        save_validation(
            item_id,
            "failed",
            failure_reason=error,
        )
        return "FAILED"

    audio_format = metadata.get("format", {})
    tags = audio_format.get("tags", {})

    title = tags.get("title")
    artist = tags.get("artist")
    album = tags.get("album")

    print(
        f"FFprobe OK | title={title} | "
        f"artist={artist} | album={album}",
        flush=True,
    )

    decode_status, message = decode_audio(file_path)

    if decode_status == "FAILED":
        save_validation(
            item_id,
            "failed",
            title=title,
            artist=artist,
            album=album,
            failure_reason=message,
        )
        return "FAILED"

    if decode_status == "WARNING":
        save_validation(
            item_id,
            "warning",
            title=title,
            artist=artist,
            album=album,
            failure_reason=message,
        )
        return "WARNING"

    save_validation(
        item_id,
        "validated",
        title=title,
        artist=artist,
        album=album,
        failure_reason=None,
    )
    return "OK"


def main():
    args = parse_arguments()

    if args.job_id is not None:
        job = get_import_job(args.job_id)
        if job is None:
            raise RuntimeError(
                f"Import job {args.job_id} does not exist."
            )

        print(f"Import job ID: {args.job_id}")
        print(f"Import run: {job['run_id']}")

    pending_items = get_pending_import_items(
        job_id=args.job_id
    )

    print(
        f"Pending items: {len(pending_items)}",
        flush=True,
    )

    validated = 0
    warnings = 0
    failed = 0
    unrecorded = 0

    for item in pending_items:
        try:
            result = validate_item(item)

            if result == "OK":
                validated += 1
            elif result == "WARNING":
                warnings += 1
            else:
                failed += 1

            print(
                f"[{item['id']}] {result}",
                flush=True,
            )

        except (FileNotFoundError, subprocess.TimeoutExpired) as error:
            failed += 1
            reason = f"Audio validation failure: {error}"

            try:
                save_validation(
                    item["id"],
                    "failed",
                    failure_reason=reason,
                )
                print(
                    f"[{item['id']}] FAILED: {reason}",
                    flush=True,
                )
            except Exception as db_error:
                unrecorded += 1
                print(
                    f"[{item['id']}] DATABASE ERROR: {db_error}",
                    flush=True,
                )

        except Exception:
            # Unexpected exceptions may indicate database or
            # infrastructure problems. Do not hide them.
            raise

    print("\nAudio validation complete.")
    print(f"Validated: {validated}")
    print(f"Warnings: {warnings}")
    print(f"Failed: {failed}")
    print(f"Unrecorded failures: {unrecorded}")

    if unrecorded:
        raise RuntimeError(
            f"{unrecorded} validation failures were not recorded"
        )


if __name__ == "__main__":
    main()
