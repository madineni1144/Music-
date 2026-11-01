// MADINENI LYRICS V1
'use strict';
const fs = require('node:fs/promises');
const path = require('node:path');
const {promisify} = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const core = require('./lyrics-core.cjs');
const VERSION = '1.0.0';
const MAX_LYRICS_BYTES = 262144;
const SCHEMA = `
CREATE TABLE IF NOT EXISTS madineni_song_lyrics (
  song_id BIGINT PRIMARY KEY REFERENCES songs(id) ON DELETE CASCADE,
  fingerprint TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('found','instrumental','not_found','error')),
  plain_text TEXT, synced_lrc TEXT, source TEXT, source_url TEXT,
  provider_id TEXT, provider_metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  fetched_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), expires_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS madineni_song_lyrics_retry_idx ON madineni_song_lyrics(expires_at);
`;
const SONG_SQL = `SELECT s.id,s.title,s.file_path,s.duration_seconds,
  a.name AS artist,al.title AS album FROM songs s
  LEFT JOIN artists a ON a.id=s.artist_id LEFT JOIN albums al ON al.id=s.album_id
  WHERE s.id=$1`;
class ProviderUnavailable extends Error {
  constructor(seconds=300) { super('Lyrics provider temporarily unavailable'); this.retrySeconds=seconds; }
}
class QueueBusy extends Error {}
class SongNotFound extends Error {}
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
function retryAfter(value) {
  const n = Number(value);
  if (value && Number.isFinite(n) && n>=0) return Math.max(1,Math.ceil(n));
  const date=Date.parse(value || '');
  return Number.isFinite(date) ? Math.max(1,Math.ceil((date-Date.now())/1000)) : 60;
}
function limiter(fetchImpl=fetch, wait=sleep) {
  let tail=Promise.resolve(), count=0, nextAt=0, cooldown=0;
  async function request(endpoint, parameters) {
    if (Date.now()<cooldown) throw new ProviderUnavailable(Math.ceil((cooldown-Date.now())/1000));
    if (count>=12) throw new QueueBusy('Lyrics request queue is busy');
    count++;
    const pending=tail.then(async () => {
      if (Date.now()<cooldown) throw new ProviderUnavailable(Math.ceil((cooldown-Date.now())/1000));
      const pause=nextAt-Date.now();
      if (pause>0) await wait(pause);
      let response;
      try {
        const url=new URL(endpoint,'https://lrclib.net');
        url.search=new URLSearchParams(parameters).toString();
        response=await fetchImpl(url,{
          headers:{'User-Agent':`MadineniMusicLyrics/${VERSION} (https://madinenimusic.madineni.xyz/)`,Accept:'application/json'},
          signal:AbortSignal.timeout(8000),redirect:'error',
        });
        // Keep the entire response in the queue, including body consumption.
        if (response.status===429 || response.status===503) {
          const seconds=retryAfter(response.headers.get('retry-after'));
          cooldown=Date.now()+seconds*1000;
          await response.body?.cancel();
          throw new ProviderUnavailable(seconds);
        }
        if (response.status===404) {await response.body?.cancel();return null;}
        if (!response.ok || !response.headers.get('content-type')?.includes('json')) {
          await response.body?.cancel();throw new ProviderUnavailable();
        }
        const reader=response.body.getReader();
        const chunks=[];let bytes=0;
        while(true) {
          const {done,value}=await reader.read();if(done)break;
          bytes+=value.byteLength;
          if(bytes>5*1024*1024){await reader.cancel();throw new ProviderUnavailable();}
          chunks.push(Buffer.from(value));
        }
        return JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch(error) {
        if(error instanceof ProviderUnavailable)throw error;
        throw new ProviderUnavailable();
      } finally {nextAt=Date.now()+350;}
    });
    tail=pending.catch(()=>{});
    try{return await pending;}finally{count--;}
  }
  return {request};
}
// All requests, including concurrent song lookups, share one provider queue.
const provider = limiter();
async function ensureSchema(pool) {await pool.query(SCHEMA);}
function below(root,target) {const rel=path.relative(root,target);return rel && !rel.startsWith('..'+path.sep) && rel!=='..' && !path.isAbsolute(rel);}
async function localIdentity(song,musicDir) {
  if(!song.file_path || !musicDir)return '';
  try {
    const root=await fs.realpath(musicDir);
    let filename=String(song.file_path);
    if(filename.startsWith('/music/'))filename=filename.slice(7);
    const audioFile=await fs.realpath(path.isAbsolute(filename)?filename:path.resolve(root,filename));
    if(!below(root,audioFile))return '';
    const stem=audioFile.slice(0,audioFile.length-path.extname(audioFile).length);
    const versions=[];
    for(const candidate of [audioFile,stem+'.lrc',stem+'.lyrics.txt']) {
      try {
        const real=await fs.realpath(candidate);if(!below(root,real)){versions.push(null);continue;}
        const stat=await fs.stat(real);versions.push([real,stat.mtimeMs,stat.size]);
      }catch{versions.push(null);}
    }
    return JSON.stringify(versions);
  }catch{return '';}
}
async function localLyrics(song,musicDir) {
  if(!song.file_path || !musicDir)return null;
  let root;
  try{root=await fs.realpath(musicDir);}catch{return null;}
  let filename=String(song.file_path);
  if(filename.startsWith('/music/'))filename=filename.slice(7);
  let audioFile=path.isAbsolute(filename)?filename:path.resolve(root,filename);
  try{audioFile=await fs.realpath(audioFile);}catch{return null;}
  if(!below(root,audioFile))return null;
  const stem=audioFile.slice(0,audioFile.length-path.extname(audioFile).length);
  for(const [candidate,synced] of [[stem+'.lrc',true],[stem+'.lyrics.txt',false]]) {
    try {
      const real=await fs.realpath(candidate);
      if(!below(root,real))continue;
      const stats=await fs.stat(real);
      if(!stats.isFile() || stats.size>MAX_LYRICS_BYTES)continue;
      const content=(await fs.readFile(real,'utf8')).replace(/^\uFEFF/,'').trim();
      if(!content)continue;
      const lines=synced?core.parseLrc(content):[];
      if(synced && !lines.length)continue;
      return {plainLyrics:synced?lines.map(x=>x.text).join('\n'):content,syncedLyrics:synced?content:null,source:'local'};
    }catch{/* Missing sidecar: try embedded tags, then the provider. */}
  }
  try {
    const {stdout}=await execFile('python3',[path.join(__dirname,'read-embedded-lyrics.py'),audioFile],{timeout:4000,maxBuffer:MAX_LYRICS_BYTES*3});
    const embedded=JSON.parse(stdout);
    if(embedded.plainLyrics?.trim() || core.parseLrc(embedded.syncedLyrics).length) return {...embedded,source:'embedded'};
  }catch{/* Mutagen is optional; provider lookup still works. */}
  return null;
}
async function findLyrics(song,queue=provider) {
  const m=core.metadata(song);
  if(!m.title || (!m.artist && !m.album))return null;
  const base={track_name:m.title};
  if(m.artist)base.artist_name=m.artist;
  if(m.album)base.album_name=m.album;
  if(m.duration!==null && m.duration<=3600)base.duration=String(m.duration);
  if(m.artist){
    const direct=await queue.request('/api/get',base);
    const match=core.pickMatch(song,direct?[direct]:[]);
    if(match)return match;
  }
  const params={track_name:m.title};
  if(m.album)params.album_name=m.album;
  else if(m.artist)params.artist_name=m.artist;
  const first=await queue.request('/api/search',params);
  let match=core.pickMatch(song,first);
  if(match)return match;
  if(m.album || m.artist){
    match=core.pickMatch(song,await queue.request('/api/search',{track_name:m.title}));
  }
  return match;
}
function createService(pool,options={}) {
  const ready=options.skipSchema?Promise.resolve():ensureSchema(pool);
  // Observe failures immediately; every endpoint also awaits ready.
  ready.catch(()=>{});
  const running=new Map();
  async function retrieve(song) {
    // Added or edited sidecars invalidate even cached misses immediately.
    const localVersion=await (options.localIdentity||localIdentity)(song,options.musicDir);
    const fp=core.fingerprint({...song,file_path:String(song.file_path||'')+'|'+localVersion});
    const cached=await pool.query('SELECT * FROM madineni_song_lyrics WHERE song_id=$1',[song.id]);
    const row=cached.rows[0];
    if(row && row.fingerprint===fp && (!row.expires_at || new Date(row.expires_at).getTime()>Date.now()))return row;
    let record=null,status='not_found',expires=new Date(Date.now()+7*86400000),source='lrclib';
    try {
      record=await (options.localLyrics||localLyrics)(song,options.musicDir);
      if(!record)record=await findLyrics(song,options.provider||provider);
      if(record) {status=record.instrumental===true?'instrumental':'found';expires=null;source=record.source||'lrclib';}
    } catch(error) {
      if(error instanceof QueueBusy)throw error;
      status='error';expires=new Date(Date.now()+Math.max(10,error.retrySeconds||300)*1000);
    }
    const plain=record?.plainLyrics?.trim()||null;
    const synced=record?.syncedLyrics?.trim()||null;
    if((plain && Buffer.byteLength(plain)>MAX_LYRICS_BYTES)||(synced && Buffer.byteLength(synced)>MAX_LYRICS_BYTES)){
      throw new ProviderUnavailable();
    }
    const id=record?.id ? String(record.id):null;
    const url=source==='lrclib' && id && /^\d+$/.test(id)?`https://lrclib.net/api/get/${id}`:null;
    const details=record?{title:record.trackName||song.title,artist:record.artistName||song.artist,album:record.albumName||song.album,duration:record.duration||song.duration_seconds}:{};
    const saved=await pool.query(`INSERT INTO madineni_song_lyrics
      (song_id,fingerprint,status,plain_text,synced_lrc,source,source_url,provider_id,provider_metadata,expires_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10)
      ON CONFLICT(song_id) DO UPDATE SET fingerprint=EXCLUDED.fingerprint,status=EXCLUDED.status,
      plain_text=EXCLUDED.plain_text,synced_lrc=EXCLUDED.synced_lrc,source=EXCLUDED.source,
      source_url=EXCLUDED.source_url,provider_id=EXCLUDED.provider_id,provider_metadata=EXCLUDED.provider_metadata,
      fetched_at=NOW(),updated_at=NOW(),expires_at=EXCLUDED.expires_at RETURNING *`,
      [song.id,fp,status,plain,synced,source,url,id,JSON.stringify(details),expires]);
    return saved.rows[0];
  }
  async function get(id) {
    await ready;
    const found=await pool.query(SONG_SQL,[id]);
    const song=found.rows[0];
    if(!song)throw new SongNotFound();
    if(running.has(String(id)))return running.get(String(id));
    if(running.size>=4)throw new QueueBusy();
    const task=retrieve(song).then(row=>core.recordPayload(id,row));
    running.set(String(id),task);
    try{return await task;}finally{running.delete(String(id));}
  }
  return {get,ready};
}
function mount(app,pool,options={}) {
  const service=createService(pool,options);
  app.get('/api/lyrics/player.js',(req,res)=>{
    res.set('Cache-Control','no-store').type('application/javascript').sendFile(path.join(__dirname,'lyrics-player.js'));
  });
  app.get('/api/lyrics/status',async(req,res)=>{
    try {
      await service.ready;
      const results=await pool.query('SELECT status,COUNT(*)::int AS count FROM madineni_song_lyrics GROUP BY status');
      res.set('Cache-Control','no-store').json({success:true,version:VERSION,provider:'LRCLIB',storage:'PostgreSQL',counts:Object.fromEntries(results.rows.map(x=>[x.status,x.count]))});
    }catch {res.status(503).json({success:false,error:'Lyrics database unavailable'});}
  });
  app.get('/api/songs/:id/lyrics',async(req,res)=>{
    const id=String(req.params.id);
    if(!/^[1-9]\d{0,18}$/.test(id) || BigInt(id)>9223372036854775807n)return res.status(400).json({success:false,error:'Invalid song ID'});
    try {res.set('Cache-Control','no-store').json({success:true,data:await service.get(id)});}
    catch(error) {
      if(error instanceof SongNotFound)return res.status(404).json({success:false,error:'Song not found'});
      res.set('Retry-After',String(error.retrySeconds||5)).status(503).json({success:false,error:'Lyrics temporarily unavailable. Please try again later.'});
    }
  });
  return service;
}
module.exports={mount,createService,ensureSchema,findLyrics,localLyrics,localIdentity,limiter,retryAfter,SongNotFound,QueueBusy,ProviderUnavailable,VERSION};
