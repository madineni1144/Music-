const express = require("express");
const cors = require("cors");
const path = require("path");
const { Pool } = require("pg");
require("dotenv").config({ path: "/opt/musicapp/app/config/.env" });

const app = express();

const PORT = 3000;
const FRONTEND_DIR = "/opt/musicapp/app/frontend";
const MUSIC_DIR = "/opt/musicapp/music/Songs";
const COVERS_DIR = "/opt/musicapp/covers";

app.use(cors());
app.use(express.json());

app.use(express.static(FRONTEND_DIR));
app.use("/music", express.static(MUSIC_DIR));
app.use("/covers", express.static(COVERS_DIR));

const pool = new Pool({
host: process.env.DB_HOST,
port: process.env.DB_PORT,
database: process.env.DB_NAME,
user: process.env.DB_USER,
password: process.env.DB_PASSWORD,
max: 10,
idleTimeoutMillis: 30000,
connectionTimeoutMillis: 5000
});

/* =========================
ROOT
========================= */

app.get("/", (req, res) => {
res.sendFile(
path.join(FRONTEND_DIR, "index.html")
);
});

/* =========================
HEALTH
========================= */

app.get("/api/health", async (req, res) => {

try {

const result =
  await pool.query("SELECT NOW() AS time");

res.json({
  success: true,
  status: "ok",
  database: "connected",
  time: result.rows[0].time
});

} catch (error) {

console.error(
  "Health check error:",
  error.message
);

res.status(503).json({
  success: false,
  status: "error",
  database: "disconnected",
  error: error.message
});

}

});

/* =========================
DB TEST
========================= */

app.get("/api/db-test", async (req, res) => {

try {

const result =
  await pool.query(
    "SELECT NOW() AS current_time"
  );

res.json({
  connected: true,
  database: process.env.DB_NAME,
  time: result.rows[0].current_time
});

} catch (error) {

console.error(
  "Database connection error:",
  error.message
);

res.status(500).json({
  connected: false,
  error: error.message
});

}

});

/* =========================
SONGS
========================= */

app.get("/api/songs", async (req, res) => {

try {

const search =
  typeof req.query.search === "string"
    ? req.query.search.trim()
    : "";

const artist =
  typeof req.query.artist === "string"
    ? req.query.artist.trim()
    : "";

const album =
  typeof req.query.album === "string"
    ? req.query.album.trim()
    : "";

let limit =
  Number.parseInt(
    req.query.limit,
    10
  );

let offset =
  Number.parseInt(
    req.query.offset,
    10
  );

if (
  !Number.isInteger(limit) ||
  limit <= 0
) {
  limit = 1000000;
}

if (limit > 1000000) {
  limit = 1000000;
}

if (
  !Number.isInteger(offset) ||
  offset < 0
) {
  offset = 0;
}

const conditions = [];
const values = [];

let parameter = 1;


if (search !== "") {

  conditions.push(
    "(" +
    "songs.title ILIKE $" +
    parameter +
    " OR artists.name ILIKE $" +
    parameter +
    " OR albums.title ILIKE $" +
    parameter +
    ")"
  );

  values.push(
    "%" + search + "%"
  );

  parameter++;

}


if (artist !== "") {

  conditions.push(
    "artists.name ILIKE $" +
    parameter
  );

  values.push(
    "%" + artist + "%"
  );

  parameter++;

}


if (album !== "") {

  conditions.push(
    "albums.title ILIKE $" +
    parameter
  );

  values.push(
    "%" + album + "%"
  );

  parameter++;

}


const whereClause =
  conditions.length > 0
    ? "WHERE " +
      conditions.join(" AND ")
    : "";


values.push(limit);
const limitParameter = parameter;
parameter++;

values.push(offset);
const offsetParameter = parameter;


const result =
  await pool.query(
    `
    SELECT
      songs.id,
      songs.title,
      songs.artist_id,
      artists.name AS artist,
      songs.album_id,
      albums.title AS album,
      songs.track_number,
      songs.duration_seconds,
      songs.file_path,
      songs.file_format,
      songs.file_size,
      songs.created_at,
      '/covers/' || songs.id || '.jpg' AS cover_art

    FROM songs

    LEFT JOIN artists
      ON songs.artist_id = artists.id

    LEFT JOIN albums
      ON songs.album_id = albums.id

    ${whereClause}

    ORDER BY songs.id ASC

    LIMIT $${limitParameter}
    OFFSET $${offsetParameter}
    `,
    values
  );

res.json(result.rows);

} catch (error) {

console.error(
  "Songs API error:",
  error.message
);

res.status(500).json({
  error: "Unable to load songs",
  details: error.message
});

}

});

/* =========================
SONG COUNT
========================= */

app.get("/api/songs/count", async (req, res) => {

try {

const result =
  await pool.query(
    "SELECT COUNT(*) AS count FROM songs"
  );

res.json({
  success: true,
  count: Number(result.rows[0].count)
});

} catch (error) {

res.status(500).json({
  success: false,
  error: error.message
});

}

});

/* =========================
SINGLE SONG
========================= */

app.get("/api/songs/:id", async (req, res) => {

try {

const id =
  Number.parseInt(
    req.params.id,
    10
  );

if (!Number.isInteger(id)) {

  return res.status(400).json({
    success: false,
    error: "Invalid song ID"
  });

}

const result =
  await pool.query(
    `
    SELECT
      songs.id,
      songs.title,
      songs.artist_id,
      artists.name AS artist,
      songs.album_id,
      albums.title AS album,
      songs.track_number,
      songs.duration_seconds,
      songs.file_path,
      songs.file_format,
      songs.file_size,
      songs.created_at

    FROM songs

    LEFT JOIN artists
      ON songs.artist_id = artists.id

    LEFT JOIN albums
      ON songs.album_id = albums.id

    WHERE songs.id = $1
    `,
    [id]
  );

if (!result.rows.length) {

  return res.status(404).json({
    success: false,
    error: "Song not found"
  });

}

res.json({
  success: true,
  data: result.rows[0]
});

} catch (error) {

console.error(
  "Single song API error:",
  error.message
);

res.status(500).json({
  success: false,
  error: error.message
});

}

});

/* =========================
ARTISTS
========================= */

app.get("/api/artists", async (req, res) => {

try {

const result =
  await pool.query(
    `
    SELECT
      artists.id,
      artists.name,
      COUNT(songs.id) AS song_count

    FROM artists

    LEFT JOIN songs
      ON songs.artist_id = artists.id

    GROUP BY
      artists.id,
      artists.name

    ORDER BY
      artists.name ASC
    `
  );

res.json(result.rows);

} catch (error) {

console.error(
  "Artists API error:",
  error.message
);

res.status(500).json({
  success: false,
  error: error.message
});

}

});

/* =========================
ALBUMS
========================= */

app.get("/api/albums", async (req, res) => {

try {

const result =
  await pool.query(
    `
    SELECT
      albums.id,
      albums.title,
      albums.artist_id,
      artists.name AS artist,
      albums.year,
      albums.cover_path,
      COUNT(songs.id) AS song_count,
      '/covers/' || MIN(songs.id) || '.jpg' AS cover_art

    FROM albums

    LEFT JOIN artists
      ON albums.artist_id = artists.id

    LEFT JOIN songs
      ON songs.album_id = albums.id

    GROUP BY
      albums.id,
      albums.title,
      albums.artist_id,
      artists.name,
      albums.year,
      albums.cover_path

    ORDER BY
      albums.title ASC
    `
  );

res.json(result.rows);

} catch (error) {

console.error(
  "Albums API error:",
  error.message
);

res.status(500).json({
  success: false,
  error: error.message
});

}

});

/* =========================
STATS
========================= */

app.get("/api/stats", async (req, res) => {

try {

const result =
  await pool.query(
    `
    SELECT
      (SELECT COUNT(*) FROM songs) AS songs,
      (SELECT COUNT(*) FROM artists) AS artists,
      (SELECT COUNT(*) FROM albums) AS albums,
      (SELECT COUNT(*) FROM playlists) AS playlists
    `
  );

res.json({
  success: true,
  data: {
    songs: Number(result.rows[0].songs),
    artists: Number(result.rows[0].artists),
    albums: Number(result.rows[0].albums),
    playlists: Number(result.rows[0].playlists)
  }
});

} catch (error) {

console.error(
  "Stats API error:",
  error.message
);

res.status(500).json({
  success: false,
  error: error.message
});

}

});

/* =========================
PLAYLISTS
========================= */

app.get("/api/playlists", async (req, res) => {

try {

const result =
  await pool.query(
    `
    SELECT
      p.id,
      p.name,
      p.description,
      p.created_at,
      COUNT(ps.song_id) AS song_count

    FROM playlists p

    LEFT JOIN playlist_songs ps
      ON p.id = ps.playlist_id

    GROUP BY
      p.id,
      p.name,
      p.description,
      p.created_at

    ORDER BY
      p.id ASC
    `
  );

res.json({
  success: true,
  data: result.rows
});

} catch (error) {

console.error(
  "Playlists API error:",
  error.message
);

res.status(500).json({
  success: false,
  error: "Unable to load playlists",
  details: error.message
});

}

});

/* =========================
CREATE PLAYLIST
========================= */

app.post("/api/playlists", async (req, res) => {

try {

const name =
  typeof req.body.name === "string"
    ? req.body.name.trim()
    : "";

const description =
  typeof req.body.description === "string"
    ? req.body.description.trim()
    : "";

if (!name) {

  return res.status(400).json({
    success: false,
    error: "Playlist name is required"
  });

}

const result =
  await pool.query(
    `
    INSERT INTO playlists
      (name, description)

    VALUES
      ($1, $2)

    RETURNING
      id,
      name,
      description,
      created_at
    `,
    [name, description]
  );

res.status(201).json({
  success: true,
  data: result.rows[0]
});

} catch (error) {

console.error(
  "Create playlist error:",
  error.message
);

res.status(500).json({
  success: false,
  error: "Unable to create playlist",
  details: error.message
});

}

});

/* =========================
PLAYLIST SONGS
========================= */

app.get(
"/api/playlists/:id/songs",
async (req, res) => {

try {

  const playlistId =
    Number.parseInt(
      req.params.id,
      10
    );

  if (!Number.isInteger(playlistId)) {

    return res.status(400).json({
      success: false,
      error: "Invalid playlist ID"
    });

  }

  const result =
    await pool.query(
      `
      SELECT
        songs.id,
        songs.title,
        artists.name AS artist,
        albums.title AS album,
        songs.file_path,
        songs.duration_seconds,
        songs.file_format

      FROM playlist_songs ps

      JOIN songs
        ON songs.id = ps.song_id

      LEFT JOIN artists
        ON songs.artist_id = artists.id

      LEFT JOIN albums
        ON songs.album_id = albums.id

      WHERE ps.playlist_id = $1

      ORDER BY ps.id ASC
      `,
      [playlistId]
    );

  res.json({
    success: true,
    data: result.rows
  });

} catch (error) {

  console.error(
    "Playlist songs API error:",
    error.message
  );

  res.status(500).json({
    success: false,
    error: "Unable to load playlist songs",
    details: error.message
  });

}

}
);

/* =========================
ADD SONG TO PLAYLIST
========================= */

app.post(
"/api/playlists/:id/songs",
async (req, res) => {

try {

  const playlistId =
    Number.parseInt(
      req.params.id,
      10
    );

  const songId =
    Number.parseInt(
      req.body.song_id,
      10
    );

  if (
    !Number.isInteger(playlistId) ||
    !Number.isInteger(songId)
  ) {

    return res.status(400).json({
      success: false,
      error:
        "Valid playlist ID and song ID are required"
    });

  }

  const result =
    await pool.query(
      `
      INSERT INTO playlist_songs
        (playlist_id, song_id)

      VALUES
        ($1, $2)

      ON CONFLICT DO NOTHING

      RETURNING
        playlist_id,
        song_id
      `,
      [playlistId, songId]
    );

  res.status(201).json({
    success: true,
    added: result.rows.length > 0,
    data: result.rows[0] || null
  });

} catch (error) {

  console.error(
    "Add playlist song error:",
    error.message
  );

  res.status(500).json({
    success: false,
    error:
      "Unable to add song to playlist",
    details: error.message
  });

}

}
);

/* =========================
REMOVE SONG FROM PLAYLIST
========================= */

app.delete(
"/api/playlists/:id/songs/:songId",
async (req, res) => {

try {

  const playlistId =
    Number.parseInt(
      req.params.id,
      10
    );

  const songId =
    Number.parseInt(
      req.params.songId,
      10
    );

  if (
    !Number.isInteger(playlistId) ||
    !Number.isInteger(songId)
  ) {

    return res.status(400).json({
      success: false,
      error:
        "Invalid playlist ID or song ID"
    });

  }

  const result =
    await pool.query(
      `
      DELETE FROM playlist_songs

      WHERE playlist_id = $1
        AND song_id = $2

      RETURNING
        playlist_id,
        song_id
      `,
      [playlistId, songId]
    );

  res.json({
    success: true,
    removed: result.rows.length > 0,
    data: result.rows[0] || null
  });

} catch (error) {

  console.error(
    "Remove playlist song error:",
    error.message
  );

  res.status(500).json({
    success: false,
    error:
      "Unable to remove song from playlist",
    details: error.message
  });

}

}
);

/* =========================
DELETE PLAYLIST
========================= */

app.delete(
"/api/playlists/:id",
async (req, res) => {

try {

  const playlistId =
    Number.parseInt(
      req.params.id,
      10
    );

  if (!Number.isInteger(playlistId)) {

    return res.status(400).json({
      success: false,
      error: "Invalid playlist ID"
    });

  }

  await pool.query(
    `
    DELETE FROM playlist_songs
    WHERE playlist_id = $1
    `,
    [playlistId]
  );

  const result =
    await pool.query(
      `
      DELETE FROM playlists
      WHERE id = $1

      RETURNING
        id,
        name
      `,
      [playlistId]
    );

  if (!result.rows.length) {

    return res.status(404).json({
      success: false,
      error: "Playlist not found"
    });

  }

  res.json({
    success: true,
    data: result.rows[0]
  });

} catch (error) {

  console.error(
    "Delete playlist error:",
    error.message
  );

  res.status(500).json({
    success: false,
    error:
      "Unable to delete playlist",
    details: error.message
  });

}

}
);

/* =========================
404
========================= */

app.use((req, res) => {

res.status(404).json({
success: false,
error: "API endpoint not found",
path: req.path
});

});

/* =========================
SERVER
========================= */

app.listen(
PORT,
"0.0.0.0",
() => {

console.log("");
console.log("======================================");
console.log("       MUSIC APP API SERVER");
console.log("======================================");
console.log("Port:      " + PORT);
console.log(
  "Local:     http://127.0.0.1:" + PORT
);
console.log(
  "Wi-Fi:     http://192.168.4.204:" + PORT
);
console.log(
  "Tailscale: http://100.83.79.17:" + PORT
);
console.log("======================================");
console.log("");

}
);
