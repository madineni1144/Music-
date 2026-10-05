CREATE TABLE IF NOT EXISTS import_jobs (
    id BIGSERIAL PRIMARY KEY,
    run_id VARCHAR(100) UNIQUE NOT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'running',
    total_files INTEGER NOT NULL DEFAULT 0,
    successful_files INTEGER NOT NULL DEFAULT 0,
    failed_files INTEGER NOT NULL DEFAULT 0,
    duplicate_files INTEGER NOT NULL DEFAULT 0,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS import_items (
    id BIGSERIAL PRIMARY KEY,
    job_id BIGINT REFERENCES import_jobs(id) ON DELETE CASCADE,

    drive_file_id VARCHAR(255),
    original_filename TEXT NOT NULL,
    sha256 CHAR(64),

    title TEXT,
    artist TEXT,
    album TEXT,

    local_file_path TEXT,
    song_id INTEGER,

    status VARCHAR(30) NOT NULL DEFAULT 'pending',
    failure_reason TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,

    playback_validated BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (drive_file_id)
);

CREATE INDEX IF NOT EXISTS idx_import_items_sha256
ON import_items (sha256);

CREATE INDEX IF NOT EXISTS idx_import_items_status
ON import_items (status);
