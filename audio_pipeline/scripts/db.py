import os

import psycopg2
from dotenv import load_dotenv


ENV_FILE = "/etc/musicapp.env"


def get_connection():
    load_dotenv(ENV_FILE)

    required = [
        "DB_HOST",
        "DB_PORT",
        "DB_NAME",
        "DB_USER",
        "DB_PASSWORD",
    ]

    missing = [name for name in required if not os.getenv(name)]

    if missing:
        raise RuntimeError(
            f"Missing database environment variables: {', '.join(missing)}"
        )

    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        port=os.getenv("DB_PORT"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
    )


def test_connection():
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT current_database();")
            database = cursor.fetchone()[0]

        print(f"PostgreSQL connection: OK ({database})")

    finally:
        connection.close()


def create_import_job(run_id):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO import_jobs (
                    run_id,
                    status
                )
                VALUES (%s, %s)
                RETURNING id;
                """,
                (
                    run_id,
                    "running",
                ),
            )

            job_id = cursor.fetchone()[0]

        connection.commit()
        return job_id

    except Exception:
        connection.rollback()
        raise

    finally:
        connection.close()


def complete_import_job(
    job_id,
    total_files,
    successful_files=0,
    failed_files=0,
    duplicate_files=0,
):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                UPDATE import_jobs
                SET
                    status = %s,
                    total_files = %s,
                    successful_files = %s,
                    failed_files = %s,
                    duplicate_files = %s,
                    completed_at = NOW()
                WHERE id = %s;
                """,
                (
                    "completed",
                    total_files,
                    successful_files,
                    failed_files,
                    duplicate_files,
                    job_id,
                ),
            )

        connection.commit()

    except Exception:
        connection.rollback()
        raise

    finally:
        connection.close()


def create_import_item(
    job_id,
    drive_file_id,
    original_filename,
    sha256=None,
    title=None,
    artist=None,
    album=None,
    local_file_path=None,
    status="pending",
):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO import_items (
                    job_id,
                    drive_file_id,
                    original_filename,
                    sha256,
                    title,
                    artist,
                    album,
                    local_file_path,
                    status
                )
                VALUES (
                    %s, %s, %s, %s, %s,
                    %s, %s, %s, %s
                )
                RETURNING id;
                """,
                (
                    job_id,
                    drive_file_id,
                    original_filename,
                    sha256,
                    title,
                    artist,
                    album,
                    local_file_path,
                    status,
                ),
            )

            item_id = cursor.fetchone()[0]

        connection.commit()
        return item_id

    except Exception:
        connection.rollback()
        raise

    finally:
        connection.close()


def find_duplicate_by_sha256(sha256):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT
                    id,
                    job_id,
                    drive_file_id,
                    original_filename,
                    sha256,
                    status
                FROM import_items
                WHERE sha256 = %s
                ORDER BY id
                LIMIT 1;
                """,
                (sha256,),
            )

            row = cursor.fetchone()

        if row is None:
            return None

        return {
            "id": row[0],
            "job_id": row[1],
            "drive_file_id": row[2],
            "original_filename": row[3],
            "sha256": row[4],
            "status": row[5],
        }

    finally:
        connection.close()


def find_duplicate_by_drive_file_id(drive_file_id):
    connection = get_connection()

    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT
                    id,
                    job_id,
                    drive_file_id,
                    original_filename,
                    sha256,
                    status
                FROM import_items
                WHERE drive_file_id = %s
                ORDER BY id
                LIMIT 1;
                """,
                (drive_file_id,),
            )

            row = cursor.fetchone()

        if row is None:
            return None

        return {
            "id": row[0],
            "job_id": row[1],
            "drive_file_id": row[2],
            "original_filename": row[3],
            "sha256": row[4],
            "status": row[5],
        }

    finally:
        connection.close()


if __name__ == "__main__":
    test_connection()
