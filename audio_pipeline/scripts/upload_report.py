import argparse
import os
from pathlib import Path

from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

from audio_pipeline.scripts.db import get_import_job


TOKEN_FILE = Path(
    os.getenv(
        "GOOGLE_DRIVE_TOKEN_FILE",
        "/home/rk/google_drive_token.json",
    )
)

REPORT_DIR = Path("/opt/musicapp/reports")

EXCEL_FOLDER_ID = (
    "180BvxOQaclFXhFNBN0UHX4B5o2thALhL"
)

SCOPES = [
    "https://www.googleapis.com/auth/drive",
]

EXCEL_MIME_TYPE = (
    "application/vnd.openxmlformats-officedocument."
    "spreadsheetml.sheet"
)


def parse_arguments():
    parser = argparse.ArgumentParser(
        description=(
            "Upload a music import Excel report "
            "to Google Drive."
        )
    )

    parser.add_argument(
        "--job-id",
        type=int,
        default=None,
        help=(
            "Upload the deterministic report "
            "for this import job."
        ),
    )

    return parser.parse_args()


def get_drive_service():
    if not TOKEN_FILE.is_file():
        raise FileNotFoundError(
            "Google Drive token not found: "
            f"{TOKEN_FILE}"
        )

    credentials = (
        Credentials.from_authorized_user_file(
            str(TOKEN_FILE),
            SCOPES,
        )
    )

    if (
        credentials.expired
        and credentials.refresh_token
    ):
        print(
            "Google access token expired. "
            "Refreshing..."
        )

        credentials.refresh(
            Request()
        )

        TOKEN_FILE.write_text(
            credentials.to_json()
        )

        TOKEN_FILE.chmod(
            0o600
        )

        print(
            "Google access token refreshed "
            "successfully."
        )

    if not credentials.valid:
        raise RuntimeError(
            "Google Drive credentials are not "
            "valid. OAuth authorization is "
            "required."
        )

    return build(
        "drive",
        "v3",
        credentials=credentials,
    )


def get_report(job_id=None):
    if not REPORT_DIR.is_dir():
        raise FileNotFoundError(
            "Report directory not found: "
            f"{REPORT_DIR}"
        )

    if job_id is not None:
        report_path = REPORT_DIR / (
            "music_import_report_"
            f"job_{job_id}.xlsx"
        )

        if not report_path.is_file():
            raise FileNotFoundError(
                "Job report not found: "
                f"{report_path}"
            )

        return report_path

    reports = list(
        REPORT_DIR.glob(
            "music_import_report_*.xlsx"
        )
    )

    if not reports:
        raise FileNotFoundError(
            "No Excel reports found in "
            f"{REPORT_DIR}"
        )

    return max(
        reports,
        key=lambda path: (
            path.stat().st_mtime
        ),
    )


def escape_drive_query_value(value):
    return (
        value
        .replace("\\", "\\\\")
        .replace("'", "\\'")
    )


def find_existing_drive_report(
    drive,
    report_name,
):
    safe_name = (
        escape_drive_query_value(
            report_name
        )
    )

    query = (
        f"name = '{safe_name}' "
        f"and '{EXCEL_FOLDER_ID}' in parents "
        "and trashed = false"
    )

    matches = []

    page_token = None

    while True:
        response = (
            drive.files()
            .list(
                q=query,
                spaces="drive",
                fields=(
                    "nextPageToken,"
                    "files("
                    "id,name,parents,size,"
                    "modifiedTime,webViewLink"
                    ")"
                ),
                pageToken=page_token,
                pageSize=100,
            )
            .execute()
        )

        matches.extend(
            response.get(
                "files",
                [],
            )
        )

        page_token = response.get(
            "nextPageToken"
        )

        if not page_token:
            break

    if len(matches) > 1:
        ids = ", ".join(
            item["id"]
            for item in matches
        )

        raise RuntimeError(
            "Multiple Google Drive reports "
            f"already exist with name "
            f"'{report_name}' in the EXCEL "
            f"folder. File IDs: {ids}. "
            "Refusing to choose one "
            "automatically."
        )

    if not matches:
        return None

    return matches[0]


def create_drive_report(
    drive,
    report_path,
):
    metadata = {
        "name": report_path.name,
        "parents": [
            EXCEL_FOLDER_ID
        ],
    }

    media = MediaFileUpload(
        str(report_path),
        mimetype=EXCEL_MIME_TYPE,
        resumable=True,
    )

    return (
        drive.files()
        .create(
            body=metadata,
            media_body=media,
            fields=(
                "id,name,parents,size,"
                "modifiedTime,webViewLink"
            ),
        )
        .execute()
    )


def update_drive_report(
    drive,
    drive_file_id,
    report_path,
):
    media = MediaFileUpload(
        str(report_path),
        mimetype=EXCEL_MIME_TYPE,
        resumable=True,
    )

    return (
        drive.files()
        .update(
            fileId=drive_file_id,
            media_body=media,
            fields=(
                "id,name,parents,size,"
                "modifiedTime,webViewLink"
            ),
        )
        .execute()
    )


def upload_report(job_id=None):
    job = None

    if job_id is not None:
        job = get_import_job(
            job_id
        )

        if job is None:
            raise RuntimeError(
                f"Import job {job_id} "
                "does not exist."
            )

    report_path = get_report(
        job_id=job_id
    )

    if (
        report_path.stat().st_size
        == 0
    ):
        raise RuntimeError(
            f"Report is empty: "
            f"{report_path}"
        )

    drive = get_drive_service()

    existing = (
        find_existing_drive_report(
            drive,
            report_path.name,
        )
    )

    if existing is None:
        result = create_drive_report(
            drive,
            report_path,
        )

        action = "CREATED"

    else:
        result = update_drive_report(
            drive,
            existing["id"],
            report_path,
        )

        action = "UPDATED"

    print("=" * 70)
    print(
        "GOOGLE DRIVE REPORT UPLOAD"
    )
    print("=" * 70)

    if job is not None:
        print(
            f"Import job ID:   "
            f"{job['id']}"
        )
        print(
            f"Import run:      "
            f"{job['run_id']}"
        )

    print(
        f"Action:          {action}"
    )
    print(
        f"Local report:    "
        f"{report_path}"
    )
    print(
        f"Drive file name: "
        f"{result.get('name')}"
    )
    print(
        f"Drive file ID:   "
        f"{result.get('id')}"
    )
    print(
        f"Drive folder ID: "
        f"{EXCEL_FOLDER_ID}"
    )
    print(
        f"Drive size:      "
        f"{result.get('size')} bytes"
    )
    print(
        f"Drive link:      "
        f"{result.get('webViewLink')}"
    )
    print()
    print(
        "Excel report synchronized "
        "successfully."
    )


def main():
    args = parse_arguments()

    upload_report(
        job_id=args.job_id
    )


if __name__ == "__main__":
    main()
