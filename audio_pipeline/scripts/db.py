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


if __name__ == "__main__":
    test_connection()
