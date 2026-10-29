"""
Madineni Music App - Automated Audio Import Pipeline

Google Drive -> Ubuntu -> PostgreSQL -> Playback
-> Google Drive Archive -> Excel -> Gmail

Schedule: 12 AM, 5 AM, 10 AM, 3 PM, 8 PM
Timezone: America/New_York
"""

import hashlib
import re
import subprocess
import sys
from datetime import timedelta

import pendulum
from airflow import DAG
from airflow.providers.standard.operators.python import PythonOperator


PACKAGE = "audio_pipeline.scripts"

PIPELINE_STAGES = [
    "validate_audio",
    "normalize_metadata",
    "store_audio",
    "register_songs",
    "playback_validate",
    "archive_drive",
    "generate_report",
    "upload_report",
    "send_email_summary",
]


def run_script(script, arguments):
    command = [
        sys.executable,
        "-m",
        f"{PACKAGE}.{script}",
        *arguments,
    ]

    print(f"Starting: {script}", flush=True)

    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )

    if result.stdout:
        print(result.stdout, flush=True)

    if result.returncode != 0:
        raise RuntimeError(
            f"{script} failed with exit code "
            f"{result.returncode}"
        )

    return result.stdout or ""


def download_incoming(**context):
    airflow_run_id = context["dag_run"].run_id

    digest = hashlib.sha256(
        airflow_run_id.encode("utf-8")
    ).hexdigest()[:24]

    import_run_id = f"airflow-music-{digest}"

    output = run_script(
        "download_incoming",
        ["--run-id", import_run_id],
    )

    matches = re.findall(
        r"^IMPORT_JOB_ID=(\d+)\s*$",
        output,
        flags=re.MULTILINE,
    )

    if not matches:
        raise RuntimeError(
            "Downloader did not return IMPORT_JOB_ID"
        )

    job_id = int(matches[-1])

    print(f"IMPORT_JOB_ID={job_id}", flush=True)

    return job_id


def execute_stage(script_name, **context):
    job_id = context["ti"].xcom_pull(
        task_ids="download_incoming"
    )

    if job_id is None:
        raise RuntimeError(
            "Missing import job ID"
        )

    run_script(
        script_name,
        ["--job-id", str(int(job_id))],
    )


with DAG(
    dag_id="madineni_audio_pipeline",
    description="Madineni automated audio import pipeline",
    start_date=pendulum.datetime(
        2026, 10, 8,
        tz="America/New_York",
    ),
    schedule="0 0,5,10,15,20 * * *",
    catchup=False,
    max_active_runs=1,
    is_paused_upon_creation=True,
    default_args={
        "owner": "musicapp",
        "retries": 2,
        "retry_delay": timedelta(minutes=10),
    },
    tags=["musicapp", "audio-pipeline"],
) as dag:

    download_task = PythonOperator(
        task_id="download_incoming",
        python_callable=download_incoming,
    )

    previous_task = download_task

    for stage in PIPELINE_STAGES:
        task = PythonOperator(
            task_id=stage,
            python_callable=execute_stage,
            op_kwargs={"script_name": stage},
            retries=0 if stage == "send_email_summary" else 2,
        )

        previous_task >> task
        previous_task = task
