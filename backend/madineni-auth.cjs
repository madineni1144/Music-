const crypto = require('node:crypto');
const { promisify } = require('node:util');
const scrypt = promisify(crypto.scrypt);

exports.mount = function (app, pool) {
  const cookieName = '__Secure-madineni_session';
  const cookieOptions = { httpOnly: true, secure: true, sameSite: 'strict', path: '/api/auth' };
  const publicOrigin = new URL(process.env.MUSICAPP_PUBLIC_ORIGIN || 'https://madinenimusic.madineni.xyz').origin;
  app.use('/api/auth', (req, res, next) => {
    res.set('Cache-Control', 'no-store');
    const origin = req.get('Origin');
    const browser = req.get('X-Music-Client') === 'web';
    if ((origin && origin !== publicOrigin) || (browser && !['GET', 'HEAD'].includes(req.method) && !origin)) {
      return res.status(403).json({ error: 'Open your account from the Madineni Music website.' });
    }
    if (req.body == null) req.body = {};
    next();
  });
  let initialization;
  function initialize() {
    if (!initialization) initialization = pool.query(`
      CREATE TABLE IF NOT EXISTS music_users (
        id BIGSERIAL PRIMARY KEY, email TEXT UNIQUE NOT NULL,
        name TEXT NOT NULL, password_hash TEXT NOT NULL,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );
      CREATE TABLE IF NOT EXISTS music_sessions (
        token_hash TEXT PRIMARY KEY,
        user_id BIGINT NOT NULL REFERENCES music_users(id) ON DELETE CASCADE,
        expires_at TIMESTAMPTZ NOT NULL
      );
    `).catch(error => { initialization = undefined; throw error; });
    return initialization;
  }
  const digest = token => crypto.createHash('sha256').update(token).digest('hex');
  const profile = row => ({ id: String(row.id), email: row.email, name: row.name });
  const attempts = new Map();
  // Bound password hashing work per client; trust proxy must reflect the deployment.
  function limit(req, res, next) {
    const now = Date.now();
    for (const [key, value] of attempts) if (value.until <= now) attempts.delete(key);
    const key = req.ip;
    const entry = attempts.get(key) || { count: 0, until: now + 15 * 60 * 1000 };
    if (entry.count >= 20 || (!attempts.has(key) && attempts.size >= 10000)) {
      return res.status(429).json({ error: 'Too many attempts. Try again in 15 minutes.' });
    }
    entry.count++; attempts.set(key, entry); next();
  }
  const route = handler => async (req, res) => {
    try { await initialize(); await handler(req, res); }
    catch (error) {
      if (error.code === '23505') return res.status(409).json({ error: 'An account with this email already exists.' });
      console.error('Account request failed:', error.message);
      res.status(503).json({ error: 'Account service unavailable. Please try again.' });
    }
  };
  async function session(user, res, req) {
    const token = crypto.randomBytes(32).toString('hex');
    await pool.query('DELETE FROM music_sessions WHERE expires_at <= NOW()');
    await pool.query("INSERT INTO music_sessions(token_hash,user_id,expires_at) VALUES($1,$2,NOW()+INTERVAL '30 days')", [digest(token), user.id]);
    if (req.get('X-Music-Client') === 'web') {
      res.cookie(cookieName, token, { ...cookieOptions, maxAge: 30 * 24 * 60 * 60 * 1000 });
      return res.json({ user: profile(user) });
    }
    res.json({ user: profile(user), token });
  }
  async function authenticate(req, res) {
    const authorization = req.get('Authorization');
    const cookie = (req.get('Cookie') || '').split(';').map(value => value.trim())
      .find(value => value.startsWith(cookieName + '='));
    const cookieToken = cookie ? cookie.slice(cookieName.length + 1) : '';
    const match = authorization ? /^Bearer ([a-f0-9]{64})$/.exec(authorization)
      : /^([a-f0-9]{64})$/.exec(cookieToken);
    if (!authorization && match && !['GET', 'HEAD'].includes(req.method) &&
        (req.get('Origin') !== publicOrigin || req.get('X-Music-Client') !== 'web')) {
      res.status(403).json({ error: 'Account request origin could not be verified.' }); return null;
    }
    if (!match) { res.status(401).json({ error: 'Please sign in again.' }); return null; }
    const result = await pool.query(`SELECT u.id,u.name,u.email FROM music_sessions s JOIN music_users u ON u.id=s.user_id WHERE s.token_hash=$1 AND s.expires_at>NOW()`, [digest(match[1])]);
    if (!result.rows[0]) { res.status(401).json({ error: 'Your session has expired. Please sign in again.' }); return null; }
    req.sessionHash = digest(match[1]); return result.rows[0];
  }
  app.post('/api/auth/register', limit, route(async (req, res) => {
    const email = typeof req.body.email === 'string' ? req.body.email.trim().toLowerCase() : '';
    const name = typeof req.body.name === 'string' ? req.body.name.trim() : '';
    const password = req.body.password;
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 || !name || name.length > 80 || typeof password !== 'string' || password.length < 8 || password.length > 12) {
      return res.status(400).json({ error: 'Enter a name, valid email, and a password between 8 and 12 characters.' });
    }
    const salt = crypto.randomBytes(16).toString('hex');
    const hash = (await scrypt(password, salt, 64)).toString('hex');
    const result = await pool.query('INSERT INTO music_users(email,name,password_hash) VALUES($1,$2,$3) RETURNING id,email,name', [email, name, `${salt}:${hash}`]);
    await session(result.rows[0], res, req);
  }));
  app.post('/api/auth/login', limit, route(async (req, res) => {
    const email = typeof req.body.email === 'string' ? req.body.email.trim().toLowerCase() : '';
    const password = req.body.password;
    if (typeof password !== 'string' || password.length > 128 || email.length > 254) return res.status(400).json({ error: 'Invalid email or password.' });
    const result = await pool.query('SELECT * FROM music_users WHERE email=$1', [email]);
    const user = result.rows[0];
    const [salt, stored] = (user?.password_hash || `${'0'.repeat(32)}:${'0'.repeat(128)}`).split(':');
    const hash = await scrypt(password, salt, 64);
    if (!user || !crypto.timingSafeEqual(hash, Buffer.from(stored, 'hex'))) return res.status(401).json({ error: 'Invalid email or password.' });
    await session(user, res, req);
  }));
  app.get('/api/auth/me', route(async (req, res) => {
    const user = await authenticate(req, res);
    if (user) res.set('Cache-Control', 'no-store').json({ user: profile(user) });
  }));
  app.patch('/api/auth/me', route(async (req, res) => {
    const user = await authenticate(req, res); if (!user) return;
    const name = typeof req.body.name === 'string' ? req.body.name.trim() : '';
    if (!name || name.length > 80) return res.status(400).json({ error: 'Name must contain 1–80 characters.' });
    const result = await pool.query('UPDATE music_users SET name=$1 WHERE id=$2 RETURNING id,email,name', [name,user.id]);
    res.json({ user: profile(result.rows[0]) });
  }));
  app.post('/api/auth/logout', route(async (req, res) => {
    const user = await authenticate(req, res);
    if (!user) {
      if (res.statusCode === 401) res.clearCookie(cookieName, cookieOptions);
      return;
    }
    await pool.query('DELETE FROM music_sessions WHERE token_hash=$1', [req.sessionHash]);
    res.clearCookie(cookieName, cookieOptions);
    res.status(204).end();
  }));
};


