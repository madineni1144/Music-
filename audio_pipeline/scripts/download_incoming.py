from pathlib import Path
from datetime import datetime, timezone
import hashlib

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

from audio_pipeline.scripts.db import (
    create_import_job,
    complete_import_job,
    create_import_item,
    find_duplicate_by_drive_file_id,
    find_duplicate_by_sha256,
)


TOKEN_FILE = "/home/rk/google_drive_token.json"
INCOMING_FOLDER_ID = "1QZWFD51jh4_gtHOBfi7bauhJLB9_QTaC"
STAGING_DIR = Path("/opt/musicapp/staging/incoming")

SCOPES = ["https://www.googleapis.com/auth/drive"]


def calculate_sha256(file_path):
    sha256 = hashlib.sha256()

    with file_path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            sha256.update(chunk)

    return sha256.hexdigest()


def download_file(drive, drive_file_id, destination):
    temporary_destination = destination.with_name(
        destination.name + ".part"
    )

    request = drive.files().get_media(fileId=drive_file_id)

    try:
        with temporary_destination.open("wb") as output:
            downloader = MediaIoBaseDownload(output, request)

            done = False

            while not done:
                status, done = downloader.next_chunk()

                if status:
                    print(
                        f"  Progress: "
                        f"{int(status.progress() * 100)}%"
                    )

        temporary_destination.replace(destination)

    except Exception:
        if temporary_destination.exists():
            temporary_destination.unlink()

        raise


def main():
    run_id = datetime.now(timezone.utc).strftime(
        "drive-import-%Y%m%d-%H%M%S"
    )

    job_id = create_import_job(run_id)

    print(f"Import run: {run_id}")
    print(f"Import job ID: {job_id}")
    print()

    creds = Credentials.from_authorized_user_file(
        TOKEN_FILE,
        SCOPES,
    )

    drive = build("drive", "v3", credentials=creds)

    STAGING_DIR.mkdir(parents=True, exist_ok=True)

    files = drive.files().list(
        q=f"'{INCOMING_FOLDER_ID}' in parents and trashed=false",
        fields="files(id,name,mimeType,size)",
    ).execute().get("files", [])

    audio_files = [
        file
        for file in files
        if file.get("mimeType", "").startswith("audio/")
    ]

    total_files = len(audio_files)

    print(f"Found {total_files} audio file(s).")

    downloaded = 0
    reused_staged = 0
    tracked = 0
    skipped_drive = 0
    duplicate_audio = 0
    failed_files = 0

    for item in audio_files:
        drive_file_id = item["id"]
        filename = item["name"]
        destination = STAGING_DIR / filename

        print()
        print(f"Checking: {filename}")

        try:
            existing_drive_item = find_duplicate_by_drive_file_id(
                drive_file_id
            )

            if existing_drive_item:
                print("Skipped: Drive file already tracked.")
                print(
                    f"Existing import item ID: "
                    f"{existing_drive_item['id']}"
                )
                skipped_drive += 1
                continue

            if destination.exists():
                print("Using existing staged file.")
                reused_staged += 1

            else:
                print(f"Downloading: {filename}")

                download_file(
                    drive,
                    drive_file_id,
                    destination,
                )

                print(f"Saved: {destination}")
                downloaded += 1

            sha256 = calculate_sha256(destination)

            print(f"SHA256: {sha256}")

            existing_audio_item = find_duplicate_by_sha256(
                sha256
            )

            if existing_audio_item:
                print("Duplicate audio content detected.")
                print(
                    f"Existing import item ID: "
                    f"{existing_audio_item['id']}"
                )

                create_import_item(
                    job_id=job_id,
                    drive_file_id=drive_file_id,
                    original_filename=filename,
                    sha256=sha256,
                    local_file_path=str(destination),
                    status="duplicate",
                )

                duplicate_audio += 1
                tracked += 1
                continue

            item_id = create_import_item(
                job_id=job_id,
                drive_file_id=drive_file_id,
                original_filename=filename,
                sha256=sha256,
                local_file_path=str(destination),
                status="pending",
            )

            print(f"Tracked as import item ID: {item_id}")
            tracked += 1

        except Exception as error:
            failed_files += 1

            print(
                f"FAILED: {filename}: "
                f"{error}"
            )

    successful_files = (
        total_files
        - failed_files
        - duplicate_audio
    )

    complete_import_job(
        job_id=job_id,
        total_files=total_files,
        successful_files=successful_files,
        failed_files=failed_files,
        duplicate_files=duplicate_audio,
    )

    print()
    print("Download/tracking stage complete.")
    print(f"Import run: {run_id}")
    print(f"Import job ID: {job_id}")
    print(f"Total Drive files: {total_files}")
    print(f"Downloaded: {downloaded}")
    print(f"Reused staged files: {reused_staged}")
    print(f"New tracking records: {tracked}")
    print(f"Skipped existing Drive files: {skipped_drive}")
    print(f"Duplicate audio files: {duplicate_audio}")
    print(f"Failed files: {failed_files}")
    print(f"Successful files: {successful_files}")
    print("Job status: completed")


if __name__ == "__main__":
    main()
