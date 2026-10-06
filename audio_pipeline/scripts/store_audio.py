from pathlib import Path
import re

from audio_pipeline.scripts.db import get_connection


MUSIC_ROOT = Path("/opt/musicapp/music/Songs")


def safe_path_name(value):
    """
    Convert metadata into a safe Linux folder/file name while
    keeping normal spaces and readable song/album names.
    """
    if value is None:
        return None

    cleaned = value.strip()

    # Characters that can cause path problems or ambiguity.
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

    return cleaned or None


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
                "status": row[6],
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

    source_path = Path(item["local_file_path"])

    extension = source_path.suffix.lower()

    if not extension:
        extension = ".mp3"

    album_folder = MUSIC_ROOT / album_name
    destination_path = album_folder / f"{title}{extension}"

    return album_folder, destination_path


def main():
    items = get_items_for_storage()

    print(f"Found {len(items)} item(s) ready for storage.")
    print(f"Music root: {MUSIC_ROOT}")

    ready = 0
    collisions = 0
    missing = 0
    failed = 0

    planned_destinations = {}

    for item in items:
        print()
        print("=" * 70)
        print(f"Import item ID: {item['id']}")
        print(f"Status: {item['status']}")
        print(f"Album: {item['album']}")
        print(f"Title: {item['title']}")

        try:
            source_path = Path(item["local_file_path"])

            print(f"Source: {source_path}")

            if not source_path.exists():
                print("Storage preview: MISSING SOURCE")
                missing += 1
                continue

            if not source_path.is_file():
                print("Storage preview: SOURCE IS NOT A FILE")
                failed += 1
                continue

            album_folder, destination_path = build_destination(item)

            print(f"Album folder: {album_folder}")
            print(f"Destination: {destination_path}")

            destination_key = str(destination_path).casefold()

            if destination_key in planned_destinations:
                previous_id = planned_destinations[destination_key]

                print(
                    "Storage preview: PLANNED COLLISION "
                    f"with import item {previous_id}"
                )

                collisions += 1
                continue

            planned_destinations[destination_key] = item["id"]

            if destination_path.exists():
                print("Storage preview: DESTINATION ALREADY EXISTS")
                collisions += 1
                continue

            print("Storage preview: READY")
            ready += 1

        except Exception as error:
            print("Storage preview: FAILED")
            print(f"Reason: {error}")
            failed += 1

    print()
    print("=" * 70)
    print("Storage preview complete.")
    print(f"Items checked: {len(items)}")
    print(f"Ready: {ready}")
    print(f"Collisions: {collisions}")
    print(f"Missing sources: {missing}")
    print(f"Failed: {failed}")
    print()
    print("No folders were created.")
    print("No audio files were moved.")
    print("Database was NOT modified.")


if __name__ == "__main__":
    main()
