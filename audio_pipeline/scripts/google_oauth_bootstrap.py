from pathlib import Path

from google_auth_oauthlib.flow import InstalledAppFlow

from audio_pipeline.scripts.secure_files import write_private_text

CLIENT_SECRET_FILE = Path("/home/rk/google_oauth.json")
TOKEN_FILE = Path("/home/rk/google_drive_token.json")

SCOPES = ["https://www.googleapis.com/auth/drive"]


def main():
    flow = InstalledAppFlow.from_client_secrets_file(
        CLIENT_SECRET_FILE,
        SCOPES,
    )

    credentials = flow.run_local_server(
        host="localhost",
        port=0,
        open_browser=False,
    )

    write_private_text(TOKEN_FILE, credentials.to_json())

    print(f"Google Drive authentication successful.")
    print(f"Token saved securely to: {TOKEN_FILE}")


if __name__ == "__main__":
    main()
