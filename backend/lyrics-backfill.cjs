// MADINENI LYRICS V1
'use strict';
const path=require('node:path');
require('dotenv').config({path:path.join(__dirname,'../config/.env'),quiet:true});
const {Pool}=require('pg');
const {createService}=require('./madineni-lyrics.cjs');
const arg=process.argv.indexOf('--limit');
const limit=arg<0?100:Number(process.argv[arg+1]);
if(!Number.isInteger(limit)||limit<1||limit>20000){console.error('Use --limit 1 through 20000');process.exit(2);}
const pool=new Pool({host:process.env.DB_HOST,port:process.env.DB_PORT,database:process.env.DB_NAME,
  user:process.env.DB_USER,password:process.env.DB_PASSWORD,max:2,connectionTimeoutMillis:5000});
(async()=>{
  try {
    const service=createService(pool,{musicDir:process.env.MUSIC_DIR||'/opt/musicapp/music/Songs'});
    await service.ready;
    const result=await pool.query(`SELECT s.id,s.title FROM songs s LEFT JOIN madineni_song_lyrics l ON l.song_id=s.id
      WHERE l.song_id IS NULL OR l.expires_at<=NOW() ORDER BY s.id LIMIT $1`,[limit]);
    const counts={};let consecutiveErrors=0;
    for(const song of result.rows){
      const lyrics=await service.get(song.id);
      counts[lyrics.status]=(counts[lyrics.status]||0)+1;
      console.log(`${song.id}: ${song.title} -> ${lyrics.status}`);
      consecutiveErrors=lyrics.status==='error'?consecutiveErrors+1:0;
      if(consecutiveErrors>=3){console.log('Provider unavailable; stopping this batch. Try again later.');break;}
    }
    console.log(JSON.stringify({processed:Object.values(counts).reduce((a,b)=>a+b,0),counts}));
  }catch{console.error('Lyrics backfill stopped. Check the music app database and retry later.');process.exitCode=1;}
  finally{await pool.end();}
})();
