import argparse
import re

from audio_pipeline.scripts.db import (
    get_import_items,
    get_import_job,
    update_import_item_metadata,
    mark_import_item_failed,
)


WATERMARK_NAMES = [
    r"SenSongsMp3(?:\.Co(?:m)?)?",
    r"NaaSongsHD",
    r"My3Songs",
]


# Canonical album/category mappings.
#
# Any incoming album matching one of these names will automatically
# be stored using the mapped album name.
ALBUM_MAPPINGS = {
    "telugu folk songs": "Private Songs",
}


# Fallback artist name for songs without valid artist metadata.
UNKNOWN_ARTIST = "Unknown Artist"


def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Normalize imported audio metadata."
    )

    parser.add_argument(
        "--job-id",
        type=int,
        default=None,
        help=(
            "Process only validated/warning items "
            "belonging to this import job."
        ),
    )

    return parser.parse_args()


def remove_watermarks(value):
    if value is None:
        return None

    cleaned = str(value)

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

    cleaned = re.sub(
        r"\s+",
        " ",
        cleaned,
    )

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

    cleaned = re.sub(
        r"\s+",
        " ",
        cleaned,
    )

    cleaned = cleaned.strip(" -:|")

    if not cleaned:
        return None

    # Apply canonical album/category mappings.
    #
    # Example:
    #   "Telugu Folk Songs" -> "Private Songs"
    mapped_album = ALBUM_MAPPINGS.get(
        cleaned.casefold()
    )

    if mapped_album:
        return mapped_album

    return cleaned


def get_items_for_normalization(job_id=None):
    return get_import_items(
        job_id=job_id,
        statuses=[
            "validated",
            "warning",
        ],
    )


def normalize_item(item):
    normalized_title = clean_title(
        item["title"]
    )

    normalized_artist = clean_artist(
        item["artist"]
    )

    normalized_album = clean_album(
        item["album"]
    )

    if not normalized_title:
        raise ValueError(
            "Normalized title is empty."
        )

    # FIX:
    # If artist metadata is missing, empty, or contains
    # only a removed website watermark, use a safe fallback.
    #
    # Valid artist names remain unchanged.
    if not normalized_artist:
        normalized_artist = UNKNOWN_ARTIST

        print(
            f"WARNING: Missing artist metadata for "
            f"{item['original_filename']}. "
            f"Using '{UNKNOWN_ARTIST}'."
        )

    if not normalized_album:
        raise ValueError(
            "Normalized album is empty."
        )

    print()
    print("=" * 70)
    print(
        f"Import item ID: {item['id']}"
    )
    print(
        f"File: {item['original_filename']}"
    )
    print(
        f"Status: {item['status']}"
    )

    print()
    print("Before:")
    print(
        f"  Title : {item['title']}"
    )
    print(
        f"  Artist: {item['artist']}"
    )
    print(
        f"  Album : {item['album']}"
    )

    print()
    print("After:")
    print(
        f"  Title : {normalized_title}"
    )
    print(
        f"  Artist: {normalized_artist}"
    )
    print(
        f"  Album : {normalized_album}"
    )

    update_import_item_metadata(
        item_id=item["id"],
        title=normalized_title,
        artist=normalized_artist,
        album=normalized_album,
    )

    print("Database update: OK")


def main():
    args = parse_arguments()

    if args.job_id is not None:
        job = get_import_job(
            args.job_id
        )

        if job is None:
            raise RuntimeError(
                f"Import job {args.job_id} "
                "does not exist."
            )

        print(
            f"Import job ID: {args.job_id}"
        )
        print(
            f"Import run: {job['run_id']}"
        )

    else:
        print(
            "Import job ID: ALL eligible jobs"
        )

    items = get_items_for_normalization(
        job_id=args.job_id
    )

    print(
        f"Found {len(items)} item(s) "
        "for metadata normalization."
    )

    updated = 0
    failed = 0

    for item in items:
        try:
            normalize_item(item)
            updated += 1

        except ValueError as error:
            reason = f"Metadata normalization failure: {error}"

            # Only invalid metadata is a per-song failure.
            # Database errors must propagate to Airflow.
            mark_import_item_failed(
                item_id=item["id"],
                failure_reason=reason,
            )

            failed += 1

            print()
            print("=" * 70)
            print(f"Import item ID: {item['id']}")
            print(f"File: {item['original_filename']}")
            print("Metadata normalization: FAILED")
            print(f"Reason: {reason}")

    print()
    print("=" * 70)
    print(
        "Metadata normalization complete."
    )

    if args.job_id is not None:
        print(
            f"Import job ID: {args.job_id}"
        )

    print(
        f"Items checked: {len(items)}"
    )
    print(
        f"Updated: {updated}"
    )
    print(
        f"Failed: {failed}"
    )



if __name__ == "__main__":
    main()
