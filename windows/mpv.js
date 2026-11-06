// ImperumTV für Windows: mpv als Player unter der Oberfläche, gesteuert über seine JSON-Schnittstelle (Named Pipe).
// Meldet dieselben Ereignisse wie der Android-Player (buffer, ready, frame, time, end, error), damit die Oberfläche gleich bleibt.
'use strict';
const { spawn } = require('child_process');
const net = require('net');
const EventEmitter = require('events');

const LANG = {
  de: 'Deutsch', deu: 'Deutsch', ger: 'Deutsch', en: 'Englisch', eng: 'Englisch', tr: 'Türkisch', tur: 'Türkisch',
  fr: 'Französisch', fra: 'Französisch', fre: 'Französisch', es: 'Spanisch', spa: 'Spanisch', it: 'Italienisch', ita: 'Italienisch',
  ar: 'Arabisch', ara: 'Arabisch', ru: 'Russisch', rus: 'Russisch', pl: 'Polnisch', pol: 'Polnisch', nl: 'Niederländisch', nld: 'Niederländisch',
  pt: 'Portugiesisch', por: 'Portugiesisch', sq: 'Albanisch', alb: 'Albanisch', sqi: 'Albanisch', sr: 'Serbisch', srp: 'Serbisch',
  hr: 'Kroatisch', hrv: 'Kroatisch', bs: 'Bosnisch', bos: 'Bosnisch', el: 'Griechisch', gre: 'Griechisch', ell: 'Griechisch'
};

class Mpv extends EventEmitter {
  constructor(bin, wid, opts) {
    super();
    this.bin = bin;
    this.wid = wid;
    this.opts = opts || {};
    this.pipe = process.platform === 'win32' ? '\\\\.\\pipe\\imperumtv-mpv-' + process.pid : '/tmp/imperumtv-mpv-' + process.pid + '.sock';
    this.reqId = 1;
    this.quitting = false;
    this.reset();
    this.st = { pause: false, idle: true, pos: 0, dur: 0, tracks: [], vparams: null, kbps: 0 };
    this.rect = [0, 0, 1, 1];
    this.start();
    this.timer = setInterval(() => this.tick(), 500);
  }

  reset() {
    this.loaded = false; this.readySent = false; this.frameSent = false; this.buffering = false;
    this.behindWall = 0; this.behindPos = 0; this.behind = 0;
  }

  // ---------- Prozess und Verbindung ----------

  start() {
    const args = [
      '--idle=yes', '--force-window=yes', '--wid=' + this.wid, '--input-ipc-server=' + this.pipe,
      '--config=no', '--load-scripts=no', '--ytdl=no', '--osc=no', '--osd-level=0', '--no-osd-bar',
      '--input-default-bindings=no', '--input-vo-keyboard=no', '--input-cursor=no', '--cursor-autohide=always',
      '--keep-open=no', '--background-color=#000000',
      '--cache=yes', '--cache-pause-initial=no', '--demuxer-max-bytes=200MiB', '--demuxer-max-back-bytes=50MiB',
      '--network-timeout=20', '--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
      '--user-agent=' + (this.opts.userAgent || 'ImperumTV/1.0 (Windows)'),
      '--alang=de,ger,deu,en,eng', '--slang=de,ger,deu', '--sid=no', '--msg-level=all=warn', '--terminal=no'
    ];
    // Bildausgabe (Einstellungen → Bildausgabe): nicht jede Grafikkarte zeigt mit jedem Verfahren ein Bild unter der Oberfläche
    args.push.apply(args, Mpv.VIDEO_OUT[this.opts.videoOut] || Mpv.VIDEO_OUT.auto);
    // Protokoll für die Fehlersuche (wird bei jedem Start neu geschrieben)
    if (this.opts.logFile) args.push('--log-file=' + this.opts.logFile);
    this.proc = spawn(this.bin, args, { stdio: 'ignore', windowsHide: true });
    this.proc.on('error', (e) => { this.emit('ev', 'error', 'Player (mpv) fehlt: ' + e.message); });
    this.proc.on('exit', () => {
      this.sock = null;
      if (this.quitting) return;
      if (this.restarting) { this.restarting = false; this.reset(); setTimeout(() => this.start(), 200); return; }
      // Player abgestürzt: neu starten (die Oberfläche bekommt einen Fehler und schaltet ggf. um)
      if (this.loaded) this.emit('ev', 'error', 'Player wurde neu gestartet');
      this.reset();
      setTimeout(() => { if (!this.quitting) this.start(); }, 800);
    });
    this.connect(0);
  }

  /** Mit anderen Einstellungen neu starten (z. B. andere Bildausgabe); der laufende Sender wird neu geladen */
  restart(opts) {
    Object.assign(this.opts, opts || {});
    const url = this.loaded || this.pending ? (this.lastUrl || this.pending) : null;
    this.pending = url;
    this.restarting = true;
    try { this.send(['quit']); } catch (e) { /* egal */ }
    const p = this.proc;
    setTimeout(() => { try { p.kill(); } catch (e) { /* egal */ } }, 600);
  }

  connect(tries) {
    const s = net.connect(this.pipe);
    let buf = '';
    s.on('connect', () => {
      this.sock = s;
      ['pause', 'idle-active', 'time-pos', 'duration', 'paused-for-cache', 'track-list', 'video-params', 'demuxer-cache-state', 'seeking']
        .forEach((p, i) => this.send(['observe_property', i + 1, p]));
      this.applySettings();
      if (this.pending) { const p = this.pending; this.pending = null; this.load(p); }
    });
    s.on('data', (d) => {
      buf += d.toString('utf8');
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        if (!line.trim()) continue;
        try { this.onMsg(JSON.parse(line)); } catch (e) { /* unvollständige Zeile */ }
      }
    });
    s.on('error', () => {
      if (this.sock === s) this.sock = null;
      if (!this.quitting && tries < 60) setTimeout(() => this.connect(tries + 1), 150);
    });
    s.on('close', () => { if (this.sock === s) this.sock = null; });
  }

  send(cmd) {
    if (!this.sock) return;
    try { this.sock.write(JSON.stringify({ command: cmd, request_id: this.reqId++ }) + '\n'); } catch (e) { /* Pipe zu */ }
  }
  set(prop, val) { this.send(['set_property', prop, val]); }

  // ---------- Nachrichten von mpv ----------

  onMsg(m) {
    if (m.event === 'property-change') return this.onProp(m.name, m.data);
    switch (m.event) {
      case 'start-file':
        this.buffering = true; this.emit('ev', 'buffer', true);
        break;
      case 'file-loaded':
        this.loaded = true;
        break;
      case 'playback-restart':
        if (this.buffering) { this.buffering = false; this.emit('ev', 'buffer', false); }
        if (!this.readySent) { this.readySent = true; this.emit('ev', 'ready', null); }
        this.checkFrame();
        break;
      case 'end-file':
        if (m.reason === 'eof') { this.loaded = false; this.emit('ev', 'end', null); }
        else if (m.reason === 'error') { this.loaded = false; this.emit('ev', 'error', 'mpv: ' + (m.file_error || 'Wiedergabe fehlgeschlagen')); }
        break;
    }
  }

  onProp(name, v) {
    const st = this.st;
    switch (name) {
      case 'pause': st.pause = !!v; break;
      case 'idle-active': st.idle = !!v; break;
      case 'time-pos': st.pos = typeof v === 'number' ? v : 0; break;
      case 'duration': st.dur = typeof v === 'number' ? v : 0; break;
      case 'seeking': if (v && this.readySent) { this.buffering = true; this.emit('ev', 'buffer', true); } break;
      case 'paused-for-cache':
        if (!this.readySent) break;
        if (!!v !== this.buffering) { this.buffering = !!v; this.emit('ev', 'buffer', !!v); }
        break;
      case 'track-list': st.tracks = Array.isArray(v) ? v : []; break;
      case 'video-params': st.vparams = v || null; this.checkFrame(); break;
      case 'demuxer-cache-state': {
        const rate = v && v['raw-input-rate'];
        if (typeof rate === 'number' && rate > 0) st.kbps = Math.round(rate * 8 / 1000);
        break;
      }
    }
  }

  /** Erstes Bild da (Sender-Ampel „gut“ erst mit Bild) */
  checkFrame() {
    if (this.frameSent || !this.readySent) return;
    if (this.st.vparams && this.st.vparams.w > 0) { this.frameSent = true; this.emit('ev', 'frame', null); }
  }

  tick() {
    const st = this.st;
    const playing = this.isPlaying();
    // Rückstand zum Live-Bild: vergangene Zeit minus abgespielte Zeit (wie auf dem Stick)
    const now = Date.now(), pos = Math.round(st.pos * 1000);
    if (this.behindWall && pos < this.behindPos - 1000) this.behindWall = 0;
    if (!this.behindWall) { this.behind = 0; if (playing && pos > 0) { this.behindWall = now; this.behindPos = pos; } }
    else this.behind = Math.max(0, (now - this.behindWall) - (pos - this.behindPos));
    if (playing && !this.buffering) this.emit('ev', 'time', st.pos);
    this.emit('state', this.state());
  }

  isPlaying() { return this.loaded && !this.st.pause && !this.st.idle; }

  state() {
    const st = this.st;
    return {
      playing: this.isPlaying() || (this.loaded && this.buffering && !st.pause),
      pos: st.pos, dur: st.dur > 0 && isFinite(st.dur) ? st.dur : 0,
      kbps: st.kbps, behind: this.behind,
      audio: JSON.stringify(this.list('audio')), text: JSON.stringify(this.list('sub'))
    };
  }

  /** Ton-/Untertitelspuren wie auf Android: [{ i, name, detail, selected }] */
  list(type) {
    return this.st.tracks.filter((t) => t.type === type).map((t, i) => {
      const lang = (t.lang || '').toLowerCase();
      let name = t.title || LANG[lang] || (lang ? lang.toUpperCase() : (type === 'sub' ? 'Untertitel ' : 'Spur ') + (i + 1));
      if (t.title && LANG[lang] && t.title.toLowerCase().indexOf(LANG[lang].toLowerCase()) < 0) name = LANG[lang] + ' · ' + t.title;
      const ch = t['demux-channel-count'];
      const detail = [(t.codec || '').toUpperCase(), ch ? (ch === 6 ? '5.1' : ch === 8 ? '7.1' : ch === 2 ? 'Stereo' : ch + ' Kanäle') : ''].filter(Boolean).join(' · ');
      return { i, id: t.id, name, detail, selected: !!t.selected };
    });
  }

  // ---------- Befehle der Oberfläche ----------

  applySettings() {
    const b = this.opts.buffer || 'normal';
    const wait = b === 'small' ? 1 : b === 'large' ? 6 : 2.5;
    const ahead = b === 'small' ? 5 : b === 'large' ? 60 : 20;
    this.set('cache-pause-wait', wait);
    this.set('demuxer-readahead-secs', ahead);
    this.setRect(this.rect);
  }

  load(url) {
    this.lastUrl = url;
    if (!this.sock) { this.pending = url; return; }
    this.reset();
    this.st.pos = 0; this.st.dur = 0; this.st.tracks = []; this.st.vparams = null; this.st.pause = false;
    this.buffering = true;
    this.set('pause', false);
    this.send(['loadfile', url, 'replace']);
  }

  stop() {
    this.pending = null;
    this.reset();
    this.st.tracks = []; this.st.vparams = null;
    this.send(['stop']);
  }

  toggle() { this.set('pause', !this.st.pause); this.st.pause = !this.st.pause; }

  /** Bildfläche als Anteile des Fensters (Vorschau in Live TV, Vollbild = 0,0,1,1) */
  setRect(r) {
    this.rect = r || [0, 0, 1, 1];
    const [x, y, w, h] = this.rect.map((n) => Math.max(0, Math.min(1, Number(n) || 0)));
    this.set('video-margin-ratio-left', x);
    this.set('video-margin-ratio-top', y);
    this.set('video-margin-ratio-right', Math.max(0, 1 - x - (w || 1)));
    this.set('video-margin-ratio-bottom', Math.max(0, 1 - y - (h || 1)));
  }

  setResize(mode) {
    if (mode === 'fill') { this.set('keepaspect', false); this.set('panscan', 0); }
    else if (mode === 'zoom') { this.set('keepaspect', true); this.set('panscan', 1); }
    else { this.set('keepaspect', true); this.set('panscan', 0); }
  }

  seekTo(sec) { this.send(['seek', Math.max(0, Number(sec) || 0), 'absolute']); }
  seekBy(sec) { this.send(['seek', Number(sec) || 0, 'relative']); }

  selectTrack(kind, index) {
    const type = kind === 'text' ? 'sub' : 'audio';
    if (type === 'sub' && index < 0) { this.set('sid', 'no'); return true; }
    const t = this.list(type)[index];
    if (!t) return false;
    this.set(type === 'sub' ? 'sid' : 'aid', t.id);
    return true;
  }

  setAudioLangs(langs) {
    const l = String(langs || '').split(',').map((s) => s.trim()).filter(Boolean);
    const exp = [];
    l.forEach((c) => { exp.push(c); if (c === 'de') exp.push('ger', 'deu'); if (c === 'en') exp.push('eng'); });
    this.set('alang', exp.length ? exp.join(',') : 'de,ger,deu,en,eng');
  }

  setBuffer(mode) { this.opts.buffer = mode; this.applySettings(); }

  quit() {
    this.quitting = true;
    clearInterval(this.timer);
    try { this.send(['quit']); } catch (e) { /* egal */ }
    setTimeout(() => { try { this.proc.kill(); } catch (e) { /* egal */ } }, 500);
  }
}

// Verfahren für die Bildausgabe: auto = D3D11 ohne „Flip“ (verträgt sich am besten mit der Oberfläche darüber)
Mpv.VIDEO_OUT = {
  auto: ['--vo=gpu', '--gpu-api=d3d11', '--d3d11-flip=no', '--hwdec=auto-safe'],
  d3d11: ['--vo=gpu', '--gpu-api=d3d11', '--d3d11-flip=yes', '--hwdec=auto-safe'],
  opengl: ['--vo=gpu', '--gpu-api=opengl', '--hwdec=auto-safe'],
  soft: ['--vo=gpu', '--gpu-api=d3d11', '--d3d11-flip=no', '--hwdec=no'],
  direct3d: ['--vo=direct3d', '--hwdec=no']
};

module.exports = Mpv;
