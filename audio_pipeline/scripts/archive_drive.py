import argparse
import os

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build

from audio_pipeline.scripts.db import (
    get_connection,
    get_import_job,
)


TOKEN_FILE = os.getenv(
    "GOOGLE_DRIVE_TOKEN_FILE",
    "/home/rk/google_drive_token.json",
)

INCOMING_FOLDER_ID = "1QZWFD51jh4_gtHOBfi7bauhJLB9_QTaC"
ARCHIVE_FOLDER_ID = "1kDDuKxP8-gL3YnkA7q9djHIVrxLZExC3"
FAILED_FOLDER_ID = "1e0Do2V1IZucWVVQlwhErR8o4aM8h3q-I"

SCOPES = [
    "https://www.googleapis.com/auth/drive"
]


def parse_arguments():
    parser = argparse.ArgumentParser(
        description=(
            "Route Google Drive import files to "
            "Archive or FAILED."
        )
    )

    parser.add_argument(
        "--job-id",
        type=int,
        default=None,
        help=(
            "Process only Drive items belonging "
            "to this import job."
        ),
    )

    return parser.parse_args()


def get_import_items(job_id=None):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            if job_id is None:
                cursor.execute(
                    """
                    SELECT
                        id,
                        drive_file_id,
                        original_filename,
                        status,
                        playback_validated,
                        song_id,
                        failure_reason
                    FROM import_items
                    WHERE drive_file_id IS NOT NULL
                    ORDER BY id;
                    """
                )
            else:
                cursor.execute(
                    """
                    SELECT
                        id,
                        drive_file_id,
                        original_filename,
                        status,
                        playback_validated,
                        song_id,
                        failure_reason
                    FROM import_items
                    WHERE job_id = %s
                      AND drive_file_id IS NOT NULL
                    ORDER BY id;
                    """,
                    (job_id,),
                )

            rows = cursor.fetchall()

        return [
            {
                "id": row[0],
                "drive_file_id": row[1],
                "filename": row[2],
                "status": row[3],
                "playback_validated": row[4],
                "song_id": row[5],
                "failure_reason": row[6],
            }
            for row in rows
        ]

    finally:
        connection.close()


def determine_destination(item):
    status = item["status"]
    playback_validated = item[
        "playback_validated"
    ]

    if status in (
        "validated",
        "warning",
    ):
        if playback_validated:
            return (
                ARCHIVE_FOLDER_ID,
                "ARCHIVE",
            )

        return None, "KEEP"

    if status == "duplicate":
        return (
            ARCHIVE_FOLDER_ID,
            "ARCHIVE_DUPLICATE",
        )

    if status == "failed":
        return (
            FAILED_FOLDER_ID,
            "FAILED",
        )

    return None, "KEEP"


def get_drive_file(
    drive,
    drive_file_id,
):
    return (
        drive.files()
        .get(
            fileId=drive_file_id,
            fields=(
                "id,name,parents,trashed"
            ),
        )
        .execute()
    )


def move_from_incoming(
    drive,
    drive_file_id,
    destination_folder_id,
):
    return (
        drive.files()
        .update(
            fileId=drive_file_id,
            addParents=destination_folder_id,
            removeParents=INCOMING_FOLDER_ID,
            fields="id,name,parents",
        )
        .execute()
    )


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

    credentials = (
        Credentials.from_authorized_user_file(
            TOKEN_FILE,
            SCOPES,
        )
    )

    drive = build(
        "drive",
        "v3",
        credentials=credentials,
    )

    items = get_import_items(
        job_id=args.job_id
    )

    archived_success = 0
    archived_duplicates = 0
    moved_failed = 0
    kept = 0
    already_moved = 0
    errors = 0

    print("=" * 72)
    print(
        "GOOGLE DRIVE ARCHIVE / FAILED ROUTING"
    )
    print("=" * 72)

    if args.job_id is not None:
        print(
            f"Import job ID: {args.job_id}"
        )
    else:
        print(
            "Import job ID: ALL tracked jobs"
        )

    print(
        f"Tracked Drive items: {len(items)}"
    )
    print()

    for item in items:
        (
            destination_id,
            action,
        ) = determine_destination(
            item
        )

        print("-" * 72)
        print(
            f"Import {item['id']} | "
            f"{item['filename']}"
        )
        print(
            f"Status: {item['status']} | "
            "Playback: "
            f"{item['playback_validated']} | "
            f"Song ID: {item['song_id']}"
        )

        try:
            drive_file = get_drive_file(
                drive,
                item["drive_file_id"],
            )

            if drive_file.get(
                "trashed"
            ):
                print(
                    "SKIP: Drive file is trashed."
                )

                errors += 1
                continue

            parents = drive_file.get(
                "parents",
                [],
            )

            if (
                INCOMING_FOLDER_ID
                not in parents
            ):
                print(
                    "SKIP: File is already "
                    "outside INCOMING."
                )

                already_moved += 1
                continue

            if destination_id is None:
                print(
                    "KEEP: File remains "
                    "in INCOMING."
                )

                kept += 1
                continue

            result = move_from_incoming(
                drive,
                item["drive_file_id"],
                destination_id,
            )

            new_parents = result.get(
                "parents",
                [],
            )

            if (
                destination_id
                not in new_parents
            ):
                raise RuntimeError(
                    "Drive move returned without "
                    "expected destination parent."
                )

            if action == "ARCHIVE":
                archived_success += 1

                print(
                    "MOVED: INCOMING → Archive"
                )

            elif (
                action
                == "ARCHIVE_DUPLICATE"
            ):
                archived_duplicates += 1

                print(
                    "MOVED: INCOMING → Archive "
                    "(duplicate)"
                )

            elif action == "FAILED":
                moved_failed += 1

                print(
                    "MOVED: INCOMING → FAILED"
                )

        except Exception as error:
            errors += 1

            print(
                f"ERROR: {error}"
            )

    print()
    print("=" * 72)
    print(
        "DRIVE ROUTING COMPLETE"
    )
    print("=" * 72)

    if args.job_id is not None:
        print(
            f"Import job ID:         "
            f"{args.job_id}"
        )

    print(
        f"Tracked items:          {len(items)}"
    )
    print(
        f"Success archived:       "
        f"{archived_success}"
    )
    print(
        f"Duplicates archived:    "
        f"{archived_duplicates}"
    )
    print(
        f"Moved to FAILED:        "
        f"{moved_failed}"
    )
    print(
        f"Kept in INCOMING:       "
        f"{kept}"
    )
    print(
        f"Already moved:          "
        f"{already_moved}"
    )
    print(
        f"Errors:                 {errors}"
    )

    if errors:
        raise RuntimeError(
            "Drive routing completed with "
            f"{errors} error(s)."
        )

    print()
    print(
        "Google Drive routing "
        "completed successfully."
    )


if __name__ == "__main__":
    main()
