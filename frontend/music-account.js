/* Shared account UI for the website and its Android WebView client. */
(() => {
  'use strict';
  if (document.getElementById('music-account-dialog')) return;
  const style = document.createElement('style');
  style.textContent = `
  #music-account-open{background:#382318;color:#fff;border:1px solid #b36b43;border-radius:24px;padding:9px 14px;cursor:pointer;font:inherit;white-space:nowrap}
  #music-account-dialog{color:#fafafa;background:#171310;border:1px solid #795039;border-radius:20px;width:min(440px,calc(100% - 28px));max-height:85vh;padding:24px;overflow:auto;font:16px/1.5 system-ui;box-sizing:border-box}
  #music-account-dialog::backdrop{background:#000a}
  #music-account-dialog h2{margin:0 0 14px}#music-account-dialog label{display:block;margin:12px 0 5px}
  #music-account-dialog input{display:block;box-sizing:border-box;width:100%;padding:11px;border:1px solid #777;border-radius:8px;background:#25201c;color:#fff;font:inherit}
  #music-account-dialog button{font:inherit;cursor:pointer;padding:10px 14px;border-radius:10px;border:1px solid #906141;background:#ac5c31;color:white}
  #music-account-dialog button:disabled{opacity:.6;cursor:wait}#music-account-dialog .account-actions{display:flex;gap:10px;flex-wrap:wrap;margin:18px 0}
  #music-account-dialog .account-close{float:right;background:transparent}#music-account-dialog .account-note{color:#c5b9b0;font-size:13px}
  #music-account-status{min-height:24px;color:#ffd0af}#music-account-dialog [hidden]{display:none!important}
  #music-account-dialog :focus-visible,#music-account-open:focus-visible{outline:3px solid #ffb27c;outline-offset:3px}
  `;
  document.head.append(style);
  const dialog = document.createElement('dialog');
  dialog.id = 'music-account-dialog';
  dialog.setAttribute('aria-labelledby', 'music-account-title');
  dialog.innerHTML = `
    <button type="button" class="account-close" aria-label="Close account">Close</button>
    <h2 id="music-account-title">Your account</h2>
    <p id="music-account-status" role="status" aria-live="polite"></p>
    <div id="music-account-guest">
      <div class="account-actions"><button type="button" id="account-login-tab">Log in</button><button type="button" id="account-register-tab">Create account</button></div>
      <form id="account-auth-form">
        <div id="account-register-name" hidden><label for="account-name">Display name</label><input id="account-name" name="name" maxlength="80" autocomplete="nickname"></div>
        <label for="account-email">Email</label><input id="account-email" type="email" name="email" maxlength="254" autocomplete="username" required>
        <label for="account-password">Password</label><input id="account-password" type="password" name="password" maxlength="128" autocomplete="current-password" required>
        <p id="account-password-hint" class="account-note" hidden>Use 12–128 characters.</p>
        <div class="account-actions"><button type="submit" id="account-submit">Log in</button></div>
      </form>
    </div>
    <div id="music-account-member" hidden>
      <p id="account-user-email"></p>
      <form id="account-name-form"><label for="account-edit-name">Display name</label><input id="account-edit-name" name="name" maxlength="80" autocomplete="nickname" required><div class="account-actions"><button type="submit">Save name</button></div></form>
      <button type="button" id="account-logout">Sign out</button>
    </div>
    <p class="account-note">Use the same account on iOS, the website, and Android. Playlists are currently shared; favorites remain on this device.</p>
  `;
  document.body.append(dialog);
  const $ = id => dialog.querySelector('#' + id);
  const trigger = document.createElement('button');
  trigger.id = 'music-account-open'; trigger.type = 'button'; trigger.textContent = 'Profile';
  trigger.setAttribute('aria-haspopup', 'dialog');
  const host = document.querySelector('.top-actions') || document.querySelector('header') || document.querySelector('.top') || document.body;
  const avatar = host.querySelector('.avatar');
  if (avatar) avatar.replaceWith(trigger); else host.append(trigger);
  let mode = 'login', user = null, busy = false;
  const status = message => { $('music-account-status').textContent = message; };
  function render() {
    $('music-account-guest').hidden = !!user;
    $('music-account-member').hidden = !user;
    trigger.textContent = user ? 'Profile · ' + user.name : 'Profile';
    if (user) { $('account-user-email').textContent = user.email; $('account-edit-name').value = user.name; }
  }
  function setMode(next) {
    mode = next;
    const register = next === 'register';
    $('account-register-name').hidden = !register;
    $('account-name').required = register;
    $('account-password').minLength = register ? 12 : 1;
    $('account-password').autocomplete = register ? 'new-password' : 'current-password';
    $('account-password-hint').hidden = !register;
    $('account-submit').textContent = register ? 'Create account' : 'Log in';
    $('account-login-tab').setAttribute('aria-pressed', String(!register));
    $('account-register-tab').setAttribute('aria-pressed', String(register));
    status('');
  }
  function setBusy(value) {
    busy = value;
    dialog.querySelectorAll('button:not(.account-close),input').forEach(element => { element.disabled = value; });
    dialog.setAttribute('aria-busy', String(value));
  }
  async function request(path, method = 'GET', body) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch('/api/auth/' + path, {
        method, credentials: 'same-origin', cache: 'no-store', signal: controller.signal,
        headers: { 'X-Music-Client': 'web', ...(body ? { 'Content-Type': 'application/json' } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {})
      });
      const data = response.status === 204 ? {} : await response.json().catch(() => ({}));
      if (!response.ok) {
        if (response.status === 401) { user = null; render(); }
        const error = new Error(data.error || 'Account request failed. Please try again.');
        error.status = response.status; throw error;
      }
      return data;
    } catch (error) {
      if (error.name === 'AbortError') throw new Error('The account server took too long. Please try again.');
      throw error;
    } finally { clearTimeout(timer); }
  }
  trigger.addEventListener('click', async () => {
    if (dialog.open) return;
    dialog.showModal(); setBusy(true); status('Checking your session…');
    try { const data = await request('me'); user = data.user; render(); status(''); }
    catch (error) { status(error.status === 401 ? '' : error.message); }
    finally { setBusy(false); (user ? $('account-edit-name') : $('account-email')).focus(); }
  });
  dialog.querySelector('.account-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { $('account-password').value = ''; });
  $('account-login-tab').addEventListener('click', () => setMode('login'));
  $('account-register-tab').addEventListener('click', () => setMode('register'));
  $('account-auth-form').addEventListener('submit', async event => {
    event.preventDefault(); if (busy) return;
    const body = { email: $('account-email').value.trim(), password: $('account-password').value };
    if (mode === 'register') body.name = $('account-name').value.trim();
    const route = mode; setBusy(true); status('Please wait…');
    try { const data = await request(route, 'POST', body); user = data.user; $('account-password').value = ''; render(); status('You are signed in.'); }
    catch (error) { status(error.message); }
    finally { setBusy(false); }
  });
  $('account-name-form').addEventListener('submit', async event => {
    event.preventDefault(); if (busy) return;
    const name = $('account-edit-name').value.trim(); setBusy(true); status('Saving…');
    try { const data = await request('me', 'PATCH', { name }); user = data.user; render(); status('Display name updated.'); }
    catch (error) { status(error.message); }
    finally { setBusy(false); }
  });
  $('account-logout').addEventListener('click', async () => {
    if (busy) return; setBusy(true); status('Signing out…');
    try { await request('logout', 'POST', {}); user = null; render(); setMode('login'); status('You are signed out.'); }
    catch (error) { status(error.status === 401 ? 'You are signed out.' : error.message); }
    finally { setBusy(false); }
  });
  setMode('login'); render();
})();
