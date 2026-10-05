from pathlib import Path
import re

path = Path("/opt/musicapp/app/frontend/index.html")
old = path.read_text()

m = re.search(r"<script>(.*?)</script>\s*</body>", old, re.S)
if not m:
    raise SystemExit("Could not find existing JavaScript. No changes made.")

js = m.group(1)

html = f'''<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Music App</title>

  <style>
    :root {{
      --bg: #09090b;
      --panel: #111114;
      --panel2: #18181c;
      --panel3: #222228;
      --text: #f5f5f5;
      --muted: #9999a5;
      --line: #292930;
      --accent: #8b5cf6;
      --accent2: #a78bfa;
      --danger: #fb7185;
    }}

    * {{
      box-sizing: border-box;
    }}

    html, body {{
      margin: 0;
      padding: 0;
      width: 100%;
      min-height: 100%;
      background: var(--bg);
      color: var(--text);
      font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}

    body {{
      overflow-x: hidden;
    }}

    button, input, select, textarea {{
      font: inherit;
    }}

    button {{
      cursor: pointer;
    }}

    .app {{
      min-height: 100vh;
    }}

    /* SIDEBAR */
    .sidebar {{
      position: fixed;
      left: 0;
      top: 0;
      bottom: 0;
      width: 245px;
      padding: 24px 16px;
      background: rgba(12,12,15,.96);
      border-right: 1px solid var(--line);
      z-index: 50;
    }}

    .brand {{
      display: flex;
      align-items: center;
      gap: 12px;
      padding: 0 10px 28px;
    }}

    .brand-icon {{
      width: 42px;
      height: 42px;
      border-radius: 14px;
      display: grid;
      place-items: center;
      background: linear-gradient(135deg, var(--accent), #6d28d9);
      font-size: 21px;
      box-shadow: 0 10px 30px rgba(139,92,246,.25);
    }}

    .brand-title {{
      font-size: 18px;
      font-weight: 800;
      letter-spacing: -.3px;
    }}

    .brand-sub {{
      color: var(--muted);
      font-size: 11px;
      margin-top: 2px;
    }}

    .nav-section {{
      margin: 12px 0 8px;
      padding: 0 10px;
      color: #666670;
      text-transform: uppercase;
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 1px;
    }}

    .nav {{
      display: flex;
      flex-direction: column;
      gap: 5px;
    }}

    .nav button {{
      width: 100%;
      border: 0;
      background: transparent;
      color: #aaaab5;
      padding: 12px 13px;
      border-radius: 12px;
      text-align: left;
      display: flex;
      align-items: center;
      gap: 12px;
      transition: .18s ease;
    }}

    .nav button:hover {{
      color: white;
      background: var(--panel2);
    }}

    .nav button.active {{
      color: white;
      background: linear-gradient(90deg, rgba(139,92,246,.22), rgba(139,92,246,.08));
      box-shadow: inset 3px 0 0 var(--accent);
    }}

    .nav-icon {{
      width: 22px;
      text-align: center;
      font-size: 17px;
    }}

    /* MAIN */
    .main {{
      margin-left: 245px;
      min-height: 100vh;
      padding-bottom: 105px;
    }}

    .topbar {{
      position: sticky;
      top: 0;
      z-index: 30;
      height: 76px;
      display: flex;
      align-items: center;
      gap: 18px;
      padding: 0 30px;
      background: rgba(9,9,11,.84);
      backdrop-filter: blur(18px);
      border-bottom: 1px solid rgba(41,41,48,.7);
    }}

    .search {{
      width: min(620px, 100%);
      position: relative;
    }}

    .search input {{
      width: 100%;
      border: 1px solid var(--line);
      background: var(--panel);
      color: white;
      border-radius: 14px;
      padding: 13px 16px 13px 44px;
      outline: none;
      transition: .2s;
    }}

    .search input:focus {{
      border-color: rgba(139,92,246,.65);
      box-shadow: 0 0 0 3px rgba(139,92,246,.10);
    }}

    .search-icon {{
      position: absolute;
      left: 16px;
      top: 50%;
      transform: translateY(-50%);
      color: var(--muted);
    }}

    .content {{
      padding: 30px;
      max-width: 1500px;
    }}

    .section {{
      display: none;
    }}

    .section.active {{
      display: block;
    }}

   /* HERO */
    .hero {{
      position: relative;
      overflow: hidden;
      border: 1px solid var(--line);
      border-radius: 24px;
      padding: 42px;
      min-height: 270px;
      background:
        radial-gradient(circle at 85% 25%, rgba(139,92,246,.30), transparent 32%),
        radial-gradient(circle at 70% 100%, rgba(109,40,217,.18), transparent 35%),
        linear-gradient(135deg, #17131f, #111114 60%);
    }}

    .hero::after {{
      content: "♫";
      position: absolute;
      right: 55px;
      bottom: -40px;
      font-size: 230px;
      line-height: 1;
      color: rgba(255,255,255,.035);
      pointer-events: none;
    }}

    .eyebrow {{
      color: var(--accent2);
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 2px;
      font-weight: 800;
      margin-bottom: 12px;
    }}

    .hero h1 {{
      margin: 0;
      font-size: clamp(34px, 5vw, 58px);
      line-height: 1;
      letter-spacing: -2px;
    }}

    .hero p {{
      color: var(--muted);
      max-width: 550px;
      line-height: 1.6;
      margin: 18px 0 0;
    }}

    /* HEADERS */
    .page-header {{
      display: flex;
      align-items: flex-end;
      justify-content: space-between;
      gap: 20px;
      margin-bottom: 22px;
    }}

    .page-header h2 {{
      margin: 0;
      font-size: 30px;
      letter-spacing: -.8px;
    }}

    .page-header p {{
      margin: 7px 0 0;
      color: var(--muted);
      font-size: 14px;
    }}

    .status {{
      color: var(--muted);
      font-size: 13px;
      margin: 12px 0;
    }}

    /* SONG LIST */
    .song-list {{
      display: flex;
      flex-direction: column;
      gap: 7px;
    }}

    .song-row {{
      display: grid;
      grid-template-columns: 44px minmax(0, 1fr) auto auto;
      align-items: center;
      gap: 15px;
      padding: 10px 14px;
      background: var(--panel);
      border: 1px solid transparent;
      border-radius: 13px;
      transition: .18s;
    }}

    .song-row:hover {{
      background: var(--panel2);
      border-color: var(--line);
      transform: translateY(-1px);
    }}

    .song-art {{
      width: 44px;
      height: 44px;
      border-radius: 11px;
      display: grid;
      place-items: center;
      background: linear-gradient(135deg, #292133, #17171c);
      color: var(--accent2);
      font-size: 18px;
    }}

    .song-info {{
      min-width: 0;
    }}

    .song-title {{
      font-weight: 700;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}

    .song-meta {{
      color: var(--muted);
      font-size: 12px;
      margin-top: 4px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}

    .song-actions {{
      display: flex;
      align-items: center;
      gap: 6px;
    }}

    .icon-btn {{
      width: 36px;
      height: 36px;
      border: 1px solid transparent;
      border-radius: 10px;
      background: transparent;
      color: #aaaab5;
    }}

    .icon-btn:hover {{
      background: var(--panel3);
      color: white;
    }}

    /* CARDS */
    .grid {{
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(190px, 1fr));
      gap: 16px;
    }}

    .card {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 17px;
      padding: 14px;
      transition: .2s;
      min-width: 0;
    }}

    .card:hover {{
      background: var(--panel2);
      transform: translateY(-3px);
      border-color: #3b3b45;
    }}

    .card-art {{
      width: 100%;
      aspect-ratio: 1;
      border-radius: 13px;
      display: grid;
      place-items: center;
      margin-bottom: 13px;
      background: linear-gradient(135deg, #2a2038, #16161a);
      color: var(--accent2);
      font-size: 38px;
    }}

    .card-title {{
      font-weight: 750;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}

    .card-sub {{
      color: var(--muted);
      font-size: 12px;
      margin-top: 5px;
    }}

    /* BUTTONS */
    .btn {{
      border: 1px solid var(--line);
      background: var(--panel2);
      color: white;
      padding: 10px 15px;
      border-radius: 11px;
      transition: .18s;
    }}

    .btn:hover {{
      background: var(--panel3);
    }}

    .btn-primary {{
      border-color: transparent;
      background: linear-gradient(135deg, var(--accent), #6d28d9);
      box-shadow: 0 8px 24px rgba(139,92,246,.20);
    }}

    .btn-primary:hover {{
      filter: brightness(1.08);
    }}

    /* PLAYLIST DETAIL */
    .back-btn {{
      margin-bottom: 18px;
    }}

    .playlist-detail-head {{
      background: linear-gradient(135deg, #17131f, #111114);
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 28px;
      margin-bottom: 22px;
    }}

    .playlist-detail-head h2 {{
      margin: 0;
      font-size: 32px;
    }}

    .playlist-detail-head p {{
      color: var(--muted);
      margin: 8px 0 0;
    }}

    .playlist-detail-count {{
      color: var(--accent2);
      font-size: 12px;
      margin-top: 15px;
    }}

    /* MODAL */
    .modal {{
      position: fixed;
      inset: 0;
      z-index: 100;
      display: none;
      align-items: center;
      justify-content: center;
      padding: 20px;
      background: rgba(0,0,0,.72);
      backdrop-filter: blur(7px);
    }}

    .modal.show {{
      display: flex;
    }}

    .modal-box {{
      width: min(500px, 100%);
      background: #131316;
      border: 1px solid var(--line);
      border-radius: 20px;
      padding: 24px;
      box-shadow: 0 25px 80px rgba(0,0,0,.5);
    }}

    .modal-box h3 {{
      margin: 0 0 20px;
      font-size: 22px;
    }}

    .field {{
      margin-bottom: 15px;
    }}

    .field label {{
      display: block;
      color: #b8b8c1;
      font-size: 12px;
      margin-bottom: 7px;
    }}

    .field input,
    .field textarea,
    .field select {{
      width: 100%;
      border: 1px solid var(--line);
      background: #0d0d10;
      color: white;
      border-radius: 11px;
      padding: 11px 12px;
      outline: none;
    }}

    .field textarea {{
      min-height: 90px;
      resize: vertical;
    }}

    .field input:focus,
    .field textarea:focus,
    .field select:focus {{
      border-color: var(--accent);
    }}

    .modal-actions {{
      display: flex;
      justify-content: flex-end;
      gap: 8px;
      margin-top: 20px;
    }}

    /* PLAYER */
    .player {{
      position: fixed;
      left: 245px;
      right: 0;
      bottom: 0;
      height: 88px;
      z-index: 40;
      display: grid;
      grid-template-columns: 280px minmax(250px, 1fr) 280px;
      align-items: center;
      gap: 20px;
      padding: 12px 25px;
      background: rgba(17,17,20,.95);
      backdrop-filter: blur(20px);
      border-top: 1px solid var(--line);
    }}

    .now-playing {{
      min-width: 0;
    }}

    .now-title {{
      font-weight: 750;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}

    .now-artist {{
      color: var(--muted);
      font-size: 12px;
      margin-top: 4px;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }}

    audio {{
      width: 100%;
      height: 40px;
    }}

    .player-spacer {{
      min-width: 0;
    }}

    /* EMPTY */
    .empty {{
      padding: 45px 20px;
      text-align: center;
      color: var(--muted);
      border: 1px dashed var(--line);
      border-radius: 16px;
      background: rgba(255,255,255,.015);
    }}

    /* MOBILE */
    @media (max-width: 900px) {{
      .sidebar {{
        width: 72px;
        padding: 16px 10px;
      }}

      .brand {{
        justify-content: center;
        padding: 0 0 22px;
      }}

      .brand-copy,
      .nav-section,
      .nav button span:not(.nav-icon) {{
        display: none;
      }}

      .nav button {{
        justify-content: center;
        padding: 12px;
      }}

      .main {{
        margin-left: 72px;
      }}

      .player {{
        left: 72px;
        grid-template-columns: 180px 1fr;
      }}

      .player-spacer {{
        display: none;
      }}
    }}

    @media (max-width: 650px) {{
      .topbar {{
        height: 68px;
        padding: 0 14px;
      }}

      .content {{
        padding: 18px 14px 115px;
      }}

      .hero {{
        padding: 28px 22px;
        min-height: 230px;
      }}

      .hero h1 {{
        font-size: 38px;
      }}

      .page-header {{
        align-items: flex-start;
        flex-direction: column;
      }}
 
      .grid {{
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 10px;
      }}

      .song-row {{
        grid-template-columns: 40px minmax(0, 1fr) auto;
        gap: 10px;
      }}

      .song-row > .song-meta-column {{
        display: none;
      }}

      .player {{
        height: 92px;
        left: 72px;
        padding: 10px 12px;
        grid-template-columns: 1fr;
        gap: 3px;
      }}

      .player audio {{
        height: 34px;
      }}
    }}
  </style>
</head>

<body>

<div class="app">

  <aside class="sidebar">
    <div class="brand">
      <div class="brand-icon">♫</div>
      <div class="brand-copy">
        <div class="brand-title">Music App</div>
        <div class="brand-sub">Your personal library</div>
      </div>
    </div>

    <div class="nav-section">Library</div>

    <nav class="nav">
      <button class="active" onclick="showSection('home', this)">
        <span class="nav-icon">⌂</span><span>Home</span>
      </button>

      <button onclick="showSection('songs', this)">
        <span class="nav-icon">♫</span><span>Songs</span>
      </button>

      <button onclick="showSection('albums', this)">
        <span class="nav-icon">▦</span><span>Albums</span>
      </button>

      <button onclick="showSection('artists', this)">
        <span class="nav-icon">♟</span><span>Artists</span>
      </button>

      <button onclick="showSection('favorites', this)">
        <span class="nav-icon">♥</span><span>Favorites</span>
      </button>

      <button onclick="showSection('playlists', this)">
        <span class="nav-icon">☷</span><span>Playlists</span>
      </button>
    </nav>
  </aside>

  <main class="main">

    <header class="topbar">
      <div class="search">
        <span class="search-icon">⌕</span>
        <input
          id="searchInput"
          type="search"
          placeholder="Search songs, artists, albums..."
        >
      </div>
    </header>

    <div class="content">

      <!-- HOME -->
      <section id="home" class="section active">

        <div class="hero">
          <div class="eyebrow">Your Music</div>
          <h1>Listen to what<br>you love.</h1>
          <p>
            Your personal music library, organized in one clean place.
            Browse songs, artists, albums and playlists.
          </p>
        </div>

        <div style="height:28px"></div>

        <div class="page-header">
          <div>
            <h2>Recently Added</h2>
            <p>Your latest music</p>
          </div>
        </div>

        <div id="homeStatus" class="status"></div>
        <div id="homeSongs" class="song-list"></div>

      </section>

      <!-- SONGS -->
      <section id="songs" class="section">

        <div class="page-header">
          <div>
            <h2>Songs</h2>
            <p>Everything in your music library</p>
          </div>
        </div>

        <div id="songsStatus" class="status"></div>
        <div id="songsList" class="song-list"></div>

      </section>

      <!-- ALBUMS -->
      <section id="albums" class="section">

        <div class="page-header">
          <div>
            <h2>Albums</h2>
            <p>Browse your collection by album</p>
          </div>
        </div>

        <div id="albumsGrid" class="grid"></div>

      </section>

      <!-- ARTISTS -->
      <section id="artists" class="section">

        <div class="page-header">
          <div>
            <h2>Artists</h2>
            <p>Explore music by artist</p>
          </div>
        </div>

        <div id="artistsGrid" class="grid"></div>

      </section>

      <!-- FAVORITES -->
      <section id="favorites" class="section">

        <div class="page-header">
          <div>
            <h2>Favorites</h2>
            <p>Your favorite songs</p>
          </div>
        </div>

        <div id="favoritesList" class="song-list"></div>

      </section>

      <!-- PLAYLISTS -->
      <section id="playlists" class="section">

        <div class="page-header">
          <div>
            <h2>Playlists</h2>
            <p>Create and organize your own collections</p>
          </div>

          <button class="btn btn-primary" onclick="openCreatePlaylistModal()">
            + New Playlist
          </button>
        </div>


        <div id="playlistsStatus" class="status"></div>
        <div id="playlistsGrid" class="grid"></div>

      </section>

      <!-- PLAYLIST DETAIL -->
      <section id="playlistDetail" class="section">

        <button class="btn back-btn" onclick="showSection('playlists')">
          ← Back to Playlists
        </button>

        <div class="playlist-detail-head">
          <h2 id="playlistDetailName">Playlist</h2>
          <p id="playlistDetailDescription"></p>
          <div id="playlistDetailCount" class="playlist-detail-count"></div>
        </div>

        <div style="display:flex;gap:10px;align-items:center;margin-bottom:16px;">
          <select id="addSongSelect" style="flex:1;"></select>
        </div>

        <div id="playlistSongsStatus" class="status"></div>
        <div id="playlistSongsList" class="song-list"></div>

      </section>

    </div>
  </main>

  <!-- PLAYER -->
  <div class="player">

    <div class="now-playing">
      <div id="nowTitle" class="now-title">Nothing playing</div>
      <div id="nowArtist" class="now-artist">Choose a song to start listening</div>
    </div>

    <audio id="audioPlayer" controls preload="metadata"></audio>

    <div class="player-spacer"></div>

  </div>

  <!-- PLAYLIST MODAL -->
  <div id="playlistModal" class="modal">

    <div class="modal-box">

      <h3>Create Playlist</h3>

      <div class="field">
        <label for="playlistNameInput">Name</label>
        <input id="playlistNameInput" type="text" placeholder="My Playlist">
      </div>

      <div class="field">
        <label for="playlistDescriptionInput">Description</label>
        <textarea id="playlistDescriptionInput" placeholder="Optional description"></textarea>
      </div>

      <div class="modal-actions">
        <button class="btn" onclick="closePlaylistModal()">Cancel</button>
        <button class="btn btn-primary" onclick="createPlaylist()">Create Playlist</button>
      </div>

    </div>

  </div>

</div>

<script>
{js}
</script>

</body>
</html>
'''

path.write_text(html)
print("Frontend redesigned successfully.")
print("Backup: /opt/musicapp/app/frontend/index.before-redesign.html")
print("New file:", path)
PY

head -8 /opt/musicapp/app/frontend/index.html
