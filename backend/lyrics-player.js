// MADINENI LYRICS V1
(() => {
  'use strict';
  if (window.madineniLyricsConnected) return;
  window.madineniLyricsConnected = true;
  function start() {
    const media = typeof audio !== 'undefined' ? audio : document.querySelector('audio');
    if (!media || typeof media.addEventListener !== 'function') return;
    const base = (typeof API_BASE === 'string' ? API_BASE : typeof API === 'string' ? API : window.MUSIC_API_BASE || '').replace(/\/$/, '');
    const getSong = () => {
      if (typeof data !== 'undefined' && Array.isArray(data) && typeof current !== 'undefined') return data[current] || null;
      if (typeof state !== 'undefined' && Array.isArray(state.songs)) return state.songs[state.index] || null;
      return null;
    };
    const style = document.createElement('style');
    style.textContent = `
      .mm-lyrics-view{position:relative;color:inherit}
      .mm-lyrics-meta{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:0 0 12px;color:#b7b1aa;font-size:13px}
      .mm-lyrics-meta a{color:#edaf79;text-decoration:underline}
      .mm-lyrics-body{position:relative;max-height:380px;overflow:auto;overscroll-behavior:contain;padding:12px 8px;scrollbar-width:thin}
      .mm-lyrics-line{display:block;width:100%;border:0;background:transparent;text-align:left;padding:9px 4px;margin:0;font:inherit;font-size:20px;line-height:1.65;color:#a6a09b;white-space:pre-wrap;overflow-wrap:anywhere}
      button.mm-lyrics-line{cursor:pointer}.mm-lyrics-line.mm-active{color:#fff;font-weight:700}
      .mm-lyrics-plain{white-space:pre-wrap;line-height:1.9;font-size:18px;overflow-wrap:anywhere;color:inherit}
      .mm-lyrics-retry,.mm-lyrics-open,.mm-lyrics-close{border:1px solid #ffffff35;background:#ffffff10;color:inherit;border-radius:18px;padding:9px 15px;font:inherit;cursor:pointer}
      .mm-lyrics-retry:disabled{opacity:.6;cursor:default}
      .mm-lyrics-dialog{position:fixed;inset:auto;top:50%;left:50%;transform:translate(-50%,-50%);margin:0;width:min(92vw,660px);max-height:85vh;overflow:auto;padding:24px;background:#201b18;color:#faf5ef;border:1px solid #5a4535;border-radius:20px;z-index:2000}
      .mm-lyrics-dialog::backdrop{background:#0009}.mm-lyrics-dialog h2{margin:0 0 15px}.mm-lyrics-dialog .mm-lyrics-close{float:right}
      .mm-lyrics-open{margin:8px}
      @media(max-width:600px){.mm-lyrics-line{font-size:19px}.mm-lyrics-body{max-height:45vh}}
    `;
    document.head.append(style);
    let host = null, dialog = null, button = document.getElementById('lyricsTab');
    let active = false, activeId = null, request = null, generation = 0, lines = [], nodes = [], previousTime = null, manualUntil = 0, retryTimer = null;
    const el = (tag, text, className) => {
      const node = document.createElement(tag);
      if (text !== undefined) node.textContent = text;
      if (className) node.className = className;
      return node;
    };
    const visible = () => active && !!host && !!host.querySelector('.mm-lyrics-view') && (!dialog || dialog.open);
    function stop() {
      active = false; generation++; request?.abort(); clearTimeout(retryTimer);
      request = null; nodes = []; lines = []; previousTime = null;
      button?.setAttribute('aria-pressed', 'false');
    }
    function shell(song) {
      const view = el('section', undefined, 'mm-lyrics-view');
      view.setAttribute('aria-label', 'Song lyrics');
      const header = el('div', song?.title || 'Lyrics', 'mm-lyrics-meta');
      const body = el('div', undefined, 'mm-lyrics-body');
      body.setAttribute('tabindex', '0');
      body.setAttribute('aria-label', 'Lyrics. Select a timed line to seek.');
      body.addEventListener('wheel', () => {manualUntil = Date.now() + 8000;}, {passive:true});
      body.addEventListener('touchstart', () => {manualUntil = Date.now() + 8000;}, {passive:true});
      view.append(header, body); host.replaceChildren(view);
      return {view, header, body};
    }
    function showFailure(body, message, until = 0) {
      body.replaceChildren(el('p', message));
      const retry = el('button', 'Try again', 'mm-lyrics-retry');
      retry.type = 'button';
      retry.onclick = () => load();
      const delay = until - Date.now();
      if (delay > 0) {
        retry.disabled = true;
        const date = new Date(until);
        body.append(el('p', `You can retry after ${date.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',second:'2-digit'})}.`));
        retryTimer = setTimeout(() => {if (retry.isConnected) retry.disabled = false;}, Math.min(delay,2147483647));
      }
      body.append(retry);
    }
    async function load() {
      const song = getSong();
      request?.abort(); clearTimeout(retryTimer);
      const token = ++generation;
      activeId = song?.id === undefined ? null : String(song.id);
      lines = []; nodes = []; previousTime = null; manualUntil = 0;
      const {header, body} = shell(song);
      if (!song || activeId === null) {body.append(el('p','Select a song to see its lyrics.'));return;}
      body.append(el('p','Finding lyrics…'));
      const controller = new AbortController();
      request = controller;
      const timeout = setTimeout(() => controller.abort(), 45000);
      try {
        const response = await fetch(`${base}/api/songs/${encodeURIComponent(activeId)}/lyrics`, {signal:controller.signal,cache:'no-store'});
        if (!response.ok) {
          const seconds = Number(response.headers.get('Retry-After')) || 5;
          const error = new Error('Lyrics are temporarily unavailable.');
          error.until = Date.now() + seconds*1000;
          throw error;
        }
        const result = await response.json();
        if (token !== generation || !visible()) return;
        const lyric = result.data;
        if (!result.success || !lyric || String(lyric.song_id) !== activeId) throw new Error('Could not load lyrics for this song.');
        body.replaceChildren();
        if (lyric.status === 'instrumental') {body.append(el('p','This track is instrumental.'));return;}
        if (lyric.status === 'not_found') {body.append(el('p','Lyrics not found for this song.'));return;}
        if (lyric.status === 'error') {showFailure(body,'The lyrics service is temporarily unavailable.',Date.parse(lyric.retry_after)||0);return;}
        lines = Array.isArray(lyric.lines) ? lyric.lines.filter(x => Number.isFinite(x.time) && x.time>=0 && typeof x.text === 'string') : [];
        const mode = el('span', lines.length ? ' • Timed lyrics' : ' • Plain lyrics');
        header.append(mode);
        if (lyric.source) {
          const label = lyric.source==='lrclib'?'LRCLIB':lyric.source==='embedded'?'Embedded lyrics':'Local lyrics';
          let link;
          try { const url = new URL(lyric.source_url); if(url.protocol==='https:' && url.hostname==='lrclib.net') link='https://lrclib.net'; } catch {}
          if (link) {
            const source=el('a',label);source.href=link;source.target='_blank';source.rel='noopener noreferrer';header.append(source);
          } else header.append(el('span',label));
        }
        if (lines.length) {
          for (const line of lines) {
            const node=el('button',line.text||'♪','mm-lyrics-line');node.type='button';
            node.title='Seek to this line';
            node.onclick=()=>{media.currentTime=Number.isFinite(media.duration)?Math.min(line.time,media.duration):line.time;manualUntil=0;highlight();};
            nodes.push(node);body.append(node);
          }
          highlight();
        } else body.append(el('div',lyric.plainLyrics||'Lyrics not found for this song.','mm-lyrics-plain'));
      } catch(error) {
        if (token === generation && visible()) showFailure(body,error.name==='AbortError'?'The lyrics request timed out. Try again.':error.message,error.until||0);
      } finally {clearTimeout(timeout);}
    }
    function highlight() {
      if (!visible() || !nodes.length) return;
      const time = Number(media.currentTime) || 0;
      let low=0,high=lines.length-1,index=-1;
      while(low<=high){const mid=(low+high)>>1;if(lines[mid].time<=time){index=mid;low=mid+1;}else high=mid-1;}
      const stamp=index>=0?lines[index].time:null;
      if(stamp===previousTime)return;
      previousTime=stamp;
      for(let i=0;i<nodes.length;i++){
        const selected=stamp!==null && lines[i].time===stamp;
        nodes[i].classList.toggle('mm-active',selected);
        if(selected)nodes[i].setAttribute('aria-current','true');else nodes[i].removeAttribute('aria-current');
      }
      if(index>=0 && Date.now()>manualUntil){
        const box=host.querySelector('.mm-lyrics-body');
        const target=nodes[index].offsetTop-box.clientHeight/2+nodes[index].clientHeight/2;
        box.scrollTo({top:Math.max(0,target),behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'});
      }
    }
    function open() {
      if(dialog && !dialog.open)dialog.showModal();
      if(!dialog && typeof openFull==='function')openFull();
      active=true;button?.setAttribute('aria-pressed','true');load();
    }
    const panel=document.getElementById('detailPanel');
    if(button && panel){
      host=panel;button.onclick=open;
      document.addEventListener('click',event=>{
        const id=event.target.closest('button')?.id;
        if(['queueTab','miniQueue','collapse'].includes(id))stop();
      });
    }else{
      dialog=el('dialog',undefined,'mm-lyrics-dialog');
      const close=el('button','Close','mm-lyrics-close');close.type='button';close.onclick=()=>dialog.close();
      host=el('div');dialog.append(close,el('h2','Lyrics'),host);document.body.append(dialog);
      dialog.addEventListener('close',stop);dialog.addEventListener('cancel',stop);
      if(!button){button=el('button','Lyrics','mm-lyrics-open');button.type='button';
        const parent=document.querySelector('#player .top-actions, #player .section-head, #player .now-actions')||document.getElementById('player')||document.querySelector('.player')||document.body;
        parent.append(button);
      }
      button.onclick=open;
    }
    button.setAttribute('aria-pressed','false');
    const update=()=>{
      if(!visible())return;
      const song=getSong(),id=song?.id===undefined?null:String(song.id);
      if(id!==activeId)load();else highlight();
    };
    for(const event of ['timeupdate','seeking','seeked','loadedmetadata','loadstart','play'])media.addEventListener(event,update);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start,{once:true});else start();
})();
