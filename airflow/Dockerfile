FROM apache/airflow:3.1.0

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

USER airflow

RUN pip install --no-cache-dir \
    mutagen \
    pillow \
    openpyxl==3.1.5
