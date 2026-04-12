const express = require('express');
const multer = require('multer');
const axios = require('axios');
const fs = require('fs');
const FormData = require('form-data');

const app = express();
const upload = multer({ dest: '/tmp/uploads/' });

// ── CONFIG FROM ENV VARIABLES ──────────────────────────────────────────────
// Set these in Render dashboard → Environment tab (never hardcode secrets)
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

// In-memory token cache
let cachedAccessToken = null;
let tokenExpiresAt = 0;

// ── TOKEN MANAGEMENT ───────────────────────────────────────────────────────
async function getAccessToken() {
  const now = Date.now();
  if (cachedAccessToken && now < tokenExpiresAt - 60000) {
    return cachedAccessToken;
  }

  const params = new URLSearchParams({
    client_id:     CONFIG.clientId,
    client_secret: CONFIG.clientSecret,
    refresh_token: CONFIG.refreshToken,
    grant_type:    'refresh_token',
    scope:         'Files.ReadWrite offline_access User.Read',
  });

  const res = await axios.post(
    'https://login.microsoftonline.com/common/oauth2/v2.0/token',
    params.toString(),
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' } }
  );

  cachedAccessToken = res.data.access_token;
  tokenExpiresAt = now + res.data.expires_in * 1000;

  // Update refresh token if a new one is returned
  if (res.data.refresh_token) {
    CONFIG.refreshToken = res.data.refresh_token;
  }

  return cachedAccessToken;
}

// ── ONEDRIVE HELPERS ───────────────────────────────────────────────────────

// Ensure a folder exists, create if not. Returns the folder item id.
async function ensureFolder(token, parentId, folderName) {
  const graphBase = 'https://graph.microsoft.com/v1.0/me/drive';

  // Try to get existing folder
  try {
    const res = await axios.get(
      `${graphBase}/items/${parentId}/children?$filter=name eq '${encodeURIComponent(folderName)}'&$select=id,name`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (res.data.value && res.data.value.length > 0) {
      return res.data.value[0].id;
    }
  } catch (_) {}

  // Create folder
  const res = await axios.post(
    `${graphBase}/items/${parentId}/children`,
    {
      name: folderName,
      folder: {},
      '@microsoft.graph.conflictBehavior': 'rename',
    },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  return res.data.id;
}

// Get root "OTN Recorder" folder id
async function getRootFolderId(token) {
  const graphBase = 'https://graph.microsoft.com/v1.0/me/drive';
  try {
    const res = await axios.get(
      `${graphBase}/root/children?$filter=name eq '${encodeURIComponent(CONFIG.rootFolder)}'&$select=id,name`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    if (res.data.value && res.data.value.length > 0) {
      return res.data.value[0].id;
    }
  } catch (_) {}

  // Create root folder if not exists
  const res = await axios.post(
    `${graphBase}/root/children`,
    { name: CONFIG.rootFolder, folder: {}, '@microsoft.graph.conflictBehavior': 'rename' },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );
  return res.data.id;
}

// Upload file using OneDrive large file upload session (handles any size)
async function uploadFile(token, parentId, fileName, filePath, fileSize) {
  const graphBase = 'https://graph.microsoft.com/v1.0/me/drive';

  // Create upload session
  const sessionRes = await axios.post(
    `${graphBase}/items/${parentId}:/${encodeURIComponent(fileName)}:/createUploadSession`,
    { item: { '@microsoft.graph.conflictBehavior': 'replace', name: fileName } },
    { headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } }
  );

  const uploadUrl = sessionRes.data.uploadUrl;
  const chunkSize = 5 * 1024 * 1024; // 5MB chunks
  const fileStream = fs.readFileSync(filePath);
  let offset = 0;

  while (offset < fileSize) {
    const end = Math.min(offset + chunkSize - 1, fileSize - 1);
    const chunk = fileStream.slice(offset, end + 1);

    await axios.put(uploadUrl, chunk, {
      headers: {
        'Content-Range': `bytes ${offset}-${end}/${fileSize}`,
        'Content-Length': chunk.length,
      },
      maxBodyLength: Infinity,
      maxContentLength: Infinity,
    });

    offset = end + 1;
  }

  return true;
}

// ── ROUTES ─────────────────────────────────────────────────────────────────

// Health check
app.get('/health', (req, res) => res.json({ status: 'ok', service: 'OTN Upload Backend' }));

// Upload endpoint
// POST /upload
// Form fields: dateFolder (DD-MM-YYYY), userFolder (full name), fileName
// Form file:   video (the mp4 file)
app.post('/upload', upload.single('video'), async (req, res) => {
  const { dateFolder, userFolder, fileName } = req.body;

  if (!req.file || !dateFolder || !userFolder || !fileName) {
    return res.status(400).json({ error: 'Missing required fields: dateFolder, userFolder, fileName, video' });
  }

  const filePath = req.file.path;
  const fileSize = req.file.size;

  try {
    const token = await getAccessToken();

    // Build folder path: OTN Recorder / DD-MM-YYYY / UserFullName
    const rootId   = await getRootFolderId(token);
    const dateId   = await ensureFolder(token, rootId, dateFolder);
    const userId   = await ensureFolder(token, dateId, userFolder);

    // Upload the file
    await uploadFile(token, userId, fileName, filePath, fileSize);

    // Clean up temp file
    fs.unlinkSync(filePath);

    res.json({ success: true, path: `${CONFIG.rootFolder}/${dateFolder}/${userFolder}/${fileName}` });
  } catch (err) {
    // Clean up temp file on error too
    if (fs.existsSync(filePath)) fs.unlinkSync(filePath);

    const errMsg = err.response?.data || err.message;
    console.error('Upload error:', errMsg);
    res.status(500).json({ error: 'Upload failed', detail: errMsg });
  }
});

// ── START ──────────────────────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`OTN Upload Backend running on port ${PORT}`));