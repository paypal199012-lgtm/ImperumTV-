// Brücke zwischen der Oberfläche (dieselbe wie auf Android) und dem Windows-Teil.
// Die Oberfläche spricht mit „window.AndroidBridge“ – hier steht dieselbe Schnittstelle, nur mit mpv dahinter.
'use strict';
const { ipcRenderer } = require('electron');

const info = ipcRenderer.sendSync('info') || {};
const S = { playing: false, pos: 0, dur: 0, kbps: 0, behind: 0, audio: '[]', text: '[]', buffer: info.buffer || 'normal' };

function post(m, a) { ipcRenderer.send('ab', m, a || []); }
function P(m) { return function () { post(m, Array.prototype.slice.call(arguments)); }; }
function list(kind) { try { return JSON.parse(kind === 'text' ? S.text : S.audio) || []; } catch (e) { return []; } }

ipcRenderer.on('state', (e, s) => { Object.assign(S, s); });
ipcRenderer.on('ev', (e, name, a) => {
  if (name === 'ready' || name === 'buffer') S.playing = true;
  if (name === 'end' || name === 'error') S.playing = false;
  if (window.__androidPlayerEvent) window.__androidPlayerEvent(name, a);
});
ipcRenderer.on('js', (e, fn, args) => { if (typeof window[fn] === 'function') window[fn].apply(window, args || []); });

window.AndroidBridge = {
  // Player
  open: function (u, x, y, w, h) { S.playing = true; S.pos = 0; S.dur = 0; S.audio = '[]'; S.text = '[]'; S.behind = 0; post('open', [u, x, y, w, h]); },
  setRect: P('setRect'),
  stop: function () { S.playing = false; post('stop'); },
  toggle: function () { S.playing = !S.playing; post('toggle'); },
  isPlaying: function () { return !!S.playing; },
  position: function () { return S.pos || 0; },
  duration: function () { return S.dur || 0; },
  setResize: P('setResize'), seekTo: P('seekTo'), seekBy: P('seekBy'),
  tracks: function (kind) { return kind === 'text' ? S.text : S.audio; },
  selectTrack: function (kind, i) { post('selectTrack', [kind, i]); return true; },
  nextAudio: function () {
    var l = list('audio'), cur = 0, i;
    if (!l.length) return '';
    if (l.length === 1) return '=' + l[0].name;
    for (i = 0; i < l.length; i++) if (l[i].selected) cur = i;
    var n = (cur + 1) % l.length; post('selectTrack', ['audio', n]); return l[n].name;
  },
  nextSubtitle: function () {
    var l = list('text'), cur = -1, i;
    if (!l.length) return '';
    for (i = 0; i < l.length; i++) if (l[i].selected) cur = i;
    var n = cur + 1;
    if (n >= l.length) { post('selectTrack', ['text', -1]); return 'Aus'; }
    post('selectTrack', ['text', n]); return l[n].name;
  },
  setAudioLangs: P('setAudioLangs'),
  applyPrefs: function () {},
  maxVideoHeight: function () { return info.maxH || 1080; },
  liveBehindMs: function () { return S.behind || 0; },
  liveCatchUp: function () { return false; },          // Oberfläche verbindet den Sender neu (beginnt beim aktuellen Bild)
  netInfo: function () { return '{"kbps":' + (S.kbps || 0) + '}'; },
  getBuffer: function () { return S.buffer; },
  setBuffer: function (m) { S.buffer = m === 'small' || m === 'large' ? m : 'normal'; post('setBuffer', [S.buffer]); },
  keepAwake: P('keepAwake'),

  // Gerät
  appVersion: function () { return info.version || 0; },
  deviceName: function () { return info.device || 'Windows-PC'; },
  deviceId: function () { return info.id || ''; },
  totalMemMb: function () { return info.memMb || 0; },
  health: function () { try { return ipcRenderer.sendSync('health') || '{}'; } catch (e) { return '{}'; } },
  showKeyboard: function () {},                          // PC: echte Tastatur
  openUrl: P('openUrl'),
  openYoutube: function (id) { post('openUrl', ['https://www.youtube.com/watch?v=' + encodeURIComponent(id)]); return true; },
  exit: P('exit'),

  // Updates (Release „windows“ bei GitHub)
  checkLatest: function () { post('checkLatest'); },
  downloadUpdate: function () { post('downloadUpdate'); }
};

// PC: Maus und Tastatur – Hinweis für die Oberfläche
window.__imptvWindows = true;

// PC-Bedienung: Mausrad = Pfeil hoch/runter, rechte Maustaste = Zurück (wie die Fernbedienung)
function key(code, name) {
  var ev = new KeyboardEvent('keydown', { key: name, bubbles: true, cancelable: true });
  Object.defineProperty(ev, 'keyCode', { get: function () { return code; } });
  Object.defineProperty(ev, 'which', { get: function () { return code; } });
  document.dispatchEvent(ev);
}
var wheelAt = 0;
window.addEventListener('wheel', function (e) {
  var now = Date.now();
  if (now - wheelAt < 90 || Math.abs(e.deltaY) < 4) return;
  wheelAt = now;
  if (e.shiftKey || Math.abs(e.deltaX) > Math.abs(e.deltaY)) key((e.deltaX || e.deltaY) > 0 ? 39 : 37, (e.deltaX || e.deltaY) > 0 ? 'ArrowRight' : 'ArrowLeft');
  else key(e.deltaY > 0 ? 40 : 38, e.deltaY > 0 ? 'ArrowDown' : 'ArrowUp');
}, { passive: true });
window.addEventListener('contextmenu', function (e) { e.preventDefault(); key(27, 'Escape'); });
