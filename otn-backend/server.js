const express  = require('express');
const multer   = require('multer');
const axios    = require('axios');
const fs       = require('fs');
const path     = require('path');
const { spawn } = require('child_process');

const app    = express();
const upload = multer({ dest: '/tmp/uploads/', limits: { fileSize: 4 * 1024 * 1024 * 1024 } });

const CONFIG = {
  clientId:     process.env.MS_CLIENT_ID,
  clientSecret: process.env.MS_CLIENT_SECRET,
  refreshToken: process.env.MS_REFRESH_TOKEN,
  rootFolder:   process.env.ONEDRIVE_ROOT_FOLDER || 'OTN Recorder',
};
if (!CONFIG.clientId || !CONFIG.clientSecret || !CONFIG.refreshToken) {
  console.error('ERROR: Missing env vars'); process.exit(1);
}

// session tracker: key=sessionName → {dateFolder,userFolder,totalChunks,chunks:[]}
const sessions = new Map();
let cachedToken = null, tokenExpiresAt = 0, currentRefreshToken = CONFIG.refreshToken;

async function getToken() {
  if (cachedToken && Date.now() < tokenExpiresAt - 60000) return cachedToken;
  const res = await axios.post(
    'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    new URLSearchParams({ client_id: CONFIG.clientId, client_secret: CONFIG.clientSecret,
      refresh_token: currentRefreshToken, grant_type: 'refresh_token',
      scope: 'Files.ReadWrite offline_access User.Read' }).toString(),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } });
  cachedToken = res.data.access_token;
  tokenExpiresAt = Date.now() + res.data.expires_in * 1000;
  if (res.data.refresh_token) currentRefreshToken = res.data.refresh_token;
  return cachedToken;
}

async function ensureFolder(token, parentId, name) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  try {
    const r = await axios.get(`${base}/items/${parentId}/children?$filter=name eq '${encodeURIComponent(name)}'&$select=id`,
      { headers: { Authorization: `Bearer ${token}` } });
    if (r.data.value?.length > 0) return r.data.value[0].id;
  } catch (_) {}
  const r = await axios.post(`${base}/items/${parentId}/children`,
    { name, folder: {}, '@microsoft.graph.conflictBehavior': 'rename' },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } });
  return r.data.id;
}

async function getRootId(token) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  try {
    const r = await axios.get(`${base}/root/children?$filter=name eq '${encodeURIComponent(CONFIG.rootFolder)}'&$select=id`,
      { headers: { Authorization: `Bearer ${token}` } });
    if (r.data.value?.length > 0) return r.data.value[0].id;
  } catch (_) {}
  const r = await axios.post(`${base}/root/children`,
    { name: CONFIG.rootFolder, folder: {}, '@microsoft.graph.conflictBehavior': 'rename' },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } });
  return r.data.id;
}

const CHUNK = 20 * 1024 * 1024;
async function uploadStream(token, parentId, fileName, filePath, fileSize) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  const sess = await axios.post(`${base}/items/${parentId}:/${encodeURIComponent(fileName)}:/createUploadSession`,
    { item: { '@microsoft.graph.conflictBehavior': 'replace', name: fileName } },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } });
  const url = sess.data.uploadUrl;
  let offset = 0;
  while (offset < fileSize) {
    const end = Math.min(offset + CHUNK, fileSize);
    const buf = await readChunk(filePath, offset, end - offset);
    for (let a = 1; a <= 3; a++) {
      try {
        await axios.put(url, buf, { headers: {
          'Content-Range': `bytes ${offset}-${end-1}/${fileSize}`,
          'Content-Length': end - offset, 'Content-Type': 'application/octet-stream'
        }, maxBodyLength: Infinity, maxContentLength: Infinity, timeout: 300000 });
        break;
      } catch (e) { if (a === 3) throw e; await sleep(3000 * a); }
    }
    offset = end;
    const pct = Math.round(offset / fileSize * 100);
    if (pct % 20 === 0) console.log(`  ${pct}%`);
  }
}

function readChunk(filePath, pos, len) {
  return new Promise((res, rej) => {
    const chunks = [];
    fs.createReadStream(filePath, { start: pos, end: pos + len - 1 })
      .on('data', c => chunks.push(c)).on('end', () => res(Buffer.concat(chunks))).on('error', rej);
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// FFmpeg merge — lossless concat
function mergeChunks(paths, output) {
  return new Promise((res, rej) => {
    const list = output + '.txt';
    fs.writeFileSync(list, paths.map(p => `file '${p}'`).join('\n'));
    const proc = spawn('ffmpeg', ['-f','concat','-safe','0','-i',list,'-c','copy','-movflags','+faststart','-y',output]);
    let err = '';
    proc.stderr.on('data', d => err += d);
    proc.on('close', code => {
      try { fs.unlinkSync(list); } catch (_) {}
      code === 0 ? res() : rej(new Error(`FFmpeg failed: ${err.slice(-300)}`));
    });
    proc.on('error', e => rej(new Error(`FFmpeg not found: ${e.message}`)));
  });
}

async function processSession(key, s) {
  s.chunks.sort((a, b) => a.index - b.index);
  const mergedPath = `/tmp/merged_${Date.now()}_${s.sessionName}.mp4`;
  const chunkPaths = s.chunks.map(c => c.path);
  console.log(`\n▶ Merging ${s.chunks.length} chunks → ${s.sessionName}.mp4`);
  try {
    if (s.chunks.length > 1) {
      await mergeChunks(chunkPaths, mergedPath);
    } else {
      fs.copyFileSync(chunkPaths[0], mergedPath);
    }
    const size = fs.statSync(mergedPath).size;
    console.log(`  Merged: ${(size/1024/1024).toFixed(1)}MB`);

    const token  = await getToken();
    const rootId = await getRootId(token);
    const dateId = await ensureFolder(token, rootId, s.dateFolder);
    const userId = await ensureFolder(token, dateId, s.userFolder);

    // Upload as clean session name (no chunk suffix)
    const finalName = `${s.sessionName}.mp4`;
    await uploadStream(token, userId, finalName, mergedPath, size);
    console.log(`✓ ${CONFIG.rootFolder}/${s.dateFolder}/${s.userFolder}/${finalName}`);

    for (const p of chunkPaths) try { fs.unlinkSync(p); } catch (_) {}
    try { fs.unlinkSync(mergedPath); } catch (_) {}
    sessions.delete(key);
  } catch (e) {
    console.error('✗ processSession error:', e.message);
    for (const p of chunkPaths) try { fs.unlinkSync(p); } catch (_) {}
    try { if (fs.existsSync(mergedPath)) fs.unlinkSync(mergedPath); } catch (_) {}
    sessions.delete(key);
  }
}

// ── Routes ────────────────────────────────────────────────────────────────────
app.get('/',       (_, r) => r.json({ service: 'OTN Upload Backend', status: 'ok' }));
app.get('/health', (_, r) => r.json({ status: 'ok' }));

app.post('/upload', upload.single('video'), async (req, res) => {
  const { dateFolder, userFolder, fileName, sessionName, totalChunks, chunkIndex } = req.body;
  if (!req.file || !dateFolder || !userFolder || !fileName) {
    return res.status(400).json({ error: 'Missing fields' });
  }

  const total = parseInt(totalChunks, 10) || 1;
  const index = parseInt(chunkIndex, 10)  || 1;
  const sName = sessionName || fileName.replace(/\.mp4$/, '');
  const key   = `${dateFolder}/${userFolder}/${sName}`;

  console.log(`→ chunk ${index}/${total}: ${fileName} (${(req.file.size/1024/1024).toFixed(1)}MB)`);

  // Respond immediately
  res.json({ success: true, received: index, total, pending: index < total });

  // Register chunk
  if (!sessions.has(key)) {
    sessions.set(key, { dateFolder, userFolder, sessionName: sName, total, chunks: [] });
  }
  sessions.get(key).chunks.push({ index, path: req.file.path });

  // When all chunks received — merge and upload
  if (sessions.get(key).chunks.length >= total) {
    setImmediate(() => processSession(key, sessions.get(key)));
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`OTN Backend on port ${PORT} | chunk→merge→OneDrive mode`));