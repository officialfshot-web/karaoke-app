// Karaoke — YouTube Music + LRCLIB synced lyrics. Runs as a home-screen web app or inside ios/KaraokeApp.swift.
const $ = s => document.querySelector(s);
const store = {
  get(k, d) { try { const v = JSON.parse(localStorage.getItem(k)); return v ?? d; } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} }
};
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const decode = s => { const t = document.createElement('textarea'); t.innerHTML = s; return t.value; };
const fmt = s => { s = Math.max(0, s | 0); return `${(s / 60) | 0}:${String(s % 60).padStart(2, '0')}`; };
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const art = id => `background-image:url(https://i.ytimg.com/vi/${id}/hqdefault.jpg)`;
const REDIRECT = location.origin + location.pathname;
// Paste your Google "Web application" Client ID here so Sign in with Google works with no setup on the phone.
const GOOGLE_CLIENT_ID = '';
const ICON = {
  play: '<svg width="30" height="30" viewBox="0 0 24 24" fill="currentColor"><path d="M7 4.5v15a1 1 0 0 0 1.5.86l12.5-7.5a1 1 0 0 0 0-1.72L8.5 3.64A1 1 0 0 0 7 4.5z"/></svg>',
  pause: '<svg width="30" height="30" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16" rx="1.2"/><rect x="14" y="4" width="4" height="16" rx="1.2"/></svg>',
  heart: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-10-9.5C.4 8.2 2.3 4 6.4 4c2.4 0 4 1.4 5.6 3.4C13.6 5.4 15.2 4 17.6 4 21.7 4 23.6 8.2 22 11.5 19.5 16.4 12 21 12 21z"/></svg>',
  google: '<svg width="20" height="20" viewBox="0 0 48 48"><path fill="#FFC107" d="M43.6 20.5H42V20H24v8h11.3C33.7 32.7 29.2 36 24 36c-6.6 0-12-5.4-12-12s5.4-12 12-12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 12.9 4 4 12.9 4 24s8.9 20 20 20 20-8.9 20-20c0-1.3-.1-2.4-.4-3.5z"/><path fill="#FF3D00" d="M6.3 14.7l6.6 4.8C14.7 15.1 19 12 24 12c3.1 0 5.8 1.2 7.9 3.1l5.7-5.7C34 6.1 29.3 4 24 4 16.3 4 9.7 8.3 6.3 14.7z"/><path fill="#4CAF50" d="M24 44c5.2 0 9.9-2 13.4-5.2l-6.2-5.2C29.2 35.1 26.7 36 24 36c-5.2 0-9.6-3.3-11.3-7.9l-6.5 5C9.5 39.6 16.2 44 24 44z"/><path fill="#1976D2" d="M43.6 20.5H42V20H24v8h11.3c-.8 2.2-2.2 4.2-4.1 5.6l6.2 5.2C37 39.2 44 34 44 24c0-1.3-.1-2.4-.4-3.5z"/></svg>',
  user: '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="12" cy="8" r="4"/><path d="M4 21c1.5-4 4.5-6 8-6s6.5 2 8 6"/></svg>',
};

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

let toastT;
function toast(msg) {
  const t = $('#toast'); t.textContent = msg; t.classList.add('on');
  clearTimeout(toastT); toastT = setTimeout(() => t.classList.remove('on'), 3200);
}

/* ---------- Names: turn YouTube titles into "Song" + "Artist" ---------- */
function cleanTitle(t) {
  return t
    .replace(/[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k|remaster|m\/?v|live|color coded|explicit|clean)[^\)\]]*[\)\]]/gi, '')
    .replace(/\s+(ft\.?|feat\.?|featuring)\s.*$/i, '')
    .replace(/\s*[|｜].*$/, '')
    .replace(/["“”]/g, '').replace(/\s{2,}/g, ' ').trim();
}
function names(title = '', channel = '') {
  const ch = channel.replace(/\s*-\s*Topic$/i, '').replace(/VEVO$/i, '').replace(/\s*official$/i, '').trim();
  if (/ - Topic$/i.test(channel)) return { artist: ch, track: cleanTitle(title) };
  const m = title.match(/^(.+?)\s+[-–—]\s+(.+)$/);
  if (m) return { artist: cleanTitle(m[1]), track: cleanTitle(m[2]) };
  return { artist: ch, track: cleanTitle(title) || title };
}

/* ---------- Album-art accent colour ---------- */
const DEFAULT_ACC = [255, 90, 54];
function rgb2hsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2, d = mx - mn;
  if (!d) return [0, 0, l];
  const s = d / (1 - Math.abs(2 * l - 1));
  const h = mx === r ? ((g - b) / d + 6) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h * 60, s, l];
}
function hsl2rgb(h, s, l) {
  const c = (1 - Math.abs(2 * l - 1)) * s, x = c * (1 - Math.abs((h / 60) % 2 - 1)), m = l - c / 2;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return [r, g, b].map(v => Math.round((v + m) * 255));
}
function applyAccent([r, g, b]) {
  const [h, s] = rgb2hsl(r, g, b);
  const main = hsl2rgb(h, Math.max(s, .72), .6), second = hsl2rgb((h + 32) % 360, Math.max(s, .8), .62);
  const st = document.documentElement.style;
  st.setProperty('--acc', `rgb(${main})`); st.setProperty('--acc-rgb', main.join(','));
  st.setProperty('--acc2', `rgb(${second})`);
}
function accentFrom(id) {
  const img = new Image(); img.crossOrigin = 'anonymous';
  img.onload = () => {
    try {
      const c = document.createElement('canvas'); c.width = c.height = 24;
      const x = c.getContext('2d', { willReadFrequently: true });
      x.drawImage(img, 0, img.height * .14, img.width, img.height * .72, 0, 0, 24, 24);
      const d = x.getImageData(0, 0, 24, 24).data;
      let best = null, bs = -1;
      for (let i = 0; i < d.length; i += 4) {
        const [, s, l] = rgb2hsl(d[i], d[i + 1], d[i + 2]);
        const score = s * (1 - Math.abs(l - .5) * 1.7);
        if (score > bs) { bs = score; best = [d[i], d[i + 1], d[i + 2]]; }
      }
      applyAccent(bs > .12 ? best : DEFAULT_ACC);
    } catch { applyAccent(DEFAULT_ACC); }
  };
  img.onerror = () => applyAccent(DEFAULT_ACC);
  img.src = `https://i.ytimg.com/vi/${id}/mqdefault.jpg`;
}

/* ---------- Google sign-in (OAuth implicit redirect — works in iOS home-screen mode) ---------- */
let token = null;
(() => {
  const h = new URLSearchParams(location.hash.slice(1));
  if (h.get('access_token')) {
    token = h.get('access_token');
    store.set('tok', { token, exp: Date.now() + (+h.get('expires_in') || 3600) * 1000 });
    history.replaceState(null, '', location.pathname);
  } else {
    const t = store.get('tok');
    if (t && t.exp > Date.now() + 60000) token = t.token;
  }
})();
// Native iOS shell does sign-in itself and hands the token back here.
window.nativeToken = (t, secs) => {
  token = t; store.set('tok', { token, exp: Date.now() + secs * 1000 });
  renderAuth(); renderHome(); toast('Connected to YouTube Music');
};
function login() {
  if (window.webkit?.messageHandlers?.signIn) return window.webkit.messageHandlers.signIn.postMessage('');
  const cid = store.get('clientId', '') || GOOGLE_CLIENT_ID;
  if (!cid) { openSettings(); return toast('Add your Google Client ID first (see README)'); }
  const p = new URLSearchParams({
    client_id: cid, redirect_uri: REDIRECT, response_type: 'token',
    scope: 'https://www.googleapis.com/auth/youtube.readonly',
    include_granted_scopes: 'true', prompt: 'select_account'
  });
  location.href = 'https://accounts.google.com/o/oauth2/v2/auth?' + p;
}
function logout() { token = null; store.set('tok', null); playlists = null; forYou = null; renderAuth(); renderHome(); }
function renderAuth() {
  const b = $('#me');
  b.classList.toggle('in', !!token);
  b.innerHTML = token ? ICON.user : ICON.google;
}

async function yt(path, params) {
  const u = new URL('https://www.googleapis.com/youtube/v3/' + path);
  for (const k in params) u.searchParams.set(k, params[k]);
  const headers = {};
  if (token) headers.Authorization = 'Bearer ' + token;
  else {
    const key = store.get('apiKey', '');
    if (!key) throw new Error('Connect YouTube Music to search — or paste a song link.');
    u.searchParams.set('key', key);
  }
  const r = await fetch(u, { headers });
  if (r.status === 401) { logout(); throw new Error('Session expired — tap Connect again.'); }
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j;
}

/* ---------- Song lists ---------- */
const lists = {};   // key -> songs[]; tapping a song queues the list it came from
const songFromItem = it => {
  const sn = it.snippet || {};
  const id = it.contentDetails?.videoId || sn.resourceId?.videoId || it.id?.videoId || (typeof it.id === 'string' ? it.id : null);
  return { id, title: decode(sn.title || ''), channel: decode(sn.videoOwnerChannelTitle || sn.channelTitle || '') };
};
const MIN_SONG_SECS = 70;   // catches old-style Shorts and other short clips by duration
const isShort = x => {
  // YouTube extended Shorts up to 3 minutes, so duration alone no longer catches them all.
  // Shorts are vertical video though, and real music videos essentially never are — check the
  // actual thumbnail shape, which doesn't rot every time YouTube changes the duration cap.
  const t = x.snippet?.thumbnails;
  const best = t?.maxres || t?.standard || t?.high || t?.medium || t?.default;
  if (best && best.height > best.width) return true;
  return isoSecs(x.contentDetails.duration) < MIN_SONG_SECS;
};
async function songsByIds(ids) {   // resolves video IDs to songs, filtering out Shorts/clips
  if (!ids.length) return [];
  const v = await yt('videos', { part: 'snippet,contentDetails', id: ids.join(',') });
  return v.items.filter(x => !isShort(x)).map(songFromItem);
}
const tile = (s, key, i) => {
  const n = names(s.title, s.channel);
  return `<button class="tile tap" data-k="${key}" data-i="${i}"><i class="art cover" style="${art(s.id)}"></i><b class="ell">${esc(n.track)}</b><span class="ell">${esc(n.artist)}</span></button>`;
};
const row = (s, key, i, num) => {
  const n = names(s.title, s.channel);
  return `<button class="row tap${cur?.song.id === s.id ? ' playing' : ''}" data-k="${key}" data-i="${i}">${num ? `<span class="n">${i + 1}</span>` : ''}<i class="art cover" style="${art(s.id)}"></i><div><b class="ell">${esc(n.track)}</b><span class="ell">${esc(n.artist)}</span></div></button>`;
};

document.addEventListener('click', e => {
  const s = e.target.closest('[data-k]');
  if (s) return playList(lists[s.dataset.k], +s.dataset.i);
  const p = e.target.closest('[data-pl]');
  if (p) return openList(p.dataset.pl, p.dataset.name);
});

/* ---------- Home ---------- */
let playlists = null, forYou = null;
// "For you" is drawn from the account you're actually signed into: your liked songs, topped up from
// your own playlists if your likes are thin. YouTube Music's own home feed is NOT used — the app can
// only reach that anonymously, which just returns the same generic mood playlists it shows a
// logged-out visitor. Shuffled so the shelf is different every time you open the app.
async function loadForYou() {
  try {
    const liked = await yt('playlistItems', { part: 'snippet,contentDetails', playlistId: 'LL', maxResults: 50 })
      .then(j => j.items.map(i => i.contentDetails?.videoId || i.snippet?.resourceId?.videoId).filter(Boolean))
      .catch(() => []);
    let ids = liked;
    if (ids.length < 12 && playlists?.length) {   // not many likes — pull from one of your own playlists too
      const p = playlists[Math.floor(Math.random() * playlists.length)];
      const extra = await yt('playlistItems', { part: 'snippet,contentDetails', playlistId: p.id, maxResults: 50 })
        .then(j => j.items.map(i => i.contentDetails?.videoId || i.snippet?.resourceId?.videoId).filter(Boolean))
        .catch(() => []);
      ids = [...new Set([...ids, ...extra])];
    }
    const songs = await songsByIds(ids.slice(0, 50));
    for (let i = songs.length - 1; i > 0; i--) { const k = Math.floor(Math.random() * (i + 1)); [songs[i], songs[k]] = [songs[k], songs[i]]; }
    forYou = songs.slice(0, 12);
  } catch { forYou = []; }
  lists.foryou = forYou;
  const sec = $('#fySection');
  if (!sec) return;
  if (!forYou.length) return sec.remove();
  $('#fyRail').innerHTML = forYou.map((s, i) => tile(s, 'foryou', i)).join('');
}
function renderHome() {
  const hr = new Date().getHours();
  $('#hello').textContent = hr < 5 ? 'Late-night session' : hr < 12 ? 'Good morning' : hr < 18 ? 'Good afternoon' : 'Good evening';
  $('#headline').innerHTML = `What are we<br>singing <em>${hr >= 18 || hr < 5 ? 'tonight' : 'today'}?</em>`;
  lists.recent = store.get('recent', []);
  let h = '';
  if (!token) h += `<div class="connect fadeup" style="animation-delay:.12s">
      <h3>Bring your<br>YouTube Music.</h3>
      <p>Your likes and playlists, ready to sing. Or just paste any song link above.</p>
      <button class="gbtn tap" id="connectBtn">${ICON.google}Sign in with Google</button></div>`;
  if (lists.recent.length) h += `<h2 class="fadeup" style="animation-delay:.16s">Sing it again</h2><div class="rail fadeup" style="animation-delay:.2s">${lists.recent.map((s, i) => tile(s, 'recent', i)).join('')}</div>`;
  if (token && forYou?.length !== 0) {
    h += `<div class="fadeup" id="fySection" style="animation-delay:.19s"><h2>For you</h2><div class="rail" id="fyRail">${
      forYou ? forYou.map((s, i) => tile(s, 'foryou', i)).join('') : '<div class="tile"><i class="art skel"></i></div>'.repeat(4)
    }</div></div>`;
  }
  if (token) {
    h += `<h2 class="fadeup" style="animation-delay:.22s">Your library</h2><div class="grid fadeup" id="libGrid" style="animation-delay:.26s">
      <button class="liked tap" data-pl="LL" data-name="Liked songs">${ICON.heart}<b>Liked songs</b><span>Everything you’ve thumbs-upped</span></button>
      ${playlists ? plTiles() : '<div class="tile"><i class="art skel"></i></div>'.repeat(4)}</div>`;
  }
  $('#homeBody').innerHTML = h;
  $('#connectBtn')?.addEventListener('click', login);
  if (token && !playlists) loadPlaylists();
  if (token && forYou === null) loadForYou();
}
const plTiles = () => playlists.map(p => `<button class="tile tap" data-pl="${esc(p.id)}" data-name="${esc(p.title)}">
  <i class="art cover" style="${p.thumb ? `background-image:url(${esc(p.thumb)})` : ''}"></i><b class="ell">${esc(p.title)}</b><span>${p.count} songs</span></button>`).join('');
async function loadPlaylists() {
  try {
    const j = await yt('playlists', { part: 'snippet,contentDetails', mine: 'true', maxResults: 50 });
    playlists = j.items.map(p => ({ id: p.id, title: decode(p.snippet.title), thumb: p.snippet.thumbnails?.high?.url || p.snippet.thumbnails?.medium?.url, count: p.contentDetails.itemCount }));
  } catch (err) { playlists = []; toast(err.message); }
  const g = $('#libGrid');
  if (g) g.innerHTML = g.firstElementChild.outerHTML + plTiles();
}

/* ---------- Search / paste link ---------- */
const q = $('#q');
q.oninput = () => { $('#find').classList.toggle('has', !!q.value); if (!q.value) $('#results').innerHTML = ''; };
$('#clearQ').onclick = () => { q.value = ''; q.oninput(); q.focus(); };
$('#find').onsubmit = async e => {
  e.preventDefault(); q.blur();
  const v = q.value.trim(); if (!v) return;
  const vid = v.match(/(?:v=|youtu\.be\/|shorts\/|embed\/)([\w-]{11})/)?.[1];
  const list = v.match(/[?&]list=([\w-]+)/)?.[1];
  if (vid) { q.value = ''; q.oninput(); return playList([{ id: vid, title: '', channel: '' }], 0); }
  if (list) { q.value = ''; q.oninput(); return openList(list, 'Playlist'); }
  const out = $('#results');
  out.innerHTML = `<h2>Results</h2>` + `<div class="row"><i class="art skel"></i><div><b class="skel" style="height:14px;width:60%;border-radius:6px"></b></div></div>`.repeat(4);
  try {
    const j = await yt('search', { part: 'snippet', type: 'video', videoCategoryId: '10', maxResults: 25, q: v });
    lists.results = await songsByIds(j.items.map(i => i.id.videoId).filter(Boolean));
    out.innerHTML = `<h2>Results</h2>` + (lists.results.map((s, i) => row(s, 'results', i)).join('') || '<div class="hint">Nothing found. Try the artist name too.</div>');
  } catch (err) { out.innerHTML = `<div class="hint">${esc(err.message)}</div>`; }
};

/* ---------- Playlist page ---------- */
let listToken = 0;
async function openList(id, name) {
  const my = ++listToken;
  $('#list').classList.add('on');
  $('#listScroll').scrollTop = 0;
  $('#lTitle').textContent = name || 'Playlist';
  $('#lSub').textContent = 'Loading…';
  $('#collage').className = 'collage skel'; $('#collage').innerHTML = '';
  $('#tracks').innerHTML = `<div class="row"><i class="art skel"></i></div>`.repeat(6);
  lists.pl = [];
  let page;
  try {
    do {
      const p = { part: 'snippet,contentDetails', playlistId: id, maxResults: 50 };
      if (page) p.pageToken = page;
      const j = await yt('playlistItems', p);
      if (my !== listToken) return;
      const ids = j.items.map(i => i.contentDetails?.videoId || i.snippet?.resourceId?.videoId).filter(Boolean);
      lists.pl.push(...await songsByIds(ids));
      if (my !== listToken) return;
      page = j.nextPageToken;
      renderList();
    } while (page && lists.pl.length < 500);
  } catch (err) { $('#tracks').innerHTML = `<div class="hint">${esc(err.message)}</div>`; $('#lSub').textContent = ''; }
}
function renderList() {
  const s = lists.pl;
  $('#lSub').textContent = `${s.length} song${s.length === 1 ? '' : 's'}`;
  const c = $('#collage');
  const four = s.length >= 4 ? s.slice(0, 4) : s.slice(0, 1);
  c.className = 'collage' + (four.length === 1 ? ' one' : '');
  c.innerHTML = four.map(x => `<i class="cover" style="${art(x.id)}"></i>`).join('');
  $('#tracks').innerHTML = s.map((x, i) => row(x, 'pl', i, true)).join('') || '<div class="hint">This playlist is empty.</div>';
}
$('#listBack').onclick = () => $('#list').classList.remove('on');
$('#singAll').onclick = () => lists.pl?.length && playList(lists.pl, 0);
$('#shuffle').onclick = () => {
  if (!lists.pl?.length) return;
  const s = [...lists.pl];
  for (let i = s.length - 1; i > 0; i--) { const j = (Math.random() * (i + 1)) | 0; [s[i], s[j]] = [s[j], s[i]]; }
  playList(s, 0);
};

/* ---------- Sheets ---------- */
function sheet(id, on) { $(id).classList.toggle('on', on); }
document.querySelectorAll('.sheet-bg').forEach(b => b.addEventListener('click', e => { if (e.target === b) sheet('#' + b.id, false); }));
function openSettings() {
  $('#cid').value = store.get('clientId', '');
  $('#akey').value = store.get('apiKey', '');
  $('#redir').textContent = REDIRECT;
  $('#acctState').textContent = token ? 'Connected to YouTube Music.' : 'Not connected.';
  $('#signOut').style.display = token ? '' : 'none';
  sheet('#setSheet', true);
}
$('#me').onclick = () => token ? openSettings() : login();
$('#saveSet').onclick = () => {
  store.set('clientId', $('#cid').value.trim());
  store.set('apiKey', $('#akey').value.trim());
  sheet('#setSheet', false);
  if (!token && store.get('clientId', '')) login();
};
$('#signOut').onclick = () => { logout(); sheet('#setSheet', false); };

/* ---------- Player ---------- */
let player = null, ytReady = false, pending = null, cur = null, queue = [], qi = 0;
let lines = [], active = -2, offset = 0, plain = false, endTimer = null;
// Timing model: lyric time = video time + delta. `offset` is the delta from the start of the song;
// each anchor {v, d} (set by holding a line) switches the delta to d from video time v onward.
// That handles music videos that add a skit or break mid-song, which a single offset can't.
let anchors = [];
const deltaAt = v => { let d = offset; for (const a of anchors) if (a.v <= v) d = a.d; return d; };
const videoTimeFor = lt => { let v = lt - offset; for (let k = 0; k < 3; k++) v = lt - deltaAt(v); return v; };
window.onYouTubeIframeAPIReady = () => { ytReady = true; if (pending) { const p = pending; pending = null; openSong(p); } };

function playList(songs, i) { queue = songs.slice(); qi = i; openSong(queue[qi]); }
function step(d) {
  if (!queue[qi + d]) return toast(d > 0 ? 'That was the last song' : 'This is the first song');
  qi += d; openSong(queue[qi]);
}

function openSong(song) {
  $('#player').classList.add('on');
  hideEnd();
  cur = { song, requested: false };
  const r = store.get('recent', []).filter(x => x.id !== song.id);
  r.unshift(song); store.set('recent', r.slice(0, 20));
  loadTiming(song.id);
  setMeta(song.title, song.channel);
  setArt(song.id);
  syncMode(false);
  skeleton();
  $('#prev').style.opacity = queue[qi - 1] ? 1 : .35;
  $('#next').style.opacity = queue[qi + 1] ? 1 : .35;
  if (!ytReady) { pending = song; return; }
  if (!player) {
    player = new YT.Player('yt', {
      videoId: song.id,
      playerVars: { playsinline: 1, rel: 0, modestbranding: 1, autoplay: 1, iv_load_policy: 3 },
      events: { onReady: () => { player.playVideo(); maybeFetch(); }, onStateChange: onState, onError: onErr }
    });
  } else player.loadVideoById(song.id);
  if (song.title) maybeFetch();
}
function setArt(id) {
  document.querySelectorAll('.amb i').forEach(i => i.style.cssText = art(id));
  $('#mArt').style.cssText = art(id); $('#eArt').style.cssText = art(id);
  accentFrom(id);
}
function setMeta(title, channel) {
  const n = names(title, channel);
  $('#pt').textContent = n.track || 'Loading…'; $('#ps').textContent = n.artist;
  $('#mT').textContent = n.track; $('#mS').textContent = n.artist;
}

function onState(e) {
  const playing = e.data === YT.PlayerState.PLAYING;
  $('#pp').innerHTML = playing ? ICON.pause : ICON.play;
  $('#mPP').innerHTML = (playing ? ICON.pause : ICON.play).replace(/30/g, 24);
  if (e.data === YT.PlayerState.ENDED) showEnd();
  maybeFetch();
}
function onErr(e) {
  if (cur?.orig) { const o = cur.orig; cur.orig = null; cur.song = o; queue[qi] = o; player.loadVideoById(o.id); return syncMode(true, 'Tap a line the moment it’s sung to sync.'); }
  const blocked = 'The artist blocks this video outside YouTube.<br>Search for an “audio” or “lyrics” version instead.';
  const m = { 2: 'That link looks broken.', 5: 'Playback hiccup — try again.', 100: 'This video is gone or private.', 101: blocked, 150: blocked };
  showMsg('Can’t play this one', m[e.data] || 'Playback hiccup — try again.');
}

function maybeFetch() {
  if (!cur || cur.requested) return;
  const vd = player?.getVideoData?.() || {};
  const title = cur.song.title || vd.title, channel = cur.song.channel || vd.author || '';
  if (!title) return;
  cur.requested = true;
  if (!cur.song.title) { cur.song.title = title; cur.song.channel = channel; const r = store.get('recent', []); if (r[0]?.id === cur.song.id) { r[0] = cur.song; store.set('recent', r); } }
  setMeta(title, channel);
  const n = names(title, channel);
  $('#lyrQ').value = `${n.artist} ${n.track}`.trim();
  (nativeHttpOK() ? loadYtmLyrics : loadLyrics)(n.artist, n.track, cur.song.id);
}

/* ---------- Lyrics ---------- */
async function lrclib(params) {
  try { const r = await fetch('https://lrclib.net/api/search?' + new URLSearchParams(params)); return r.ok ? await r.json() : []; }
  catch { return []; }
}
const VERSIONY = /\b(live|remix|acoustic|sped|slowed|nightcore|karaoke|instrumental|demo|edit|version|mix)\b/i;
const lyrScore = x => {
  const dur = player?.getDuration?.() || 0;
  const wantVer = VERSIONY.test(cur?.song.title || '');
  return (x.syncedLyrics ? 1000 : x.plainLyrics ? 500 : 0)
    - (dur && x.duration ? Math.min(450, Math.abs(x.duration - dur) * 6) : 0)
    - (!wantVer && VERSIONY.test(`${x.trackName} ${x.albumName}`) ? 150 : 0);
};
// YouTube reports the old video's duration for a moment after a switch, so wait for the real one
async function videoDuration(vid) {
  for (let k = 0; k < 60; k++) {
    if (cur?.song.id !== vid) return 0;
    const d = player?.getDuration?.() || 0;
    if (d > 0 && player.getVideoData?.().video_id === vid) return d;
    await new Promise(r => setTimeout(r, 100));
  }
  return 0;
}
async function loadLyrics(artist, track, vid) {
  let list = await lrclib({ track_name: track, artist_name: artist });
  if (!list.some(x => x.syncedLyrics)) list = list.concat(await lrclib({ q: `${artist} ${track}` }));
  if (!list.length) list = await lrclib({ q: track });
  const dur = await videoDuration(vid);
  if (cur?.song.id !== vid) return;
  list.sort((a, b) => lyrScore(b) - lyrScore(a));
  useLyrics(list[0], track);
  if (list[0]?.syncedLyrics && list[0].duration && dur) checkVersion(list[0], dur, artist, track, vid);
}

/* ---------- Music-video vs album timing ---------- */
// Synced lyrics are timed to the album track. Music videos often add an intro, so if the
// lengths don't match, swap to the album ("- Topic") upload, or ask for one tap to sync.
async function checkVersion(hit, dur, artist, track, vid) {
  const diff = dur - hit.duration;
  if (Math.abs(diff) < 1 || store.get('offsets', {})[vid] !== undefined) return;
  if (!/ - Topic$/i.test(cur.song.channel) && (nativeHttpOK() || token || store.get('apiKey', ''))) {
    const alt = await findAlbumVersion(artist, track, hit.duration);
    if (alt && cur?.song.id === vid) return swapTo(alt);
  }
  if (cur?.song.id !== vid) return;
  if (Math.abs(diff) <= 15) {
    // the extra (or missing) seconds are almost always an intro: shift the lyrics by that much
    offset = -Math.round(diff * 10) / 10; saveOffset(); active = -2;
    toast(`This video has a ${Math.abs(diff).toFixed(1)}s ${diff > 0 ? 'longer' : 'shorter'} intro, lyrics shifted to match`);
  } else syncMode(true, 'This version is timed differently. Tap a line the moment it’s sung.');
}
const isoSecs = d => { const m = d.match(/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/) || []; return (+m[1] || 0) * 3600 + (+m[2] || 0) * 60 + (+m[3] || 0); };
// The iPhone app can query YouTube Music's own song search (no sign-in needed); browsers can't.
const nativeHttpOK = () => !!window.webkit?.messageHandlers?.http;
async function ytm(ep, body, android) {
  const client = android
    ? { clientName: 'ANDROID_MUSIC', clientVersion: '7.27.52', androidSdkVersion: 34, hl: 'en', gl: 'US' }
    : { clientName: 'WEB_REMIX', clientVersion: '1.20250101.01.00', hl: 'en', gl: 'US' };
  return JSON.parse(await nhttp(`https://music.youtube.com/youtubei/v1/${ep}?prettyPrint=false`, JSON.stringify({ ...body, context: { client } }),
    android ? { 'User-Agent': 'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip' } : {}));
}
const nhttp = (url, body, headers = {}) => window.webkit.messageHandlers.http.postMessage(body ? { url, body, headers } : { url, headers });

/* ---------- Word-by-word timing (NetEase "yrc" lyrics: every word has its own start + length) ---------- */
async function neteaseWords(artist, track) {
  const H = { Referer: 'https://music.163.com/' }, a = artist.toLowerCase();
  const s = JSON.parse(await nhttp('https://music.163.com/api/search/get?' + new URLSearchParams({ s: `${artist} ${track}`, type: 1, limit: 8 }), null, H));
  const songs = (s.result?.songs || []).filter(x => x.artists?.some(r => { const n = r.name.toLowerCase(); return a.includes(n) || n.includes(a); }));
  for (const sg of songs.slice(0, 3)) {
    const l = JSON.parse(await nhttp(`https://music.163.com/api/song/lyric/v1?id=${sg.id}&lv=0&yv=0&tv=0`, null, H));
    const lines = parseYrc(l.yrc?.lyric || '');
    if (lines.length > 3) return { dur: sg.duration / 1000, lines };
  }
  return null;
}
function parseYrc(s) {
  const out = [];
  for (const row of s.split('\n')) {
    const m = row.match(/^\[(\d+),(\d+)\](.*)$/); if (!m) continue;
    const ws = [...m[3].matchAll(/\((\d+),(\d+),\d+\)([^(]*)/g)].map(x => ({ t: +x[1] / 1000, e: (+x[1] + +x[2]) / 1000, raw: x[3] })).filter(x => x.raw.trim());
    if (!ws.length) continue;
    out.push({ t: +m[1] / 1000, end: (+m[1] + +m[2]) / 1000, text: ws.map(x => x.raw).join('').trim(),
      wt: ws.map(x => ({ t: x.t, e: x.e, w: x.raw.trim(), sp: /\s$/.test(x.raw) })) });
  }
  return out;
}
// Line up the word timings with YouTube Music's line timings for the exact track that's playing.
// Only used when most lines agree on one offset; otherwise it's a different edit and we don't trust it.
function alignWords(nw, ls, dur) {
  const norm = s => s.toLowerCase().replace(/[^a-z0-9 ]/g, '').split(/\s+/).slice(0, 4).join(' ');
  const shift = d => nw.lines.map(l => ({ ...l, t: l.t + d, end: l.end + d, wt: l.wt.map(w => ({ ...w, t: w.t + d, e: w.e + d })) }));
  if (ls?.length) {
    const diffs = [];
    for (const l of ls) {
      if (!l.text) continue;
      const n = norm(l.text), w = nw.lines.find(x => norm(x.text) === n && Math.abs(x.t - l.t) < 20);
      if (w) diffs.push(l.t - w.t);
    }
    if (diffs.length < 3) return null;
    diffs.sort((x, y) => x - y);
    const d = diffs[diffs.length >> 1];
    return diffs.filter(x => Math.abs(x - d) < .7).length >= diffs.length * .8 ? shift(d) : null;
  }
  return dur && Math.abs(nw.dur - dur) <= 2 ? nw.lines : null;
}
const deepFind = (o, k) => {
  if (!o || typeof o !== 'object') return undefined;
  if (k in o) return o[k];
  for (const v of Object.values(o)) { const r = deepFind(v, k); if (r !== undefined) return r; }
};
// YouTube Music's own synced lyrics: timed to that exact track, so they match what's playing
async function ytmLyrics(id) {
  const bid = JSON.stringify(await ytm('next', { videoId: id })).match(/"(MPLY[^"]+)"/)?.[1];
  if (!bid) return null;
  const t = deepFind(await ytm('browse', { browseId: bid }, true), 'timedLyricsData');
  if (!t?.length) return null;
  return t.map(x => ({ t: +x.cueRange.startTimeMilliseconds / 1000, end: +x.cueRange.endTimeMilliseconds / 1000, text: (x.lyricLine || '').replace(/^♪$/, '').trim() }));
}
function withGaps(ls) {
  const res = [];
  if (ls[0]?.t > 4) res.push({ t: 0, text: '' });
  ls.forEach((l, i) => { res.push(l); const nx = ls[i + 1]; if (l.text && nx && nx.t - l.end > 6) res.push({ t: l.end + .3, text: '' }); });
  return res;
}
async function loadYtmLyrics(artist, track, vid) {
  try {
    let id = vid;
    const wordsP = neteaseWords(artist, track).catch(() => null);
    if (!/ - Topic$/i.test(cur.song.channel)) {
      // play the album track: it's what YouTube Music's lyrics are timed to
      const a = artist.toLowerCase(), songs = await ytmSongs(`${artist} ${track}`);
      const m = songs.find(x => x.artist.toLowerCase().includes(a));
      if (m && cur?.song.id === vid) { swapTo({ id: m.id, title: m.title, channel: `${m.artist} - Topic` }); id = m.id; }
    }
    const ls = await ytmLyrics(id).catch(() => null);
    const words = await wordsP;
    if (cur?.song.id !== id) return;
    const exact = words && alignWords(words, ls, await videoDuration(id));
    if (cur?.song.id !== id) return;
    if (exact) { plain = false; return setLyrics(withGaps(exact)); }
    if (ls) { plain = false; return setLyrics(withGaps(ls)); }
  } catch {}
  if (cur) loadLyrics(artist, track, cur.song.id);
}
async function ytmSongs(q) {
  const j = await ytm('search', { query: q, params: 'EgWKAQIIAWoKEAkQBRAKEAMQBA==' });
  const out = [];
  (function walk(o) {
    if (!o || typeof o !== 'object') return;
    const r = o.musicResponsiveListItemRenderer;
    if (r) {
      const cols = (r.flexColumns || []).map(c => (c.musicResponsiveListItemFlexColumnRenderer?.text?.runs || []).map(x => x.text).join(''));
      const parts = (cols[1] || '').split(' • '), dm = parts[parts.length - 1].match(/^(?:(\d+):)?(\d+):(\d{2})$/);
      if (r.playlistItemData?.videoId && dm) out.push({ id: r.playlistItemData.videoId, title: cols[0], artist: parts[0], d: (+dm[1] || 0) * 3600 + +dm[2] * 60 + +dm[3] });
      return;
    }
    for (const k in o) walk(o[k]);
  })(j);
  return out;
}
async function findAlbumVersion(artist, track, target) {
  if (nativeHttpOK()) {
    try {
      const a = artist.toLowerCase();
      const m = (await ytmSongs(`${artist} ${track}`)).filter(x => Math.abs(x.d - target) <= 2)
        .sort((x, y) => y.artist.toLowerCase().includes(a) - x.artist.toLowerCase().includes(a))[0];
      if (m) return { id: m.id, title: m.title, channel: `${m.artist} - Topic` };
    } catch {}
  }
  if (!token && !store.get('apiKey', '')) return null;
  try {
    const s = await yt('search', { part: 'snippet', type: 'video', videoCategoryId: '10', maxResults: 10, q: `${artist} ${track}` });
    const ids = s.items.map(i => i.id.videoId).filter(Boolean);
    if (!ids.length) return null;
    const v = await yt('videos', { part: 'snippet,contentDetails,status', id: ids.join(',') });
    const c = v.items
      .filter(x => x.status?.embeddable !== false && Math.abs(isoSecs(x.contentDetails.duration) - target) <= 2)
      .map(x => ({ id: x.id, title: decode(x.snippet.title), channel: decode(x.snippet.channelTitle) }))
      .sort((a, b) => / - Topic$/.test(b.channel) - / - Topic$/.test(a.channel));
    return c[0] || null;
  } catch { return null; }
}
function swapTo(alt) {
  cur.orig = cur.song; cur.song = alt;
  queue[qi] = alt;
  const r = store.get('recent', []); if (r[0]?.id === cur.orig.id) { r[0] = alt; store.set('recent', r); }
  loadTiming(alt.id);
  setArt(alt.id);
  player.loadVideoById(alt.id);
  toast('Playing the album version so the lyrics line up');
}
function useLyrics(hit, track) {
  if (!hit || (!hit.syncedLyrics && !hit.plainLyrics && !hit.instrumental))
    return showMsg('No lyrics yet', `Couldn’t find words for “${esc(track || 'this song')}”.<br>Tap ••• to search by hand.`);
  if (hit.instrumental) return showMsg('Instrumental', 'No words — just vibe.');
  if (hit.syncedLyrics) { plain = false; setLyrics(parseLRC(hit.syncedLyrics)); }
  else {
    plain = true;
    const ls = hit.plainLyrics.split(/\r?\n/).filter(l => l.trim());
    const d = player?.getDuration?.() || hit.duration || 200;
    setLyrics(ls.map((text, i) => ({ t: d * .08 + d * .85 * i / ls.length, text })));
    toast('Only unsynced lyrics found — scrolling at an even pace');
  }
}
$('#lyrForm').onsubmit = async e => {
  e.preventDefault(); $('#lyrQ').blur();
  const v = $('#lyrQ').value.trim(); if (!v) return;
  const box = $('#lyrChoices');
  box.innerHTML = '<div class="choice skel" style="height:58px"></div>'.repeat(3);
  const list = (await lrclib({ q: v })).sort((a, b) => lyrScore(b) - lyrScore(a)).slice(0, 12);
  box.innerHTML = list.map((x, i) => `<button class="choice tap" data-c="${i}"><div><b class="ell">${esc(x.trackName)}</b><span class="ell">${esc(x.artistName)} · ${fmt(x.duration)}</span></div>
    <span class="tag${x.syncedLyrics ? '' : ' off'}">${x.syncedLyrics ? 'SYNCED' : x.instrumental ? 'INSTR' : 'PLAIN'}</span></button>`).join('') || '<p>No matches. Try fewer words.</p>';
  box.onclick = ev => { const c = ev.target.closest('[data-c]'); if (c) { useLyrics(list[+c.dataset.c]); sheet('#optSheet', false); } };
};

function parseLRC(s) {
  const out = [];
  for (const line of s.split(/\r?\n/)) {
    const tags = [...line.matchAll(/\[(\d+):(\d+(?:\.\d+)?)\]/g)];
    if (!tags.length) continue;
    let text = line.replace(/\[[^\]]*\]/g, '');
    let wt = null;   // real per-word timings, when the lyrics have them
    if (/<\d+:\d+(?:\.\d+)?>/.test(text)) {
      wt = [...text.matchAll(/<(\d+):(\d+(?:\.\d+)?)>([^<]*)/g)].map(m => ({ t: +m[1] * 60 + +m[2], w: m[3].trim() })).filter(x => x.w);
      text = wt.map(x => x.w).join(' ');
    }
    text = text.trim();
    for (const m of tags) out.push({ t: +m[1] * 60 + +m[2], text, wt });
  }
  out.sort((a, b) => a.t - b.t);
  // add countdown dots for the intro and any long instrumental break
  const res = [];
  if (out.length && out[0].t > 4) res.push({ t: 0, text: '' });
  out.forEach((l, i) => {
    res.push(l);
    const nx = out[i + 1];
    if (l.text && nx && nx.text && nx.t - l.t > 10) res.push({ t: l.t + Math.min(6, l.text.length * .09 + 2), text: '' });
  });
  return res;
}

function setLyrics(ls) {
  lines = ls; active = -2;
  $('#lmsg').style.display = 'none';
  $('#lyrIn').innerHTML = ls.map((l, i) => {
    if (!l.text) return `<div class="ln gap" data-i="${i}"><i></i><i></i><i></i></div>`;
    const nx = ls[i + 1]?.t ?? l.t + 6;
    if (l.wt?.length) {
      l.words = l.wt.map((x, k) => ({ text: x.w, sp: x.sp ?? true, ta: x.t, tb: x.e ?? l.wt[k + 1]?.t ?? Math.min(nx, x.t + .7) }));
    } else {
      // no word timings: give each word time by its syllables, and let the last word ring out
      const ws = l.text.split(/\s+/);
      const wt = ws.map((w, k) => syllables(w) + .35 + (k === ws.length - 1 ? 1.2 : 0));
      const total = wt.reduce((a, b) => a + b, 0);
      const span = l.end ? Math.max(.8, l.end - l.t - .1) : Math.max(.8, Math.min(nx - l.t - .15, total * .3 + .6));
      let acc = 0;
      l.words = ws.map((w, k) => { const ta = l.t + acc / total * span; acc += wt[k]; return { text: w, ta, tb: l.t + acc / total * span }; });
    }
    return `<div class="ln${plain ? '' : ' tap'}" data-i="${i}">${l.words.map((w, k) => `<span class="w">${esc(w.text)}</span>` + (k < l.words.length - 1 && w.sp !== false ? ' ' : '')).join('')}</div>`;
  }).join('');
  [...$('#lyrIn').children].forEach((el, i) => { ls[i].el = el; ls[i].spans = el.querySelectorAll('.w'); ls[i].dots = el.querySelectorAll('i'); });
  center(ls[0]?.el);
}
function syllables(w) {
  const latin = w.toLowerCase().replace(/[^a-z']/g, '');
  if (!latin) return Math.max(1, Math.ceil(w.length / 2));
  return Math.max(1, (latin.replace(/(?:[^laeiouy]es|ed|[^laeiouy]e)$/, '').match(/[aeiouy]+/g) || []).length);
}
function skeleton() {
  lines = []; $('#lmsg').style.display = 'none';
  $('#lyrIn').innerHTML = [72, 90, 58, 80].map(w => `<div class="ln sk" style="width:${w}%"></div>`).join('');
  center($('#lyrIn').firstElementChild);
}
function showMsg(title, body) {
  lines = []; $('#lyrIn').innerHTML = '';
  $('#lmsg').innerHTML = `<b>${title}</b><div>${body}</div>`;
  $('#lmsg').style.display = 'flex';
}
function center(el) {
  if (!el) return;
  const f = innerWidth > innerHeight && innerHeight < 620 ? .42 : .3;   // sideways: keep the line near the middle
  $('#lyrIn').style.transform = `translateY(${$('#lyr').clientHeight * f - el.offsetTop - el.offsetHeight / 2}px)`;
}

// Tap a line to jump there. Hold a line (or tap it in sync mode) = "this is being sung right now".
const lineAt = e => { const ln = e.target.closest('.ln'); return ln && !ln.classList.contains('sk') && !plain && player ? ln : null; };
let holdT = null, held = false, downXY = null;
$('#lyrIn').onpointerdown = e => {
  const ln = lineAt(e); if (!ln || ln.classList.contains('gap')) return;
  held = false; downXY = [e.clientX, e.clientY];
  holdT = setTimeout(() => { held = true; syncLine(+ln.dataset.i); }, 450);
};
$('#lyrIn').onpointermove = e => { if (holdT && downXY && Math.hypot(e.clientX - downXY[0], e.clientY - downXY[1]) > 10) { clearTimeout(holdT); holdT = null; } };
$('#lyrIn').onpointerup = $('#lyrIn').onpointercancel = () => { clearTimeout(holdT); holdT = null; };
$('#lyrIn').onclick = e => {
  const ln = lineAt(e); if (!ln) return;
  if (held) { held = false; return; }
  if (syncing && !ln.classList.contains('gap')) return syncLine(+ln.dataset.i);
  player.seekTo(Math.max(0, videoTimeFor(lines[+ln.dataset.i].t) - .15), true);
  player.playVideo();
};
function syncLine(i) {
  const v = now() - .25;   // you react ~0.25s after you hear it
  const d = Math.round((lines[i].t - v) * 20) / 20;
  if (v < 40) { offset = d; anchors = anchors.filter(a => a.v > v + 4); }   // early on it's an intro thing: fix from the start
  else anchors = [...anchors.filter(a => Math.abs(a.v - v) > 4), { v, d }].sort((a, b) => a.v - b.v);
  saveOffset(); syncMode(false); active = -2;
  lines[i].el.animate([{ transform: 'scale(1.08)' }, { transform: 'none' }], { duration: 350, easing: 'cubic-bezier(.3,1.6,.5,1)' });
  toast('Synced ✓ from here on');
}

/* ---------- Frame loop ---------- */
let dragging = false, lastRaw = 0, lastAt = 0;
// YouTube's time updates in steps; fill in between so word highlighting moves smoothly
function now() {
  const r = player.getCurrentTime() || 0, ts = performance.now();
  if (r !== lastRaw) { lastRaw = r; lastAt = ts; return r; }
  if (player.getPlayerState?.() !== YT.PlayerState.PLAYING) return r;
  return r + Math.min(.5, (ts - lastAt) / 1000 * (player.getPlaybackRate?.() || 1));
}
function tick() {
  requestAnimationFrame(tick);
  if (!player?.getCurrentTime) return;
  const raw = now(), dur = player.getDuration() || 0;
  const pct = dur ? raw / dur * 100 : 0;
  $('#mProg').style.width = pct + '%';
  $('#mini').classList.toggle('on', !!cur && !$('#player').classList.contains('on'));
  if (!$('#player').classList.contains('on')) return;
  if (!dragging) { $('#fl').style.width = pct + '%'; $('#kn').style.left = pct + '%'; $('#tcur').textContent = fmt(raw); }
  $('#tdur').textContent = fmt(dur);
  if (!lines.length) return;

  const t = raw + deltaAt(raw);
  let i = -1;
  for (let k = 0; k < lines.length; k++) { if (lines[k].t <= t) i = k; else break; }
  if (i !== active) {
    lines.forEach((l, k) => {
      l.el.classList.toggle('on', k === i);
      l.el.classList.toggle('past', k < i);
      l.el.dataset.d = k > i ? Math.min(3, k - i) : 0;
      if (k !== i) l.spans.forEach(s => { s.style.setProperty('--wp', k < i ? '100%' : '0%'); s.classList.remove('now'); });
      if (k !== i) l.dots.forEach(d => d.classList.remove('lit'));
    });
    active = i;
    center(lines[Math.max(0, i)].el);
  }
  if (i < 0) return;
  const L = lines[i], nx = lines[i + 1]?.t ?? L.t + 6;
  if (L.text) {
    L.words.forEach((w, k) => {
      const wp = clamp((t - w.ta) / Math.max(.05, w.tb - w.ta));
      L.spans[k].style.setProperty('--wp', (wp * 100).toFixed(1) + '%');
      L.spans[k].classList.toggle('now', wp > 0 && wp < 1);
    });
  } else {
    const remain = nx - t;   // 3 · 2 · 1 countdown into the next line
    L.dots.forEach((d, k) => d.classList.toggle('lit', remain <= 3 - k + .05 && remain > 0));
  }
}
requestAnimationFrame(tick);

/* ---------- Scrubber ---------- */
const bar = $('#bar');
function scrubTo(e) {
  const r = bar.getBoundingClientRect(), p = clamp((e.clientX - r.left) / r.width);
  $('#fl').style.width = p * 100 + '%'; $('#kn').style.left = p * 100 + '%';
  $('#tcur').textContent = fmt(p * (player?.getDuration?.() || 0));
  return p;
}
bar.onpointerdown = e => { dragging = true; bar.classList.add('drag'); bar.setPointerCapture(e.pointerId); scrubTo(e); };
bar.onpointermove = e => { if (dragging) scrubTo(e); };
bar.onpointerup = e => {
  if (!dragging) return;
  dragging = false; bar.classList.remove('drag');
  player?.seekTo?.(scrubTo(e) * player.getDuration(), true);
};

/* ---------- Controls ---------- */
function togglePlay() {
  if (!player?.getPlayerState) return;
  player.getPlayerState() === YT.PlayerState.PLAYING ? player.pauseVideo() : player.playVideo();
}
$('#pp').innerHTML = ICON.play;
$('#pp').onclick = togglePlay;
$('#mPP').onclick = e => { e.stopPropagation(); togglePlay(); };
$('#mini').onclick = () => $('#player').classList.add('on');
$('#close').onclick = () => { $('#player').classList.remove('on'); renderHome(); };
$('#prev').onclick = () => (player?.getCurrentTime?.() > 5 ? player.seekTo(0, true) : step(-1));
$('#next').onclick = () => step(1);
$('#vidBtn').onclick = () => { $('#vid').classList.toggle('small'); setTimeout(() => { active = -2; }, 520); };

/* ---------- Reactive glow (mic-driven ambient pulse + pitch-colored lyric glow) ---------- */
let reactiveStream = null, reactiveCtx = null, reactiveAnalyser = null, reactiveBuf = null, reactiveLevel = 0, reactiveHue = 14;

// Autocorrelation pitch detector (same approach as Chrome Music Lab's pitch detector).
// Finds the fundamental frequency of a voice in the time-domain signal — not scientifically
// precise, but plenty accurate for a visual "what note is this roughly" effect.
function detectPitch(buf, sampleRate) {
  const SIZE = buf.length;
  let rms = 0;
  for (let i = 0; i < SIZE; i++) rms += buf[i] * buf[i];
  rms = Math.sqrt(rms / SIZE);
  if (rms < .012) return -1;   // too quiet — don't guess a pitch out of noise
  const thres = .2;
  let r1 = 0, r2 = SIZE - 1;
  for (let i = 0; i < SIZE >> 1; i++) if (Math.abs(buf[i]) < thres) { r1 = i; break; }
  for (let i = 1; i < SIZE >> 1; i++) if (Math.abs(buf[SIZE - i]) < thres) { r2 = SIZE - i; break; }
  const b = buf.subarray(r1, r2), n = b.length;
  const c = new Float32Array(n);
  for (let i = 0; i < n; i++) { let s = 0; for (let j = 0; j < n - i; j++) s += b[j] * b[j + i]; c[i] = s; }
  let d = 0; while (d < n - 1 && c[d] > c[d + 1]) d++;
  let maxVal = -1, T0 = -1;
  for (let i = d; i < n; i++) if (c[i] > maxVal) { maxVal = c[i]; T0 = i; }
  if (T0 > 0 && T0 < n - 1) {   // parabolic interpolation for sub-sample precision
    const x1 = c[T0 - 1], x2 = c[T0], x3 = c[T0 + 1], a = (x1 + x3 - 2 * x2) / 2, b2 = (x3 - x1) / 2;
    if (a) T0 -= b2 / (2 * a);
  }
  return T0 > 0 ? sampleRate / T0 : -1;
}
const freqToHue = f => { const lo = 90, hi = 700, t = clamp(Math.log2(Math.max(f, lo) / lo) / Math.log2(hi / lo)); return 220 - t * 220; };

/* ---------- Pitch meter: a live glowing puck on a fixed track, not a scrolling graph ---------- */
const PT_LO = -16, PT_HI = 16;   // semitones relative to A4, ~2.7 octaves of range
let lastFreq = -1, smoothSemi = NaN, trendBuf = [], holdBuf = [], lastSpark = 0;
const NOTE_NAMES_FROM_C = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
function noteNameFor(semi) {   // semi is relative to A4=0; octave rolls over at C, like real sheet music
  const r = Math.round(semi), sfc = r + 9;
  return NOTE_NAMES_FROM_C[((sfc % 12) + 12) % 12] + (4 + Math.floor(sfc / 12));
}
function updatePitchMeter(semi) {
  const puck = $('#ptPuck'), note = $('#ptNote'), hint = $('#ptHint');
  if (Number.isNaN(semi)) {
    puck.style.opacity = 0; hint.classList.remove('show'); note.textContent = '—';
    trendBuf = []; holdBuf = [];
    return;
  }
  puck.style.opacity = 1;
  puck.style.left = (clamp((semi - PT_LO) / (PT_HI - PT_LO)) * 100).toFixed(1) + '%';
  note.textContent = noteNameFor(semi);

  // direction hint: compare now to ~a third of a second ago, so it reads as a trend, not noise
  trendBuf.push(semi);
  if (trendBuf.length > 16) trendBuf.shift();
  if (trendBuf.length >= 12) {
    const delta = trendBuf[trendBuf.length - 1] - trendBuf[0];
    if (delta > .7) { hint.textContent = '▲ going higher'; hint.classList.add('show'); }
    else if (delta < -.7) { hint.textContent = '▼ going lower'; hint.classList.add('show'); }
    else hint.classList.remove('show');
  }

  // Guitar Hero-style payoff: holding a steady note sparks the puck, like nailing a note
  holdBuf.push(semi);
  if (holdBuf.length > 14) holdBuf.shift();
  if (holdBuf.length === 14) {
    const mean = holdBuf.reduce((a, b) => a + b, 0) / 14;
    const variance = holdBuf.reduce((a, b) => a + (b - mean) ** 2, 0) / 14;
    const now = performance.now();
    if (variance < .05 && now - lastSpark > 550) {
      puck.classList.remove('pspark'); void puck.offsetWidth; puck.classList.add('pspark');
      lastSpark = now;
    }
  }
}

function reactiveFrame() {
  if (!reactiveAnalyser) return;
  requestAnimationFrame(reactiveFrame);
  reactiveAnalyser.getFloatTimeDomainData(reactiveBuf);
  let sum = 0;
  for (let i = 0; i < reactiveBuf.length; i++) sum += reactiveBuf[i] * reactiveBuf[i];
  const rms = Math.sqrt(sum / reactiveBuf.length);
  reactiveLevel += (clamp(rms * 4) - reactiveLevel) * .25;
  document.documentElement.style.setProperty('--reactive', reactiveLevel.toFixed(3));
  lastFreq = detectPitch(reactiveBuf, reactiveCtx.sampleRate);   // every frame now — halving the rate was adding real latency
  if (lastFreq > 0) {
    reactiveHue += (freqToHue(lastFreq) - reactiveHue) * .25;
    document.documentElement.style.setProperty('--pitch-hue', reactiveHue.toFixed(1));
  }
  // smooth the live reading instead of jumping straight to it — autocorrelation jitters a bit
  // (and occasionally snaps to the wrong octave for a frame), which made the puck too twitchy to sing against
  const rawSemi = (lastFreq > 0 && reactiveLevel > .08) ? 12 * Math.log2(lastFreq / 440) : NaN;
  if (Number.isNaN(rawSemi)) smoothSemi = NaN;
  else if (Number.isNaN(smoothSemi)) smoothSemi = rawSemi;   // new note after silence — snap, nothing to ease from
  else smoothSemi += (rawSemi - smoothSemi) * .3;
  updatePitchMeter(smoothSemi);
}
async function startReactive() {
  try {
    reactiveStream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch { return toast('Mic access denied — enable it in Settings to use this.'); }
  reactiveCtx = new (window.AudioContext || window.webkitAudioContext)();
  const src = reactiveCtx.createMediaStreamSource(reactiveStream);
  reactiveAnalyser = reactiveCtx.createAnalyser();
  reactiveAnalyser.fftSize = 2048;
  reactiveBuf = new Float32Array(reactiveAnalyser.fftSize);
  src.connect(reactiveAnalyser);
  lastFreq = -1; smoothSemi = NaN; trendBuf = [];
  $('#micBtn').classList.add('on');
  $('#pitchTrackWrap').classList.add('on');
  reactiveFrame();
}
function stopReactive() {
  reactiveAnalyser = null;
  reactiveStream?.getTracks().forEach(t => t.stop());
  reactiveCtx?.close();
  reactiveStream = reactiveCtx = null;
  reactiveHue = 14;
  document.documentElement.style.setProperty('--reactive', 0);
  document.documentElement.style.setProperty('--pitch-hue', 14);
  $('#micBtn').classList.remove('on');
  $('#pitchTrackWrap').classList.remove('on');
}
$('#micBtn').onclick = () => (reactiveStream ? stopReactive() : startReactive());
$('#syncBtn').onclick = () => {
  if (plain || !lines.length) return toast('These lyrics have no timing to sync');
  syncMode(!syncing, 'Tap a line the moment it’s sung. (Or just hold any line, anytime.)');
};
$('#more').onclick = () => { $('#lyrChoices').innerHTML = ''; sheet('#optSheet', true); };

function renderOffset() {
  $('#offV').innerHTML = `${offset > 0 ? '+' : ''}${offset.toFixed(1)}s<small>${anchors.length ? `+ ${anchors.length} fix${anchors.length > 1 ? 'es' : ''} mid-song` : offset ? (offset > 0 ? 'lyrics earlier' : 'lyrics later') : 'in sync'}</small>`;
  $('#syncBtn').textContent = offset || anchors.length ? 'SYNC ✓' : 'SYNC';
}
function loadTiming(id) {
  offset = store.get('offsets', {})[id] || 0;
  anchors = store.get('anchors', {})[id] || [];
  renderOffset();
}
function saveOffset() {
  renderOffset();
  const o = store.get('offsets', {}); o[cur.song.id] = offset; store.set('offsets', o);
  const a = store.get('anchors', {}); if (anchors.length) a[cur.song.id] = anchors; else delete a[cur.song.id]; store.set('anchors', a);
}
function nudge(d) {
  const r = x => Math.round((x + d) * 10) / 10;
  offset = r(offset); anchors = anchors.map(a => ({ v: a.v, d: r(a.d) }));
  saveOffset(); active = -2;
}
$('#resetSync').onclick = () => { offset = 0; anchors = []; saveOffset(); active = -2; toast('Timing reset'); };
let syncing = false;
function syncMode(on, msg) {
  syncing = on;
  $('#syncbar').classList.toggle('on', on);
  $('#lyr').classList.toggle('syncing', on);
  if (msg) $('#syncTxt').textContent = msg;
}
$('#syncX').onclick = () => syncMode(false);
$('#offM').onclick = () => nudge(-.2);
$('#offP').onclick = () => nudge(.2);

/* ---------- End of song ---------- */
const CHEERS = ['Mic drop.', 'Encore!', 'Nailed it.', 'Legendary.', 'Crowd goes wild.'];
function showEnd() {
  const n = names(cur.song.title, cur.song.channel);
  $('#eH').textContent = CHEERS[(Math.random() * CHEERS.length) | 0];
  $('#eP').textContent = `You just sang ${n.track}`;
  const nx = queue[qi + 1];
  $('#eNext').style.display = nx ? '' : 'none';
  if (nx) {
    $('#eNextT').textContent = `Up next: ${names(nx.title, nx.channel).track}`;
    const b = $('#eBar'); b.style.transition = 'none'; b.style.width = '0';
    requestAnimationFrame(() => { b.style.transition = 'width 8s linear'; b.style.width = '100%'; });
    endTimer = setTimeout(() => step(1), 8000);
  }
  $('#end').classList.add('on');
  const colors = ['var(--acc)', 'var(--acc2)', '#fff', '#ffd23f'];
  for (let k = 0; k < 46; k++) {
    const s = document.createElement('i'); s.className = 'spark';
    const a = Math.random() * Math.PI * 2, d = 140 + Math.random() * 260;
    s.style.cssText = `--x:${Math.cos(a) * d}px;--y:${Math.sin(a) * d + 120}px;--r:${Math.random() * 720}deg;background:${colors[k % 4]};animation-delay:${Math.random() * .15}s;${k % 3 ? '' : 'border-radius:50%'}`;
    $('#end').appendChild(s); setTimeout(() => s.remove(), 1700);
  }
}
function hideEnd() { clearTimeout(endTimer); $('#end').classList.remove('on'); }
$('#eNext').onclick = () => step(1);
$('#eAgain').onclick = () => { hideEnd(); player.seekTo(0, true); player.playVideo(); };

addEventListener('resize', () => { active = -2; });
renderAuth();
renderHome();
