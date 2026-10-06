from pathlib import Path
import json
import subprocess

from audio_pipeline.scripts.db import (
    get_pending_import_items,
    update_import_item_validation,
)


def probe_audio(file_path):
    command = [
        "ffprobe",
        "-v", "error",
        "-show_entries",
        "format=duration,size:format_tags=title,artist,album",
        "-of", "json",
        str(file_path),
    ]

    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return None, result.stderr.strip()

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
    )

    decoder_output = result.stderr.strip()

    if result.returncode != 0:
        return "FAILED", decoder_output

    if decoder_output:
        return "WARNING", decoder_output

    return "OK", None


def validate_item(item):
    file_path = Path(item["local_file_path"])

    print()
    print("=" * 60)
    print(f"Import item ID: {item['id']}")
    print(f"File: {item['original_filename']}")
    print(f"Path: {file_path}")

    if not file_path.exists():
        reason = "File does not exist."

        update_import_item_validation(
            item_id=item["id"],
            status="failed",
            failure_reason=reason,
        )

        print("Validation: FAILED")
        print(f"Reason: {reason}")

        return "FAILED"

    if not file_path.is_file():
        reason = "Path is not a regular file."

        update_import_item_validation(
            item_id=item["id"],
            status="failed",
            failure_reason=reason,
        )

        print("Validation: FAILED")
        print(f"Reason: {reason}")

        return "FAILED"

    metadata, error = probe_audio(file_path)

    if error:
        update_import_item_validation(
            item_id=item["id"],
            status="failed",
            failure_reason=error,
        )

        print("FFprobe: FAILED")
        print(f"Reason: {error}")

        return "FAILED"

    audio_format = metadata.get("format", {})
    tags = audio_format.get("tags", {})

    title = tags.get("title")
    artist = tags.get("artist")
    album = tags.get("album")

    print("FFprobe: OK")
    print(f"Duration: {audio_format.get('duration')}")
    print(f"Size: {audio_format.get('size')}")
    print(f"Title: {title}")
    print(f"Artist: {artist}")
    print(f"Album: {album}")

    decode_status, decode_message = decode_audio(file_path)

    print(f"Full Decode: {decode_status}")

    if decode_message:
        print(f"Decoder message: {decode_message}")

    if decode_status == "FAILED":
        update_import_item_validation(
            item_id=item["id"],
            status="failed",
            title=title,
            artist=artist,
            album=album,
            failure_reason=decode_message,
        )

        print("Validation: FAILED")
        return "FAILED"

    if decode_status == "WARNING":
        update_import_item_validation(
            item_id=item["id"],
            status="warning",
            title=title,
            artist=artist,
            album=album,
            failure_reason=decode_message,
        )

        print("Validation: WARNING")
        return "WARNING"

    update_import_item_validation(
        item_id=item["id"],
        status="validated",
        title=title,
        artist=artist,
        album=album,
        failure_reason=None,
    )

    print("Validation: OK")
    return "OK"


def main():
    pending_items = get_pending_import_items()

    print(f"Found {len(pending_items)} pending import item(s).")

    validated = 0
    warnings = 0
    failed = 0

    for item in pending_items:
        try:
            status = validate_item(item)

            if status == "OK":
                validated += 1

            elif status == "WARNING":
                warnings += 1

            else:
                failed += 1

        except Exception as error:
            failed += 1

            print()
            print("=" * 60)
            print(f"Import item ID: {item['id']}")
            print(f"File: {item['original_filename']}")
            print("Validation: FAILED")
            print(f"Reason: {error}")

    print()
    print("=" * 60)
    print("Audio validation complete.")
    print(f"Pending items checked: {len(pending_items)}")
    print(f"Validated OK: {validated}")
    print(f"Warnings: {warnings}")
    print(f"Failed: {failed}")


if __name__ == "__main__":
    main()
