const express = require('express');
const axios   = require('axios');

const app = express();
app.use(express.json());

const CONFIG = {
  clientId:     process.env.MS_CLIENT_ID,
  clientSecret: process.env.MS_CLIENT_SECRET,
  refreshToken: process.env.MS_REFRESH_TOKEN,
};
if (!CONFIG.clientId || !CONFIG.clientSecret || !CONFIG.refreshToken) {
  console.error('ERROR: Missing env vars'); process.exit(1);
}

let cachedToken         = null;
let tokenExpiresAt      = 0;
let currentRefreshToken = CONFIG.refreshToken;
let requestCount        = 0;
const startTime         = Date.now();

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
    { headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: 15000 }
  );
  cachedToken         = res.data.access_token;
  tokenExpiresAt      = Date.now() + res.data.expires_in * 1000;
  if (res.data.refresh_token) currentRefreshToken = res.data.refresh_token;
  console.log('✓ Token refreshed');
  return cachedToken;
}

// ── Routes ────────────────────────────────────────────────────────────────────
app.get('/', (_, res) => res.json({
  service:  'OTN Token Backend',
  status:   'ok',
  uptime:   Math.floor((Date.now() - startTime) / 1000) + 's',
  requests: requestCount,
}));

// Health check — used by phone keep-alive ping every 10 min
app.get('/health', (_, res) => {
  res.json({ status: 'ok', uptime: Math.floor((Date.now() - startTime) / 1000) + 's' });
});

// Token endpoint — phone calls this before every upload
app.get('/token', async (req, res) => {
  requestCount++;
  try {
    const token = await getToken();
    res.json({
      access_token: token,
      expires_in:   Math.floor((tokenExpiresAt - Date.now()) / 1000),
    });
    console.log(`[${new Date().toISOString()}] Token served (#${requestCount})`);
  } catch (err) {
    console.error('Token error:', err.response?.data || err.message);
    res.status(500).json({ error: 'Token refresh failed', detail: err.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`OTN Token Backend on port ${PORT}`);
  console.log('RAM usage: ~10MB | No file handling | Token-only mode');
});