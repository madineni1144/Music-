import argparse
import hashlib
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

from audio_pipeline.scripts.db import (
    get_or_create_import_job,
    get_import_job,
    get_import_items,
    complete_import_job,
    create_import_item,
    find_duplicate_by_drive_file_id,
    find_duplicate_by_sha256,
    get_connection,
)

TOKEN_FILE = Path(
    os.getenv(
        "GOOGLE_DRIVE_TOKEN_FILE",
        "/home/rk/google_drive_token.json",
    )
)

INCOMING_FOLDER_ID = "1QZWFD51jh4_gtHOBfi7bauhJLB9_QTaC"
STAGING_DIR = Path("/opt/musicapp/staging/incoming")
SCOPES = ["https://www.googleapis.com/auth/drive"]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Download and track incoming music."
    )
    parser.add_argument(
        "--run-id",
        help="Stable run identifier for Airflow retries.",
    )
    return parser.parse_args()


def calculate_sha256(path):
    digest = hashlib.sha256()

    with path.open("rb") as source:
        for chunk in iter(
            lambda: source.read(1024 * 1024),
            b"",
        ):
            digest.update(chunk)

    return digest.hexdigest()


def get_drive_service():
    credentials = Credentials.from_authorized_user_file(
        str(TOKEN_FILE),
        SCOPES,
    )

    if credentials.expired:
        if not credentials.refresh_token:
            raise RuntimeError(
                "Google Drive refresh token unavailable."
            )

        credentials.refresh(Request())

        TOKEN_FILE.write_text(
            credentials.to_json(),
            encoding="utf-8",
        )
        TOKEN_FILE.chmod(0o600)

    if not credentials.valid:
        raise RuntimeError(
            "Google Drive credentials invalid."
        )

    return build(
        "drive",
        "v3",
        credentials=credentials,
        cache_discovery=False,
    )


def list_audio_files(drive):
    results = []
    page_token = None

    while True:
        response = drive.files().list(
            q=(
                f"'{INCOMING_FOLDER_ID}' in parents "
                "and trashed=false"
            ),
            fields=(
                "nextPageToken,"
                "files(id,name,mimeType,size)"
            ),
            pageSize=1000,
            pageToken=page_token,
        ).execute()

        for item in response.get("files", []):
            if item.get(
                "mimeType", ""
            ).startswith("audio/"):
                results.append(item)

        page_token = response.get("nextPageToken")

        if not page_token:
            break

    return sorted(
        results,
        key=lambda item: item["id"],
    )


def staged_path(item):
    drive_id = item["id"]

    if not re.fullmatch(
        r"[A-Za-z0-9_-]+",
        drive_id,
    ):
        raise ValueError(
            "Invalid Google Drive file ID."
        )

    filename = Path(item["name"]).name

    if filename in ("", ".", ".."):
        raise ValueError(
            "Invalid audio filename."
        )

    return STAGING_DIR / drive_id / filename


def download_file(drive, file_id, destination):
    destination.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    temporary = destination.with_name(
        destination.name + ".part"
    )

    if temporary.exists():
        temporary.unlink()

    request = drive.files().get_media(
        fileId=file_id
    )

    try:
        with temporary.open("wb") as output:
            downloader = MediaIoBaseDownload(
                output,
                request,
            )

            done = False

            while not done:
                _, done = downloader.next_chunk()

        temporary.replace(destination)

    except Exception:
        temporary.unlink(missing_ok=True)
        raise


def set_job_failed(
    job_id,
    total_files,
    successful_files,
    failed_files,
    duplicate_files,
):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE import_jobs
                SET
                    status = 'failed',
                    total_files = %s,
                    successful_files = %s,
                    failed_files = %s,
                    duplicate_files = %s,
                    completed_at = NULL
                WHERE id = %s;
                """,
                (
                    total_files,
                    successful_files,
                    failed_files,
                    duplicate_files,
                    job_id,
                ),
            )

            if cursor.rowcount != 1:
                raise RuntimeError(
                    f"Import job {job_id} not found."
                )

        connection.commit()

    except Exception:
        connection.rollback()
        raise

    finally:
        connection.close()


def main():
    args = parse_args()

    run_id = args.run_id or (
        datetime.now(timezone.utc).strftime(
            "drive-import-%Y%m%d-%H%M%S-%f"
        )
    )

    job_id = get_or_create_import_job(run_id)
    job = get_import_job(job_id)

    print("=" * 70)
    print("GOOGLE DRIVE INCOMING DOWNLOAD")
    print("=" * 70)
    print(f"Import run: {run_id}")
    print(f"Import job ID: {job_id}")
    print(f"Existing status: {job['status']}")

    if job["status"] == "completed":
        print(
            "This run already completed download/tracking. "
            "Reusing existing records."
        )
        print(f"IMPORT_JOB_ID={job_id}")
        return

    drive = get_drive_service()

    STAGING_DIR.mkdir(
        parents=True,
        exist_ok=True,
    )

    files = list_audio_files(drive)

    downloaded = 0
    reused_staged = 0
    newly_tracked = 0
    duplicates = 0
    skipped = 0
    failures = 0

    for item in files:
        file_id = item["id"]
        filename = item["name"]

        print(
            f"Checking: {filename} ({file_id})"
        )

        try:
            existing = find_duplicate_by_drive_file_id(
                file_id
            )

            if existing:
                skipped += 1
                print(
                    "Already tracked as item "
                    f"{existing['id']}."
                )
                continue

            destination = staged_path(item)

            if destination.exists():
                if not destination.is_file():
                    raise RuntimeError(
                        "Staging path is not a regular file."
                    )

                expected_size = item.get("size")

                if (
                    expected_size is not None
                    and destination.stat().st_size
                    != int(expected_size)
                ):
                    raise RuntimeError(
                        "Existing staged file size differs "
                        "from Google Drive. "
                        "Manual review required."
                    )

                reused_staged += 1

            else:
                download_file(
                    drive,
                    file_id,
                    destination,
                )
                downloaded += 1

            sha256 = calculate_sha256(
                destination
            )

            previous = find_duplicate_by_sha256(
                sha256
            )

            status = (
                "duplicate"
                if previous is not None
                else "pending"
            )

            created_id = create_import_item(
                job_id=job_id,
                drive_file_id=file_id,
                original_filename=filename,
                sha256=sha256,
                local_file_path=str(destination),
                status=status,
            )

            if status == "duplicate":
                duplicates += 1
            else:
                newly_tracked += 1

            print(
                f"Tracked item {created_id}: {status}"
            )

        except Exception as error:
            failures += 1
            print(
                f"FAILED: {filename}: {error}"
            )

    all_items = get_import_items(
        job_id=job_id
    )

    pending_count = sum(
        row["status"] != "duplicate"
        for row in all_items
    )

    duplicate_count = sum(
        row["status"] == "duplicate"
        for row in all_items
    )

    if failures:
        set_job_failed(
            job_id=job_id,
            total_files=len(files),
            successful_files=pending_count,
            failed_files=failures,
            duplicate_files=duplicate_count,
        )
    else:
        complete_import_job(
            job_id=job_id,
            total_files=len(files),
            successful_files=pending_count,
            failed_files=0,
            duplicate_files=duplicate_count,
        )

    print("=" * 70)
    print(f"Import job ID:        {job_id}")
    print(f"Drive audio files:    {len(files)}")
    print(f"Downloaded:           {downloaded}")
    print(f"Reused staged:        {reused_staged}")
    print(f"New tracking records: {newly_tracked}")
    print(f"Duplicates this run:  {duplicates}")
    print(f"Already tracked:      {skipped}")
    print(f"Failed:               {failures}")
    print(f"IMPORT_JOB_ID={job_id}")

    if failures:
        raise RuntimeError(
            f"{failures} files failed during download. "
            "Retry with the same --run-id."
        )


if __name__ == "__main__":
    main()
