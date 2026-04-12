const express = require('express');
const multer  = require('multer');
const axios   = require('axios');
const fs      = require('fs');

const app    = express();
const upload = multer({ dest: '/tmp/uploads/' });

// ── CONFIG FROM ENV VARIABLES ──────────────────────────────────────────────
const CONFIG = {
  clientId:     process.env.MS_CLIENT_ID,
  clientSecret: process.env.MS_CLIENT_SECRET,
  refreshToken: process.env.MS_REFRESH_TOKEN,
  rootFolder:   process.env.ONEDRIVE_ROOT_FOLDER || 'OTN Recorder',
};

if (!CONFIG.clientId || !CONFIG.clientSecret || !CONFIG.refreshToken) {
  console.error('ERROR: Missing MS_CLIENT_ID, MS_CLIENT_SECRET or MS_REFRESH_TOKEN env vars');
  process.exit(1);
}

let cachedAccessToken   = null;
let tokenExpiresAt      = 0;
let currentRefreshToken = CONFIG.refreshToken;

// ── TOKEN MANAGEMENT ──────────────────────────────────────────────────────
async function getAccessToken() {
  const now = Date.now();
  if (cachedAccessToken && now < tokenExpiresAt - 60000) return cachedAccessToken;

  const params = new URLSearchParams({
    client_id:     CONFIG.clientId,
    client_secret: CONFIG.clientSecret,
    refresh_token: currentRefreshToken,
    grant_type:    'refresh_token',
    scope:         'Files.ReadWrite offline_access User.Read',
  });

  const res = await axios.post(
    'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    params.toString(),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
  );

  cachedAccessToken = res.data.access_token;
  tokenExpiresAt    = now + res.data.expires_in * 1000;
  if (res.data.refresh_token) currentRefreshToken = res.data.refresh_token;
  console.log('✓ Token refreshed');
  return cachedAccessToken;
}

// ── ONEDRIVE HELPERS ──────────────────────────────────────────────────────
async function ensureFolder(token, parentId, folderName) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';
  try {
    const res = await axios.get(
      `${base}/items/${parentId}/children?$filter=name eq '${encodeURIComponent(folderName)}'&$select=id,name`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (res.data.value && res.data.value.length > 0) {
      console.log(`✓ Folder exists: ${folderName}`);
      return res.data.value[0].id;
    }
  } catch (e) {
    console.log(`  Folder check failed for ${folderName}: ${e.message}`);
  }

  console.log(`  Creating folder: ${folderName}`);
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
    if (res.data.value && res.data.value.length > 0) return res.data.value[0].id;
  } catch (_) {}

  const res = await axios.post(
    `${base}/root/children`,
    { name: CONFIG.rootFolder, folder: {}, '@microsoft.graph.conflictBehavior': 'rename' },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  return res.data.id;
}

async function uploadFile(token, parentId, fileName, filePath, fileSize) {
  const base = 'https://graph.microsoft.com/v1.0/me/drive';

  // Create upload session
  console.log(`  Creating upload session for: ${fileName} (${(fileSize/1024/1024).toFixed(1)}MB)`);
  const sessionRes = await axios.post(
    `${base}/items/${parentId}:/${encodeURIComponent(fileName)}:/createUploadSession`,
    { item: { '@microsoft.graph.conflictBehavior': 'replace', name: fileName } },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );

  const uploadUrl  = sessionRes.data.uploadUrl;
  const chunkSize  = 10 * 1024 * 1024; // 10MB chunks (larger = fewer requests)
  const fileBuffer = fs.readFileSync(filePath);
  let offset = 0;
  let chunkNum = 0;

  while (offset < fileSize) {
    const end   = Math.min(offset + chunkSize - 1, fileSize - 1);
    const chunk = fileBuffer.slice(offset, end + 1);
    chunkNum++;

    console.log(`  Chunk ${chunkNum}: bytes ${offset}-${end}/${fileSize}`);

    // Retry logic for each chunk
    let attempts = 0;
    while (attempts < 3) {
      try {
        await axios.put(uploadUrl, chunk, {
          headers: {
            'Content-Range':  `bytes ${offset}-${end}/${fileSize}`,
            'Content-Length': chunk.length,
          },
          maxBodyLength:    Infinity,
          maxContentLength: Infinity,
          timeout:          120000, // 2 min per chunk
        });
        break; // success
      } catch (e) {
        attempts++;
        console.log(`  Chunk ${chunkNum} attempt ${attempts} failed: ${e.message}`);
        if (attempts >= 3) throw e;
        await new Promise(r => setTimeout(r, 2000 * attempts)); // backoff
      }
    }

    offset = end + 1;
  }

  console.log(`✓ Upload complete: ${fileName}`);
  return true;
}

// ── ROUTES ─────────────────────────────────────────────────────────────────
app.get('/',       (_req, res) => res.json({ service: 'OTN Upload Backend', status: 'ok' }));
app.get('/health', (_req, res) => res.json({ status: 'ok', service: 'OTN Upload Backend' }));

app.post('/upload', upload.single('video'), async (req, res) => {
  const { dateFolder, userFolder, fileName } = req.body;

  if (!req.file || !dateFolder || !userFolder || !fileName) {
    return res.status(400).json({
      error: 'Missing fields',
      received: { dateFolder, userFolder, fileName, hasFile: !!req.file }
    });
  }

  const filePath = req.file.path;
  const fileSize = req.file.size;
  console.log(`\n→ Upload: ${dateFolder}/${userFolder}/${fileName} (${(fileSize/1024/1024).toFixed(1)}MB)`);

  try {
    const token  = await getAccessToken();
    const rootId = await getRootFolderId(token);
    const dateId = await ensureFolder(token, rootId, dateFolder);
    const userId = await ensureFolder(token, dateId, userFolder);

    await uploadFile(token, userId, fileName, filePath, fileSize);

    // Clean up temp file
    try { fs.unlinkSync(filePath); } catch (_) {}

    const path = `${CONFIG.rootFolder}/${dateFolder}/${userFolder}/${fileName}`;
    console.log(`✓ Success: ${path}`);
    res.json({ success: true, path });

  } catch (err) {
    try { fs.unlinkSync(filePath); } catch (_) {}
    const detail = err.response?.data || err.message;
    console.error('✗ Upload error:', detail);
    res.status(500).json({ error: 'Upload failed', detail: String(detail) });
  }
});

// ── START ──────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`OTN Upload Backend running on port ${PORT}`));