from datetime import datetime
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen
import json
import re

import psycopg2
from mutagen import File as MutagenFile
from mutagen.id3 import ID3
from PIL import Image
from io import BytesIO

from airflow import DAG
from airflow.operators.python import PythonOperator


MUSIC_FOLDER = Path("/opt/airflow/music")
COVER_FOLDER = Path("/opt/airflow/covers")

DB_CONFIG = {
    "host": "host.docker.internal",
    "port": 5432,
    "database": "music_app",
    "user": "postgres",
    "password": "momdad4567",
}


def clean_title(value):
    if not value:
        return ""

    title = str(value).strip()

    # Remove common source/site markers.
    patterns = [
        r"\s*::\s*SenSongsMp3\.(?:Com|Co)\s*$",
        r"\s*-\s*SenSongsMp3\.(?:Com|Co)\s*$",
        r"\s*-\s*My3Songs\.In\s*$",
        r"\s*\(www\.SenSongsMp3\.(?:co|com)\)\s*$",
        r"\s*-\s*\(www\.SenSongsMp3\.(?:co|com)\)\s*$",
    ]

    for pattern in patterns:
        title = re.sub(
            pattern,
            "",
            title,
            flags=re.IGNORECASE,
        ).strip()

    # Remove leading track numbers such as:
    # "01 - Aata"
    title = re.sub(
        r"^\s*\d{1,3}\s*[-._]\s*",
        "",
        title,
    ).strip()

    return title


def extract_metadata(file):
    metadata = {
        "title": clean_title(file.stem),
        "artist": "",
        "album": "",
        "year": None,
        "duration": None,
    }

    try:
        audio = MutagenFile(file, easy=True)

        if audio is None:
            print(f"No readable metadata: {file.name}")
            return metadata

        raw_title = (audio.get("title") or [""])[0]
        raw_artist = (audio.get("artist") or [""])[0]
        raw_album = (audio.get("album") or [""])[0]
        raw_date = (audio.get("date") or [""])[0]

        if raw_title:
            metadata["title"] = clean_title(raw_title)

        if raw_artist:
            metadata["artist"] = str(raw_artist).strip()

        if raw_album:
            metadata["album"] = str(raw_album).strip()

        if raw_date:
            match = re.search(r"\d{4}", str(raw_date))
            if match:
                metadata["year"] = int(match.group(0))

        info = getattr(audio, "info", None)

        if info and getattr(info, "length", None):
            metadata["duration"] = round(info.length)

    except Exception as exc:
        print(f"Metadata read failed for {file.name}: {exc}")

    if not metadata["title"]:
        metadata["title"] = clean_title(file.stem) or file.stem

    return metadata


def get_or_create_artist(cursor, artist_name):
    if not artist_name:
        return None

    artist_name = artist_name.strip()

    cursor.execute(
        """
        SELECT id
        FROM artists
        WHERE LOWER(name) = LOWER(%s)
        LIMIT 1
        """,
        (artist_name,),
    )

    row = cursor.fetchone()

    if row:
        return row[0]

    cursor.execute(
        """
        INSERT INTO artists (name)
        VALUES (%s)
        RETURNING id
        """,
        (artist_name,),
    )

    artist_id = cursor.fetchone()[0]

    print(
        f"Created artist: {artist_name} "
        f"(id {artist_id})"
    )

    return artist_id


def get_or_create_album(
    cursor,
    album_title,
    artist_id=None,
    year=None,
):
    if not album_title:
        return None

    album_title = album_title.strip()

    if artist_id is not None:
        cursor.execute(
            """
            SELECT id
            FROM albums
            WHERE LOWER(title) = LOWER(%s)
              AND artist_id = %s
            ORDER BY id
            LIMIT 1
            """,
            (album_title, artist_id),
        )
    else:
        cursor.execute(
            """
            SELECT id
            FROM albums
            WHERE LOWER(title) = LOWER(%s)
              AND artist_id IS NULL
            ORDER BY id
            LIMIT 1
            """,
            (album_title,),
        )

    row = cursor.fetchone()

    if row:
        album_id = row[0]

        # Fill missing year without overwriting an existing year.
        if year:
            cursor.execute(
                """
                UPDATE albums
                SET year = COALESCE(year, %s)
                WHERE id = %s
                """,
                (year, album_id),
            )

        return album_id

    cursor.execute(
        """
        INSERT INTO albums
            (title, artist_id, year)
        VALUES
            (%s, %s, %s)
        RETURNING id
        """,
        (
            album_title,
            artist_id,
            year,
        ),
    )

    album_id = cursor.fetchone()[0]

    print(
        f"Created album: {album_title} "
        f"(id {album_id})"
    )

    return album_id


def download_cover(
    song_id,
    title,
    artist="",
    album="",
    music_file=None,
):
    COVER_FOLDER.mkdir(
        parents=True,
        exist_ok=True,
    )

    cover_file = (
        COVER_FOLDER / f"{song_id}.jpg"
    )

    if (
        cover_file.exists()
        and cover_file.stat().st_size > 1000
    ):
        print(
            f"Cover already exists: "
            f"{cover_file.name}"
        )
        return f"/covers/{cover_file.name}"

    # Prefer artwork embedded directly in the MP3.
    # Existing valid covers are preserved by the check above.
    if music_file is not None:
        try:
            tags = ID3(music_file)

            pictures = [
                frame
                for frame in tags.values()
                if frame.FrameID == "APIC"
            ]

            if pictures:
                picture = pictures[0]

                with Image.open(
                    BytesIO(picture.data)
                ) as image:

                    # Always write a real JPEG because the backend
                    # serves covers as /covers/<song_id>.jpg.
                    if image.mode != "RGB":
                        if "A" in image.getbands():
                            background = Image.new(
                                "RGB",
                                image.size,
                                "white",
                            )

                            background.paste(
                                image,
                                mask=image.getchannel("A"),
                            )

                            image = background
                        else:
                            image = image.convert("RGB")

                    image.save(
                        cover_file,
                        format="JPEG",
                        quality=92,
                        optimize=True,
                    )

                if (
                    cover_file.exists()
                    and cover_file.stat().st_size > 1000
                ):
                    print(
                        "Embedded artwork extracted: "
                        f"{cover_file.name}"
                    )

                    return (
                        f"/covers/{cover_file.name}"
                    )

        except Exception as exc:
            print(
                "Embedded artwork unavailable: "
                f"{Path(music_file).name}: {exc}"
            )

    # No usable embedded artwork, so use iTunes.
    search_text = " ".join(
        str(x).strip()
        for x in [
            clean_title(title),
            artist,
            album,
        ]
        if x
    )

    if not search_text:
        return None

    print(f"Artwork search: {search_text}")

    url = (
        "https://itunes.apple.com/search"
        f"?term={quote(search_text)}"
        "&media=music&entity=song&limit=5"
    )

    try:
        request = Request(
            url,
            headers={
                "User-Agent": "AuraSound/1.0"
            },
        )

        with urlopen(
            request,
            timeout=15,
        ) as response:
            data = json.loads(
                response.read().decode("utf-8")
            )

        results = data.get("results", [])

        if not results:
            print(
                f"No artwork found: "
                f"{search_text}"
            )
            return None

        result = results[0]

        artwork_url = result.get(
            "artworkUrl100"
        )

        if not artwork_url:
            print(
                f"No artwork URL: "
                f"{search_text}"
            )
            return None

        print(
            "Artwork match: "
            f"{result.get('trackName')} - "
            f"{result.get('artistName')}"
        )

        artwork_url = artwork_url.replace(
            "/100x100bb.jpg",
            "/600x600bb.jpg",
        )

        with urlopen(
            Request(
                artwork_url,
                headers={
                    "User-Agent":
                    "AuraSound/1.0"
                },
            ),
            timeout=15,
        ) as response:
            image_data = response.read()

        if len(image_data) < 1000:
            print(
                "Artwork download too small: "
                f"{search_text}"
            )
            return None

        cover_file.write_bytes(image_data)

        print(
            f"Artwork downloaded: "
            f"{cover_file}"
        )

        return f"/covers/{cover_file.name}"

    except Exception as exc:
        print(
            "Artwork search failed for "
            f"'{search_text}': {exc}"
        )
        return None


def import_music():
    print("Scanning music folder...")

    MUSIC_FOLDER.mkdir(
        parents=True,
        exist_ok=True,
    )

    extensions = {
        ".mp3",
        ".flac",
        ".m4a",
        ".wav",
        ".aac",
        ".ogg",
    }

    files = sorted(
        file
        for file in MUSIC_FOLDER.iterdir()
        if (
            file.is_file()
            and file.suffix.lower()
            in extensions
        )
    )

    print(
        f"Found {len(files)} "
        "music file(s)."
    )

    conn = psycopg2.connect(**DB_CONFIG)
    cursor = conn.cursor()

    imported = 0
    updated = 0
    artwork_found = 0
    metadata_complete = 0

    try:
        for file in files:
            metadata = extract_metadata(file)

            title = metadata["title"]
            artist = metadata["artist"]
            album = metadata["album"]
            year = metadata["year"]
            duration = metadata["duration"]

            if (
                title
                and artist
                and album
                and duration
            ):
                metadata_complete += 1

            artist_id = get_or_create_artist(
                cursor,
                artist,
            )

            album_id = get_or_create_album(
                cursor,
                album,
                artist_id,
                year,
            )

            file_path = str(
                Path(
                    "/opt/musicapp/music/Songs"
                ) / file.name
            )

            cursor.execute(
                """
                SELECT id
                FROM songs
                WHERE file_path = %s
                """,
                (file_path,),
            )

            row = cursor.fetchone()

            if row:
                song_id = row[0]

                cursor.execute(
                    """
                    UPDATE songs
                    SET
                        title = %s,
                        artist_id = %s,
                        album_id = %s,
                        duration_seconds = %s,
                        file_format = %s,
                        file_size = %s
                    WHERE id = %s
                    """,
                    (
                        title,
                        artist_id,
                        album_id,
                        duration,
                        file.suffix
                            .lower()
                            .replace(".", "")
                            .upper(),
                        file.stat().st_size,
                        song_id,
                    ),
                )

                updated += 1

            else:
                cursor.execute(
                    """
                    INSERT INTO songs
                    (
                        title,
                        artist_id,
                        album_id,
                        duration_seconds,
                        file_path,
                        file_format,
                        file_size
                    )
                    VALUES
                    (
                        %s, %s, %s, %s,
                        %s, %s, %s
                    )
                    RETURNING id
                    """,
                    (
                        title,
                        artist_id,
                        album_id,
                        duration,
                        file_path,
                        file.suffix
                            .lower()
                            .replace(".", "")
                            .upper(),
                        file.stat().st_size,
                    ),
                )

                song_id = cursor.fetchone()[0]
                imported += 1

                print(
                    f"Imported: {file.name} "
                    f"(song id {song_id})"
                )

            cover_url = download_cover(
                song_id,
                title,
                artist,
                album,
                music_file=file,
            )

            if cover_url:
                artwork_found += 1

        conn.commit()

    except Exception:
        conn.rollback()
        raise

    finally:
        cursor.close()
        conn.close()

    print()
    print("===== IMPORT SUMMARY =====")
    print(
        f"Music files: {len(files)}"
    )
    print(
        f"New songs imported: {imported}"
    )
    print(
        f"Existing songs updated: {updated}"
    )
    print(
        "Complete embedded metadata: "
        f"{metadata_complete}"
    )
    print(
        f"Artwork found: {artwork_found}"
    )


with DAG(
    dag_id="music_trending_import",
    start_date=datetime(2026, 1, 1),
    schedule="0 */6 * * *",
    catchup=False,
    tags=[
        "music",
        "library",
        "authorized",
    ],
) as dag:

    import_task = PythonOperator(
        task_id="import_music",
        python_callable=import_music,
    )
