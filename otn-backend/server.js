const express = require('express');
const multer  = require('multer');
const axios   = require('axios');
const fs      = require('fs');

const app    = express();
const upload = multer({
  dest: '/tmp/uploads/',
  limits: { fileSize: 4 * 1024 * 1024 * 1024 }, // 4GB max
});

// ── CONFIG ────────────────────────────────────────────────────────────────────
const CONFIG = {
  clientId:     process.env.MS_CLIENT_ID,
  clientSecret: process.env.MS_CLIENT_SECRET,
  refreshToken: process.env.MS_REFRESH_TOKEN,
  rootFolder:   process.env.ONEDRIVE_ROOT_FOLDER || 'OTN Recorder',
};

if (!CONFIG.clientId || !CONFIG.clientSecret || !CONFIG.refreshToken) {
  console.error('ERROR: Missing env vars');
  process.exit(1);
}

let cachedToken         = null;
let tokenExpiresAt      = 0;
let currentRefreshToken = CONFIG.refreshToken;

// ── TOKEN ─────────────────────────────────────────────────────────────────────
async function getAccessToken() {
  if (cachedToken && Date.now() < tokenExpiresAt - 60000) return cachedToken;
  const res = await axios.post(
    'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    new URLSearchParams({
      client_id:     CONFIG.clientId,
      client_secret: CONFIG.clientSecret,
      refresh_token: currentRefreshToken,
      grant_type:    'refresh_token',
      scope:         'Files.ReadWrite offline_access User.Read',
    }).toString(),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
  );
  cachedToken         = res.data.access_token;
  tokenExpiresAt      = Date.now() + res.data.expires_in * 1000;
  if (res.data.refresh_token) currentRefreshToken = res.data.refresh_token;
  console.log('✓ Token refreshed');
  return cachedToken;
}

// ── FOLDER HELPERS ────────────────────────────────────────────────────────────
async function ensureFolder(token, parentId, folderName) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  try {
    const res = await axios.get(
      `${base}/items/${parentId}/children?$filter=name eq '${encodeURIComponent(folderName)}'&$select=id,name`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (res.data.value?.length > 0) return res.data.value[0].id;
  } catch (_) {}
  const res = await axios.post(
    `${base}/items/${parentId}/children`,
    { name: folderName, folder: {}, '@microsoft.graph.conflictBehavior': 'rename' },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  return res.data.id;
}

async function getRootFolderId(token) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  try {
    const res = await axios.get(
      `${base}/root/children?$filter=name eq '${encodeURIComponent(CONFIG.rootFolder)}'&$select=id,name`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (res.data.value?.length > 0) return res.data.value[0].id;
  } catch (_) {}
  const res = await axios.post(
    `${base}/root/children`,
    { name: CONFIG.rootFolder, folder: {}, '@microsoft.graph.conflictBehavior': 'rename' },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  return res.data.id;
}

// ── STREAMING UPLOAD ──────────────────────────────────────────────────────────
// Streams file in 20MB slices — peak RAM = 20MB regardless of file size.
// Phone already merged chunks before sending, so this receives one clean file.
const CHUNK_SIZE = 20 * 1024 * 1024;

async function uploadFileStreaming(token, parentId, fileName, filePath, fileSize) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  console.log(`  Uploading: ${fileName} (${(fileSize/1024/1024).toFixed(1)}MB)`);

  const sessionRes = await axios.post(
    `${base}/items/${parentId}:/${encodeURIComponent(fileName)}:/createUploadSession`,
    { item: { '@microsoft.graph.conflictBehavior': 'replace', name: fileName } },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  const uploadUrl   = sessionRes.data.uploadUrl;
  let   offset      = 0;
  let   chunkNum    = 0;
  const totalChunks = Math.ceil(fileSize / CHUNK_SIZE);

  while (offset < fileSize) {
    const chunkEnd  = Math.min(offset + CHUNK_SIZE, fileSize);
    const chunkSize = chunkEnd - offset;
    chunkNum++;

    const chunk = await readChunk(filePath, offset, chunkSize);

    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        await axios.put(uploadUrl, chunk, {
          headers: {
            'Content-Range':  `bytes ${offset}-${chunkEnd - 1}/${fileSize}`,
            'Content-Length': chunkSize,
            'Content-Type':   'application/octet-stream',
          },
          maxBodyLength:    Infinity,
          maxContentLength: Infinity,
          timeout:          300000,
        });
        break;
      } catch (err) {
        if (attempt === 3) throw err;
        await sleep(3000 * attempt);
      }
    }

    offset = chunkEnd;
    const pct = Math.round((offset / fileSize) * 100);
    if (chunkNum % 3 === 0 || pct === 100) {
      console.log(`  ${pct}% (chunk ${chunkNum}/${totalChunks})`);
    }
  }
  console.log(`  ✓ Done: ${fileName}`);
}

function readChunk(filePath, position, length) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    const stream = fs.createReadStream(filePath, { start: position, end: position + length - 1 });
    stream.on('data', c => chunks.push(c));
    stream.on('end',  ()  => resolve(Buffer.concat(chunks)));
    stream.on('error', e  => reject(e));
  });
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ── ROUTES ────────────────────────────────────────────────────────────────────
app.get('/',       (_, res) => res.json({ service: 'OTN Upload Backend', status: 'ok' }));
app.get('/health', (_, res) => res.json({ status: 'ok', service: 'OTN Upload Backend' }));

app.post('/upload', upload.single('video'), async (req, res) => {
  const { dateFolder, userFolder, fileName } = req.body;

  if (!req.file || !dateFolder || !userFolder || !fileName) {
    return res.status(400).json({ error: 'Missing fields' });
  }

  const filePath = req.file.path;
  const fileSize = req.file.size;

  console.log(`\n→ ${dateFolder}/${userFolder}/${fileName} (${(fileSize/1024/1024).toFixed(1)}MB)`);

  try {
    const token  = await getAccessToken();
    const rootId = await getRootFolderId(token);
    const dateId = await ensureFolder(token, rootId, dateFolder);
    const userId = await ensureFolder(token, dateId, userFolder);

    await uploadFileStreaming(token, userId, fileName, filePath, fileSize);

    try { fs.unlinkSync(filePath); } catch (_) {}

    const filePath2 = `${CONFIG.rootFolder}/${dateFolder}/${userFolder}/${fileName}`;
    console.log(`✓ ${filePath2}\n`);
    res.json({ success: true, path: filePath2 });

  } catch (err) {
    try { fs.unlinkSync(filePath); } catch (_) {}
    const detail = err.response?.data || err.message;
    console.error('✗ Error:', detail);
    res.status(500).json({ error: 'Upload failed', detail: String(detail) });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`OTN Upload Backend on port ${PORT}`);
  console.log(`Mode: phone-side merge → single file upload`);
});