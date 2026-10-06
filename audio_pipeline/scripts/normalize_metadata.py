import re

from audio_pipeline.scripts.db import (
    get_connection,
    update_import_item_metadata,
)


WATERMARK_NAMES = [
    r"SenSongsMp3(?:\.Co(?:m)?)?",
    r"NaaSongsHD",
    r"My3Songs",
]


def remove_watermarks(value):
    if value is None:
        return None

    cleaned = value

    for watermark in WATERMARK_NAMES:
        cleaned = re.sub(
            rf"\s*(?:::|-)\s*{watermark}\s*",
            " ",
            cleaned,
            flags=re.IGNORECASE,
        )

        cleaned = re.sub(
            watermark,
            " ",
            cleaned,
            flags=re.IGNORECASE,
        )

    return cleaned


def clean_text(value):
    if value is None:
        return None

    cleaned = remove_watermarks(value)

    cleaned = re.sub(r"\s+", " ", cleaned)
    cleaned = cleaned.strip(" -:|")

    return cleaned or None


def clean_title(title):
    return clean_text(title)


def clean_artist(artist):
    return clean_text(artist)


def clean_album(album):
    cleaned = clean_text(album)

    if cleaned is None:
        return None

    # Remove trailing release year.
    #
    # Examples:
    #   "90ML (2019)" -> "90ML"
    #   "Uppena (2021)" -> "Uppena"
    cleaned = re.sub(
        r"\s*\((?:19|20)\d{2}\)\s*$",
        "",
        cleaned,
    )

    cleaned = re.sub(r"\s+", " ", cleaned)
    cleaned = cleaned.strip(" -:|")

    return cleaned or None


def get_items_for_normalization():
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
                    status
                FROM import_items
                WHERE status IN ('validated', 'warning')
                ORDER BY id;
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
                "status": row[5],
            }
            for row in rows
        ]

    finally:
        connection.close()


def normalize_item(item):
    normalized_title = clean_title(item["title"])
    normalized_artist = clean_artist(item["artist"])
    normalized_album = clean_album(item["album"])

    if not normalized_title:
        raise ValueError("Normalized title is empty.")

    if not normalized_artist:
        raise ValueError("Normalized artist is empty.")

    if not normalized_album:
        raise ValueError("Normalized album is empty.")

    print()
    print("=" * 70)
    print(f"Import item ID: {item['id']}")
    print(f"File: {item['original_filename']}")
    print(f"Status: {item['status']}")

    print()
    print("Before:")
    print(f"  Title : {item['title']}")
    print(f"  Artist: {item['artist']}")
    print(f"  Album : {item['album']}")

    print()
    print("After:")
    print(f"  Title : {normalized_title}")
    print(f"  Artist: {normalized_artist}")
    print(f"  Album : {normalized_album}")

    update_import_item_metadata(
        item_id=item["id"],
        title=normalized_title,
        artist=normalized_artist,
        album=normalized_album,
    )

    print("Database update: OK")


def main():
    items = get_items_for_normalization()

    print(f"Found {len(items)} item(s) for metadata normalization.")

    updated = 0
    failed = 0

    for item in items:
        try:
            normalize_item(item)
            updated += 1

        except Exception as error:
            failed += 1

            print()
            print("=" * 70)
            print(f"Import item ID: {item['id']}")
            print(f"File: {item['original_filename']}")
            print("Database update: FAILED")
            print(f"Reason: {error}")

    print()
    print("=" * 70)
    print("Metadata normalization complete.")
    print(f"Items checked: {len(items)}")
    print(f"Updated: {updated}")
    print(f"Failed: {failed}")


if __name__ == "__main__":
    main()
