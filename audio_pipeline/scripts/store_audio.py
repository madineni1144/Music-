from pathlib import Path
import hashlib
import re
import shutil

from audio_pipeline.scripts.db import get_connection


MUSIC_ROOT = Path("/opt/musicapp/music/Songs")


def safe_path_name(value):
    """
    Convert metadata into a safe Linux folder/file name while
    keeping normal spaces and readable names.
    """
    if value is None:
        return None

    cleaned = value.strip()

    # Prevent path separators and null characters.
    cleaned = re.sub(r'[\/\0]', "-", cleaned)

    # Remove control characters.
    cleaned = "".join(
        character
        for character in cleaned
        if ord(character) >= 32
    )

    # Collapse repeated whitespace.
    cleaned = re.sub(r"\s+", " ", cleaned)

    # Avoid trailing dots/spaces.
    cleaned = cleaned.strip(" .")

    # Prevent special path components.
    if cleaned in {".", ".."}:
        return None

    return cleaned or None


def calculate_sha256(file_path):
    sha256 = hashlib.sha256()

    with open(file_path, "rb") as file_handle:
        while True:
            chunk = file_handle.read(1024 * 1024)

            if not chunk:
                break

            sha256.update(chunk)

    return sha256.hexdigest()


def get_items_for_storage():
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT
                    id,
                    original_filename,
                    title,
                    artist,
                    album,
                    local_file_path,
                    sha256,
                    status
                FROM import_items
                WHERE status IN ('validated', 'warning')
                ORDER BY album, title, id;
                """
            )

            rows = cursor.fetchall()

        return [
            {
                "id": row[0],
                "original_filename": row[1],
                "title": row[2],
                "artist": row[3],
                "album": row[4],
                "local_file_path": row[5],
                "sha256": row[6],
                "status": row[7],
            }
            for row in rows
        ]

    finally:
        connection.close()


def build_destination(item):
    album_name = safe_path_name(item["album"])
    title = safe_path_name(item["title"])

    if not album_name:
        raise ValueError("Album name is empty.")

    if not title:
        raise ValueError("Song title is empty.")

    if not item["local_file_path"]:
        raise ValueError("Source file path is empty.")

    source_path = Path(item["local_file_path"])

    extension = source_path.suffix.lower()

    if not extension:
        extension = ".mp3"

    album_folder = MUSIC_ROOT / album_name
    destination_path = album_folder / f"{title}{extension}"

    return source_path, album_folder, destination_path


def update_final_path(item_id, destination_path):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE import_items
                SET
                    local_file_path = %s,
                    updated_at = NOW()
                WHERE id = %s
                  AND status IN ('validated', 'warning');
                """,
                (
                    str(destination_path),
                    item_id,
                ),
            )

            if cursor.rowcount != 1:
                raise RuntimeError(
                    f"Import item {item_id} was not updated."
                )

        connection.commit()

    except Exception:
        connection.rollback()
        raise

    finally:
        connection.close()


def copy_and_verify(item):
    source_path, album_folder, destination_path = build_destination(item)

    if not source_path.exists():
        raise FileNotFoundError(
            f"Source file does not exist: {source_path}"
        )

    if not source_path.is_file():
        raise RuntimeError(
            f"Source path is not a file: {source_path}"
        )

    if destination_path.exists():
        raise FileExistsError(
            f"Destination already exists: {destination_path}"
        )

    expected_sha256 = item["sha256"]

    if not expected_sha256:
        raise ValueError(
            f"Import item {item['id']} has no SHA-256 value."
        )

    source_sha256 = calculate_sha256(source_path)

    if source_sha256 != expected_sha256:
        raise RuntimeError(
            "Source SHA-256 does not match the database."
        )

    album_folder.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary_path = destination_path.with_name(
        destination_path.name + ".part"
    )

    if temporary_path.exists():
        raise FileExistsError(
            f"Temporary destination already exists: {temporary_path}"
        )

    try:
        shutil.copy2(
            source_path,
            temporary_path,
        )

        copied_sha256 = calculate_sha256(temporary_path)

        if copied_sha256 != expected_sha256:
            raise RuntimeError(
                "Copied file SHA-256 verification failed."
            )

        temporary_path.rename(destination_path)

        final_sha256 = calculate_sha256(destination_path)

        if final_sha256 != expected_sha256:
            raise RuntimeError(
                "Final file SHA-256 verification failed."
            )

        update_final_path(
            item_id=item["id"],
            destination_path=destination_path,
        )

    except Exception:
        if temporary_path.exists():
            temporary_path.unlink()

        raise

    return destination_path


def main():
    items = get_items_for_storage()

    print(f"Found {len(items)} item(s) ready for storage.")
    print(f"Music root: {MUSIC_ROOT}")

    stored = 0
    failed = 0

    planned_destinations = {}

    for item in items:
        print()
        print("=" * 70)
        print(f"Import item ID: {item['id']}")
        print(f"Status: {item['status']}")
        print(f"Album: {item['album']}")
        print(f"Title: {item['title']}")
        print(f"Artist: {item['artist']}")

        try:
            source_path, album_folder, destination_path = (
                build_destination(item)
            )

            print(f"Source: {source_path}")
            print(f"Album folder: {album_folder}")
            print(f"Destination: {destination_path}")

            destination_key = str(destination_path).casefold()

            if destination_key in planned_destinations:
                previous_id = planned_destinations[destination_key]

                raise RuntimeError(
                    "Destination collision with import item "
                    f"{previous_id}."
                )

            planned_destinations[destination_key] = item["id"]

            final_path = copy_and_verify(item)

            print(f"Stored: {final_path}")
            print("SHA-256 verification: OK")
            print("Database final path update: OK")

            stored += 1

        except Exception as error:
            print("Storage: FAILED")
            print(f"Reason: {error}")

            failed += 1

    print()
    print("=" * 70)
    print("Audio storage stage complete.")
    print(f"Items checked: {len(items)}")
    print(f"Stored successfully: {stored}")
    print(f"Failed: {failed}")
    print()
    print("Original staging files were NOT deleted.")


if __name__ == "__main__":
    main()
