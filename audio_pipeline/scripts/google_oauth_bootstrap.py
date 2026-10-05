from pathlib import Path

from google_auth_oauthlib.flow import InstalledAppFlow

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

    TOKEN_FILE.write_text(credentials.to_json())
    TOKEN_FILE.chmod(0o600)

    print(f"Google Drive authentication successful.")
    print(f"Token saved securely to: {TOKEN_FILE}")


if __name__ == "__main__":
    main()
