const express = require('express');
const axios   = require('axios');

const app = express();
app.use(express.json());

// ── CONFIG ────────────────────────────────────────────────────────────────────
const CONFIG = {
  clientId:     process.env.MS_CLIENT_ID,
  clientSecret: process.env.MS_CLIENT_SECRET,
  refreshToken: process.env.MS_REFRESH_TOKEN,
};
if (!CONFIG.clientId || !CONFIG.clientSecret || !CONFIG.refreshToken) {
  console.error('ERROR: Missing env vars MS_CLIENT_ID / MS_CLIENT_SECRET / MS_REFRESH_TOKEN');
  process.exit(1);
}

let cachedToken         = null;
let tokenExpiresAt      = 0;
let currentRefreshToken = CONFIG.refreshToken;

// ── TOKEN REFRESH ─────────────────────────────────────────────────────────────
async function getToken() {
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

// ── ROUTES ────────────────────────────────────────────────────────────────────
app.get('/',       (_, res) => res.json({ service: 'OTN Token Backend', status: 'ok' }));
app.get('/health', (_, res) => res.json({ status: 'ok' }));

// GET /token — phone calls this to get a fresh OneDrive access token.
// Returns the token so the phone can upload directly to OneDrive.
// No file data passes through this server at all.
app.get('/token', async (req, res) => {
  try {
    const token = await getToken();
    res.json({
      access_token: token,
      expires_in:   Math.floor((tokenExpiresAt - Date.now()) / 1000),
    });
    console.log('Token served to phone');
  } catch (err) {
    console.error('Token error:', err.response?.data || err.message);
    res.status(500).json({ error: 'Failed to get token', detail: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`OTN Token Backend on port ${PORT}`);
  console.log('Mode: token-only — files upload directly phone → OneDrive');
  console.log('RAM usage: ~10MB (no file handling)');
});