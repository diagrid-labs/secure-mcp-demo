import os

import psycopg2


def get_connection():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "demo"),
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
    )
