from pathlib import Path

from google.oauth2.credentials import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseDownload

TOKEN_FILE = "/home/rk/google_drive_token.json"
INCOMING_FOLDER_ID = "1QZWFD51jh4_gtHOBfi7bauhJLB9_QTaC"
STAGING_DIR = Path("/opt/musicapp/staging/incoming")

SCOPES = ["https://www.googleapis.com/auth/drive"]


def main():
    creds = Credentials.from_authorized_user_file(TOKEN_FILE, SCOPES)
    drive = build("drive", "v3", credentials=creds)

    files = drive.files().list(
        q=f"'{INCOMING_FOLDER_ID}' in parents and trashed=false",
        fields="files(id,name,mimeType,size)"
    ).execute().get("files", [])

    audio_files = [
        f for f in files
        if f.get("mimeType", "").startswith("audio/")
    ]

    print(f"Found {len(audio_files)} audio file(s).")

    for item in audio_files:
        destination = STAGING_DIR / item["name"]

        print(f"Downloading: {item['name']}")

        request = drive.files().get_media(fileId=item["id"])

        with destination.open("wb") as output:
            downloader = MediaIoBaseDownload(output, request)

            done = False
            while not done:
                status, done = downloader.next_chunk()
                if status:
                    print(f"  Progress: {int(status.progress() * 100)}%")

        print(f"Saved: {destination}")

    print("Download complete.")


if __name__ == "__main__":
    main()
