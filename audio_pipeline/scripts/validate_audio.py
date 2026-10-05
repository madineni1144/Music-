from pathlib import Path
import hashlib
import json
import subprocess


STAGING_DIR = Path("/opt/musicapp/staging/incoming")


def calculate_sha256(file_path):
    sha256 = hashlib.sha256()

    with file_path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            sha256.update(chunk)

    return sha256.hexdigest()


def probe_audio(file_path):
    command = [
        "ffprobe",
        "-v", "error",
        "-show_entries",
        "format=duration,size:format_tags=title,artist,album",
        "-of", "json",
        str(file_path),
    ]

    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        return None, result.stderr.strip()

    return json.loads(result.stdout), None


def decode_audio(file_path):
    command = [
        "ffmpeg",
        "-v", "error",
        "-i", str(file_path),
        "-f", "null",
        "-",
    ]

    result = subprocess.run(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )

    decoder_output = result.stderr.strip()

    if result.returncode != 0:
        return "FAILED", decoder_output

    if decoder_output:
        return "WARNING", decoder_output

    return "OK", None


def main():
    audio_files = sorted(STAGING_DIR.glob("*.mp3"))

    print(f"Found {len(audio_files)} MP3 file(s).")

    for file_path in audio_files:
        print()
        print("=" * 60)
        print(f"File: {file_path.name}")

        sha256 = calculate_sha256(file_path)
        print(f"SHA256: {sha256}")

        metadata, error = probe_audio(file_path)

        if error:
            print("FFprobe: FAILED")
            print(f"Reason: {error}")
            continue

        audio_format = metadata.get("format", {})
        tags = audio_format.get("tags", {})

        print("FFprobe: OK")
        print(f"Duration: {audio_format.get('duration')}")
        print(f"Size: {audio_format.get('size')}")
        print(f"Title: {tags.get('title')}")
        print(f"Artist: {tags.get('artist')}")
        print(f"Album: {tags.get('album')}")

        decode_status, decode_message = decode_audio(file_path)

        print(f"Full Decode: {decode_status}")

        if decode_message:
            print(f"Decoder message: {decode_message}")


if __name__ == "__main__":
    main()
