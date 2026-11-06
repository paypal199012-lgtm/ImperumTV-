// ImperumTV für Windows
// Zwei Fenster übereinander: unten das Video (mpv zeichnet hinein), darüber durchsichtig die Oberfläche –
// genau wie auf dem Fire TV Stick (Video unter der durchsichtigen Oberfläche). Die Oberfläche ist dieselbe wie auf Android.
'use strict';
const { app, BrowserWindow, ipcMain, powerSaveBlocker, shell, screen, net } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { execSync, spawn } = require('child_process');
const Mpv = require('./mpv');

const UPDATE_REPO = 'paypal199012-lgtm/ImperumTV-';
const UPDATE_TAG = 'windows';
const SETUP_NAME = 'ImperumTV-Setup.exe';

app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
app.commandLine.appendSwitch('disable-features', 'HardwareMediaKeyHandling');
if (!app.requestSingleInstanceLock()) { app.quit(); }

let videoWin = null, uiWin = null, mpv = null, blocker = null, quitting = false;
const SELFTEST = process.env.IMPTV_SELFTEST === '1';
function testLog(s) { try { fs.appendFileSync(path.join(os.tmpdir(), 'imptv-selftest.log'), new Date().toISOString() + ' ' + s + '\n'); } catch (e) { /* egal */ } }

function settingsFile() { return path.join(app.getPath('userData'), 'einstellungen.json'); }
function loadSettings() { try { return JSON.parse(fs.readFileSync(settingsFile(), 'utf8')) || {}; } catch (e) { return {}; } }
function saveSettings(s) { try { fs.writeFileSync(settingsFile(), JSON.stringify(s)); } catch (e) { /* egal */ } }
const settings = loadSettings();

function mpvPath() {
  if (process.env.IMPTV_MPV) return process.env.IMPTV_MPV;
  const packed = path.join(process.resourcesPath || '', 'mpv', process.platform === 'win32' ? 'mpv.exe' : 'mpv');
  if (fs.existsSync(packed)) return packed;
  const local = path.join(__dirname, 'mpv', process.platform === 'win32' ? 'mpv.exe' : 'mpv');
  return fs.existsSync(local) ? local : 'mpv';
}

/** Fester Schlüssel dieses PCs (Windows: MachineGuid) – daraus macht die Oberfläche die „MAC-Adresse“ für die Freischaltung */
function machineId() {
  if (settings.machineId) return settings.machineId;
  let id = '';
  if (process.platform === 'win32') {
    try {
      const out = execSync('reg query HKLM\\SOFTWARE\\Microsoft\\Cryptography /v MachineGuid', { windowsHide: true }).toString();
      const m = /MachineGuid\s+REG_SZ\s+([0-9a-f-]+)/i.exec(out);
      if (m) id = 'win-' + m[1].toLowerCase();
    } catch (e) { id = ''; }
  }
  if (!id) id = 'pc-' + require('crypto').randomBytes(12).toString('hex');
  settings.machineId = id; saveSettings(settings);
  return id;
}

function windowsName() {
  if (process.platform !== 'win32') return os.type() + ' ' + os.release();
  const build = parseInt(String(os.release()).split('.')[2] || '0', 10);
  return 'Windows ' + (build >= 22000 ? '11' : '10');
}

function versionNumber() { const m = /(\d+)\s*$/.exec(app.getVersion()); return m ? parseInt(m[1], 10) : 0; }

function hwndOf(win) {
  const b = win.getNativeWindowHandle();
  if (process.platform === 'win32') return b.length >= 8 ? b.readBigUInt64LE(0).toString() : String(b.readUInt32LE(0));
  return String(b.readUInt32LE(0));             // Linux/X11 (nur zum Testen)
}

function toUi(fn, ...args) { if (uiWin && !uiWin.isDestroyed()) uiWin.webContents.send('js', fn, args); }

function createWindows() {
  const d = screen.getPrimaryDisplay();
  const icon = path.join(__dirname, 'icon.ico');
  videoWin = new BrowserWindow({
    x: d.bounds.x, y: d.bounds.y, width: d.bounds.width, height: d.bounds.height,
    frame: false, backgroundColor: '#000000', show: false, fullscreen: settings.windowed !== true, title: 'ImperumTV',
    icon: fs.existsSync(icon) ? icon : undefined, webPreferences: { sandbox: true }
  });
  videoWin.setMenu(null);
  videoWin.loadURL('data:text/html,<body style="background:#000;margin:0"></body>');

  uiWin = new BrowserWindow({
    parent: videoWin, frame: false, transparent: true, backgroundColor: '#00000000', show: false, skipTaskbar: true,
    resizable: false, movable: false, minimizable: false, maximizable: false, hasShadow: false, title: 'ImperumTV',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'), contextIsolation: false, nodeIntegration: false, sandbox: false,
      webSecurity: false, backgroundThrottling: false, spellcheck: false
    }
  });
  uiWin.setMenu(null);
  const sync = () => { if (uiWin && !uiWin.isDestroyed() && videoWin && !videoWin.isDestroyed()) uiWin.setBounds(videoWin.getContentBounds()); };
  ['resize', 'move', 'enter-full-screen', 'leave-full-screen', 'maximize', 'unmaximize', 'restore'].forEach((e) => videoWin.on(e, () => { sync(); setTimeout(sync, 200); }));
  videoWin.on('focus', () => { if (uiWin && !uiWin.isDestroyed()) uiWin.focus(); });
  videoWin.on('closed', () => { videoWin = null; if (!quitting) app.quit(); });
  uiWin.on('closed', () => { uiWin = null; if (!quitting) app.quit(); });

  // F11: Vollbild an/aus · Alt+F4 beendet
  uiWin.webContents.on('before-input-event', (ev, input) => {
    if (input.type === 'keyDown' && input.key === 'F11') {
      ev.preventDefault();
      const full = !videoWin.isFullScreen();
      settings.windowed = !full; saveSettings(settings);
      videoWin.setFullScreen(full);
      if (!full) { const wa = screen.getDisplayMatching(videoWin.getBounds()).workArea; videoWin.setBounds(wa); }
    }
  });
  // Links aus der Oberfläche (z. B. Website) im normalen Browser öffnen
  uiWin.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/i.test(url)) shell.openExternal(url); return { action: 'deny' }; });

  // Selbsttest (nur beim Bauen bei GitHub): Testvideo unter durchsichtiger Seite, dann die echte Oberfläche
  if (SELFTEST) {
    uiWin.webContents.on('console-message', (e, level, msg) => testLog('UI: ' + msg));
    uiWin.loadFile(path.join(__dirname, 'selftest.html'));
  } else uiWin.loadFile(path.join(__dirname, 'www', 'index.html'));
  videoWin.once('ready-to-show', () => {
    videoWin.show();
    if (settings.windowed) videoWin.setBounds(screen.getPrimaryDisplay().workArea);
    sync(); uiWin.show(); uiWin.focus();
    mpv = new Mpv(mpvPath(), hwndOf(videoWin), { buffer: settings.buffer || 'normal', userAgent: 'ImperumTV/1.0 (Windows)' });
    mpv.on('ev', (name, a) => {
      if (SELFTEST && name !== 'time') testLog('mpv: ' + name + (a !== undefined && a !== null ? ' ' + a : ''));
      if (uiWin && !uiWin.isDestroyed()) uiWin.webContents.send('ev', name, a);
    });
    mpv.on('state', (s) => { if (uiWin && !uiWin.isDestroyed()) uiWin.webContents.send('state', s); });
  });
}

// ---------- Befehle der Oberfläche ----------

ipcMain.on('info', (e) => {
  const d = screen.getPrimaryDisplay();
  e.returnValue = {
    version: versionNumber(), versionText: app.getVersion(), device: 'Windows-PC · ' + windowsName(), id: machineId(),
    maxH: Math.round(Math.max(d.size.height, d.size.width * 9 / 16) * (d.scaleFactor || 1)),
    memMb: Math.round(os.totalmem() / 1048576), buffer: settings.buffer || 'normal'
  };
});

ipcMain.on('ab', (e, m, a) => {
  a = a || [];
  switch (m) {
    case 'open': if (mpv) { mpv.setRect([a[1], a[2], a[3], a[4]]); mpv.load(a[0]); } break;
    case 'setRect': if (mpv) mpv.setRect([a[0], a[1], a[2], a[3]]); break;
    case 'stop': if (mpv) mpv.stop(); break;
    case 'toggle': if (mpv) mpv.toggle(); break;
    case 'setResize': if (mpv) mpv.setResize(a[0]); break;
    case 'seekTo': if (mpv) mpv.seekTo(a[0]); break;
    case 'seekBy': if (mpv) mpv.seekBy(a[0]); break;
    case 'selectTrack': if (mpv) mpv.selectTrack(a[0], a[1]); break;
    case 'setAudioLangs': if (mpv) mpv.setAudioLangs(a[0]); break;
    case 'setBuffer': settings.buffer = a[0]; saveSettings(settings); if (mpv) mpv.setBuffer(a[0]); break;
    case 'keepAwake':
      if (a[0] && blocker === null) blocker = powerSaveBlocker.start('prevent-display-sleep');
      else if (!a[0] && blocker !== null) { try { powerSaveBlocker.stop(blocker); } catch (x) { /* egal */ } blocker = null; }
      break;
    case 'openUrl': if (/^https?:/i.test(a[0] || '')) shell.openExternal(a[0]); break;
    case 'exit': app.quit(); break;
    case 'checkLatest': checkLatest(); break;
    case 'downloadUpdate': downloadUpdate(); break;
  }
});

/** Stick-Zustand für die Admin-Seite (Speicher, Arbeitsspeicher, Tempo, Laufzeit) */
ipcMain.on('health', (e) => {
  const o = { ramFree: Math.round(os.freemem() / 1048576), ramTotal: Math.round(os.totalmem() / 1048576), up: Math.round(os.uptime()), net: 'pc' };
  try { const s = fs.statfsSync(app.getPath('userData')); o.stFree = Math.round(s.bavail * s.bsize / 1048576); o.stTotal = Math.round(s.blocks * s.bsize / 1048576); } catch (x) { /* egal */ }
  o.kbps = mpv ? mpv.st.kbps : 0;
  e.returnValue = JSON.stringify(o);
});

// ---------- Updates: Release „windows“ bei GitHub, Datei ImperumTV-Setup.exe ----------

async function latestRelease() {
  const r = await net.fetch('https://api.github.com/repos/' + UPDATE_REPO + '/releases/tags/' + UPDATE_TAG, { headers: { 'User-Agent': 'ImperumTV-Update', Accept: 'application/vnd.github+json' } });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  const rel = await r.json();
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(rel.name || '') || /(\d+)\s*$/.exec(rel.body || '');
  const n = m ? parseInt(m[m.length - 1], 10) : 0;
  const asset = (rel.assets || []).find((x) => x.name === SETUP_NAME);
  return { n, asset };
}

async function checkLatest() {
  let tag = '', err = '';
  try { const { n } = await latestRelease(); if (n) tag = 'win-' + n; else err = 'keine Version gefunden'; }
  catch (e) { err = e.message; }
  toUi('__androidLatest', { tag, error: err });
}

async function downloadUpdate() {
  try {
    const { asset } = await latestRelease();
    if (!asset) throw new Error('Datei fehlt');
    const r = await net.fetch(asset.browser_download_url, { headers: { 'User-Agent': 'ImperumTV-Update' } });
    if (!r.ok || !r.body) throw new Error('HTTP ' + r.status);
    const total = Number(r.headers.get('content-length')) || asset.size || 0;
    const file = path.join(app.getPath('temp'), 'ImperumTV-Setup-' + Date.now() + '.exe');
    const out = fs.createWriteStream(file);
    const reader = r.body.getReader();
    let got = 0, lastPct = -1;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      out.write(Buffer.from(value)); got += value.length;
      const pct = total ? Math.floor(got * 100 / total) : 0;
      if (pct !== lastPct) { lastPct = pct; toUi('__androidUpdate', 'progress', pct); }
    }
    await new Promise((res) => out.end(res));
    toUi('__androidUpdate', 'installing');
    // Installer starten (fragt kurz nach), App beenden, damit die Dateien ersetzt werden können
    spawn(file, ['--updated'], { detached: true, stdio: 'ignore' }).unref();
    setTimeout(() => app.quit(), 1500);
  } catch (e) {
    toUi('__androidUpdate', 'error', 0, e.message);
  }
}

app.on('second-instance', () => { if (videoWin) { if (videoWin.isMinimized()) videoWin.restore(); videoWin.focus(); } });
app.whenReady().then(createWindows);
app.on('before-quit', () => { quitting = true; if (mpv) mpv.quit(); });
app.on('window-all-closed', () => app.quit());
