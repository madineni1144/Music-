// MADINENI LYRICS V1
'use strict';
const crypto = require('node:crypto');

function clean(value) {
  return String(value || '').normalize('NFKC')
    .replace(/\[[^\]]*(?:www\.|https?:|songsmp3|naasongs|my3songs|sensongs)[^\]]*\]/gi, '')
    .replace(/\([^)]*(?:www\.|https?:|songsmp3|naasongs|my3songs|sensongs)[^)]*\)/gi, '')
    .replace(/https?:\/\/\S+|www\.\S+/gi, '')
    .replace(/\.(mp3|flac|m4a|ogg|wav)$/i, '')
    .replace(/-[a-f0-9]{10}$/, '')
    .replace(/^\s*\d{1,3}\s*[.\-_]\s*/, '')
    .replace(/\b(?:128|192|256|320)\s*kbps\b/gi, '')
    .replace(/\s+/g, ' ').trim();
}
function normalize(value) {
  return clean(value).toLocaleLowerCase('en-US')
    .replace(/[^\p{L}\p{N}]+/gu, ' ').replace(/\s+/g, ' ').trim();
}
function titleKey(value) {
  return normalize(clean(value).replace(/\s*[-–]?\s*[([]from\s+[\s\S]*?[)\]]\s*$/i, ''));
}
function albumKey(value) {
  return normalize(clean(value).replace(/\s*[([](?:original\s+)?(?:motion\s+picture\s+)?soundtrack[)\]]/gi, ''));
}
function known(value) {
  const s = normalize(value);
  return !!s && !/^(unknown(?: artist| album)?|various(?: artists)?|n a|na|none|null|not available)$/.test(s)
    && !/^(?:www )?(?:sensongsmp3|naasongs|my3songs|songsmp3)(?: (?:com|co|net))?$/.test(s);
}
function artists(value) {
  const pieces = String(value || '').split(/\s*(?:,|;|&|\bfeat\.?\b|\bfeaturing\b|\band\b|\bx\b)\s*/i);
  return [...new Set([normalize(value), ...pieces.map(normalize)].filter(Boolean))];
}
function metadata(song) {
  const duration = Number(song.duration_seconds);
  return {
    title: clean(song.title),
    artist: known(song.artist) ? clean(song.artist) : '',
    album: known(song.album) ? clean(song.album) : '',
    duration: Number.isFinite(duration) && duration > 0 ? duration : null,
  };
}
function fingerprint(song) {
  return crypto.createHash('sha256').update(JSON.stringify({
    ...metadata(song), file: song.file_path || '',
  })).digest('hex');
}
function matchScore(song, record) {
  const m = metadata(song);
  if (!record || !m.title || titleKey(m.title) !== titleKey(record.trackName || record.name)) return -1;
  if (record.instrumental !== true && !record.plainLyrics?.trim() && !parseLrc(record.syncedLyrics).length) return -1;
  const albumMatch = !!m.album && albumKey(m.album) === albumKey(record.albumName);
  const artistMatch = !!m.artist && artists(m.artist).some(a => artists(record.artistName).includes(a));
  // Never use a title alone: film songs and language versions can share it.
  if (m.album && !albumMatch) return -1;
  if (m.artist && !artistMatch) return -1;
  if (!albumMatch && !artistMatch) return -1;
  const rd = Number(record.duration);
  const diff = m.duration !== null && Number.isFinite(rd) && rd > 0 ? Math.abs(m.duration - rd) : null;
  if (m.duration !== null && (diff === null || diff > 2)) return -1;
  return 100 + (albumMatch ? 30 : 0) + (artistMatch ? 30 : 0) + (diff === null ? 0 : 10 - diff)
    + (record.syncedLyrics?.trim() ? 5 : 0);
}
function pickMatch(song, records) {
  const ranked = (Array.isArray(records) ? records : []).map(r => ({r, score:matchScore(song,r)}))
    .filter(x => x.score >= 0).sort((a,b) => b.score-a.score);
  if (!ranked.length) return null;
  // Equal-ranked different artists are ambiguous when the local artist is missing.
  const top = ranked.filter(x => x.score === ranked[0].score);
  if (!metadata(song).artist && new Set(top.map(x => normalize(x.r.artistName))).size > 1) return null;
  return ranked[0].r;
}
function parseLrc(value) {
  const text = String(value || '').replace(/\r/g, '');
  const offsets = [...text.matchAll(/\[offset\s*:\s*([+-]?\d+)\]/gi)];
  const offset = offsets.length ? Number(offsets.at(-1)[1]) / 1000 : 0;
  const lines = [];
  for (const raw of text.split('\n')) {
    const stamps = [...raw.matchAll(/\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g)];
    if (!stamps.length) continue;
    const lyric = raw.replace(/\[(?:\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?)\]/g, '').trim();
    for (const stamp of stamps) {
      if (Number(stamp[2]) >= 60) continue;
      const fraction = stamp[3] ? Number('0.' + stamp[3]) : 0;
      lines.push({time:Math.max(0, Number(stamp[1])*60+Number(stamp[2])+fraction+offset),text:lyric});
    }
  }
  return lines.sort((a,b) => a.time-b.time);
}
function recordPayload(songId, row) {
  const lines = parseLrc(row.synced_lrc);
  return {
    song_id:String(songId), status:row.status, source:row.source,
    source_url:row.source_url || null, plainLyrics:row.plain_text || null,
    syncedLyrics:lines.length ? row.synced_lrc : null, lines,
    instrumental:row.status === 'instrumental', fetched_at:row.fetched_at || null,
    retry_after:row.expires_at || null,
  };
}
module.exports = {clean, normalize, metadata, fingerprint, matchScore, pickMatch, parseLrc, recordPayload};
