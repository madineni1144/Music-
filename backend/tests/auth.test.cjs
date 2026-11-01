const test = require('node:test');
const assert = require('node:assert/strict');
const { mount } = require('../madineni-auth.cjs');
const ORIGIN = 'https://madinenimusic.madineni.xyz';
const WEB = { Origin: ORIGIN, 'X-Music-Client': 'web' };
function fixture() {
  const routes = new Map(), middleware = [], users = [], sessions = new Map();
  const pool = { async query(sql, p = []) {
    if (sql.includes('CREATE TABLE')) return {rows: []};
    if (sql.startsWith('INSERT INTO music_users')) {
      if (users.some(u => u.email === p[0])) throw Object.assign(new Error('duplicate'), {code:'23505'});
      const user = {id:users.length+1,email:p[0],name:p[1],password_hash:p[2]}; users.push(user); return {rows:[user]};
    }
    if (sql.startsWith('DELETE FROM music_sessions WHERE expires_at')) return {rows:[]};
    if (sql.startsWith('INSERT INTO music_sessions')) { sessions.set(p[0],p[1]); return {rows:[]}; }
    if (sql.startsWith('SELECT * FROM music_users')) return {rows:users.filter(u=>u.email===p[0])};
    if (sql.startsWith('SELECT u.id')) return {rows:users.filter(u=>u.id===sessions.get(p[0]))};
    if (sql.startsWith('UPDATE music_users')) { const u=users.find(u=>u.id===p[1]);u.name=p[0];return {rows:[u]}; }
    if (sql.startsWith('DELETE FROM music_sessions WHERE token_hash')) { sessions.delete(p[0]);return {rows:[]}; }
    throw new Error('Unexpected query');
  }};
  const app = {use(path,fn){middleware.push(fn);}};
  for (const method of ['post','get','patch']) app[method]=(path,...handlers)=>routes.set(method.toUpperCase()+' '+path,handlers);
  mount(app,pool);
  return {users,sessions,async request(method,path,{headers={},body,ip='test'}={}) {
    const req={method,body,ip,get(name){return Object.entries(headers).find(([key])=>key.toLowerCase()===name.toLowerCase())?.[1];}};
    const res={statusCode:200,headers:{},status(code){this.statusCode=code;return this;},set(k,v){this.headers[k]=v;return this;},json(data){this.data=data;this.ended=true;return this;},end(){this.ended=true;return this;},cookie(name,value,options){this.cookieValue={name,value,options};return this;},clearCookie(name,options){this.cleared={name,options};return this;}};
    for (const handler of [...middleware,...routes.get(method+' '+path)]) {let next=false;await handler(req,res,()=>{next=true;});if(res.ended||!next)break;}
    return res;
  }};
}
const body={email:'Person@example.com',name:'Person',password:'DemoPass123'};
test('browser registration, cookie session, profile update, logout and revocation',async()=>{
 const f=fixture();let r=await f.request('POST','/api/auth/register',{headers:WEB,body});
 assert.equal(r.statusCode,200);assert.equal(r.data.token,undefined);assert.equal(r.data.user.email,'person@example.com');
 assert.notEqual(f.users[0].password_hash,body.password);assert.equal(r.cookieValue.options.httpOnly,true);assert.equal(r.cookieValue.options.secure,true);assert.equal(r.cookieValue.options.sameSite,'strict');assert.equal(r.cookieValue.options.maxAge,2592000000);
 const headers={...WEB,Cookie:r.cookieValue.name+'='+r.cookieValue.value};
 r=await f.request('GET','/api/auth/me',{headers});assert.equal(r.data.user.name,'Person');
 r=await f.request('PATCH','/api/auth/me',{headers,body:{name:'Edited'}});assert.equal(r.data.user.name,'Edited');
 r=await f.request('POST','/api/auth/logout',{headers});assert.equal(r.statusCode,204);assert.ok(r.cleared);
 r=await f.request('GET','/api/auth/me',{headers});assert.equal(r.statusCode,401);
});
test('iOS bearer contract and login remain compatible',async()=>{
 const f=fixture();let r=await f.request('POST','/api/auth/register',{body});const token=r.data.token;assert.match(token,/^[a-f0-9]{64}$/);assert.equal(r.cookieValue,undefined);
 r=await f.request('GET','/api/auth/me',{headers:{Authorization:'Bearer '+token}});assert.equal(r.data.user.name,'Person');
 r=await f.request('POST','/api/auth/login',{body:{email:body.email,password:body.password}});assert.match(r.data.token,/^[a-f0-9]{64}$/);
 r=await f.request('POST','/api/auth/login',{body:{email:body.email,password:'wrong'}});assert.equal(r.statusCode,401);
});
test('cross-origin requests and missing-origin browser writes are rejected',async()=>{
 const f=fixture();
 for(const headers of [{...WEB,Origin:'https://evil.example'},{'X-Music-Client':'web'}]){
  const r=await f.request('POST','/api/auth/register',{headers,body});assert.equal(r.statusCode,403);
 }
 assert.equal(f.users.length,0);
 const r=await f.request('POST','/api/auth/register',{headers:WEB,body});
 const cookie=r.cookieValue.name+'='+r.cookieValue.value;
 const denied=await f.request('PATCH','/api/auth/me',{headers:{Cookie:cookie},body:{name:'bad'}});assert.equal(denied.statusCode,403);
});
test('expired sessions return 401; logout clears stale cookies; no-store on errors',async()=>{
 const f=fixture();const headers={...WEB,Cookie:'__Secure-madineni_session='+'f'.repeat(64)};
 const r=await f.request('GET','/api/auth/me',{headers});assert.equal(r.statusCode,401);assert.equal(r.headers['Cache-Control'],'no-store');
 const out=await f.request('POST','/api/auth/logout',{headers});assert.equal(out.statusCode,401);assert.ok(out.cleared);
});
test('validation, duplicate email and rate limiting',async()=>{
 const f=fixture();let r=await f.request('POST','/api/auth/register',{headers:WEB,body:{...body,password:'short'}});assert.equal(r.statusCode,400);
 await f.request('POST','/api/auth/register',{headers:WEB,body});r=await f.request('POST','/api/auth/register',{headers:WEB,body});assert.equal(r.statusCode,409);
 for(let i=0;i<21;i++) r=await f.request('POST','/api/auth/login',{headers:WEB,body:{email:body.email,password:'wrong'},ip:'other'});
 assert.equal(r.statusCode,429);
});


test('new passwords accept 8 and 12 characters and reject 7 and 13',async()=>{
 for(const [length,expected] of [[7,400],[8,200],[12,200],[13,400]]){
  const f=fixture();const r=await f.request('POST','/api/auth/register',{headers:WEB,body:{...body,password:'a'.repeat(length)}});
  assert.equal(r.statusCode,expected,`password length ${length}`);
 }
});
test('existing users with longer passwords can still log in',async()=>{
 const f=fixture();const password='previous-long-password';const salt='a'.repeat(32);
 const hash=require('node:crypto').scryptSync(password,salt,64).toString('hex');
 f.users.push({id:1,email:'old@example.com',name:'Existing',password_hash:salt+':'+hash});
 const r=await f.request('POST','/api/auth/login',{headers:WEB,body:{email:'old@example.com',password}});
 assert.equal(r.statusCode,200);assert.equal(r.data.user.name,'Existing');
});
