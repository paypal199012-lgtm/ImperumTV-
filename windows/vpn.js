// ImperumTV für Windows: VPN mit der eigenen .ovpn-Datei (von der Admin-Seite), wie auf dem Stick.
// Technik: Das mitgelieferte OpenVPN wird beim ersten Einschalten einmal installiert (Windows fragt dabei nach Administrator-Rechten).
// Danach startet der OpenVPN-Dienst die Verbindung für die App; gesteuert wird sie über die Management-Schnittstelle von OpenVPN.
'use strict';
const fs = require('fs');
const os = require('os');
const net = require('net');
const path = require('path');
const { spawn } = require('child_process');
const EventEmitter = require('events');

const SERVICE_PIPE = '\\\\.\\pipe\\openvpn\\service';
// Zeilen, die in der .ovpn-Datei nichts zu suchen haben (Skripte, Protokolle, eigene Steuerung) – werden entfernt
const BLOCK = /^\s*(script-security|up|down|route-up|route-pre-down|ipchange|tls-verify|auth-user-pass-verify|client-connect|client-disconnect|learn-address|plugin|management\S*|log|log-append|status|cd|config|daemon|writepid|chroot|setenv-safe|tmp-dir|auth-user-pass\s+\S+)(\s|$)/i;

class Vpn extends EventEmitter {
  constructor(dir, resources, store) {
    super();
    this.dir = dir;                      // Ordner der App-Daten (…\AppData\Roaming\ImperumTV\vpn)
    this.resources = resources;          // Ordner mit OpenVPN.msi
    this.store = store;                  // { get(), set(o) } – Profil, Benutzer, Passwort (verschlüsselt), „beim Start verbinden“
    this.state = 'aus';
    this.error = '';
    this.logLines = [];
    this.mgmt = null; this.svc = null;
    try { fs.mkdirSync(dir, { recursive: true }); } catch (e) { /* egal */ }
  }

  // ---------- Stand für die Oberfläche (gleich wie auf Android) ----------

  info() {
    const s = this.store.get();
    const conf = s.conf || '';
    const m = /^\s*remote\s+(\S+)/im.exec(conf);
    return { state: this.state, error: this.error, has: !!conf.trim(), user: s.user || '', server: m ? m[1] : '', auto: !!s.auto, installed: this.installed() };
  }

  /** Letzte Zeilen aus dem eigenen Protokoll von OpenVPN (bei Fehlern, für die Admin-Seite) */
  addOvpnTail() {
    try {
      if (!this.ovpnLogFile || !fs.existsSync(this.ovpnLogFile)) { this.log('(kein OpenVPN-Protokoll)'); return; }
      const t = fs.readFileSync(this.ovpnLogFile, 'utf8').split(/\r?\n/).filter((l) => l.trim() && !/username|password|passwort|MANAGEMENT: CMD/i.test(l));
      this.log('--- OpenVPN-Protokoll (Ende) ---');
      t.slice(-35).forEach((l) => this.log('  ' + l.replace(/^\w{3} \w{3}\s+\d+ [\d:]+ \d{4}\s*/, '').slice(0, 200)));
    } catch (e) { this.log('(OpenVPN-Protokoll nicht lesbar: ' + e.message + ')'); }
  }

  set(state, err) {
    if (state === 'fehler' && this.state !== 'fehler') this.addOvpnTail();
    // Wächter: steht die Verbindung nach 40 s nicht, Fehler melden (mit Protokoll an die Admin-Seite) statt ewig „verbindet“
    clearTimeout(this.guard);
    if (state === 'verbindet' && !this.settingUp) {
      this.guard = setTimeout(() => {
        if (this.state !== 'verbindet') return;
        this.log('Zeitüberschreitung: nach 40 s keine Verbindung (Dienst: ' + (this.svcAnswer || 'keine Antwort') + ', Management: ' + (this.mgmtSeen ? 'verbunden' : 'nicht erreicht') + ')');
        this.stopping = true;
        if (this.mgmt) this.send('signal SIGTERM');
        // OpenVPN schreibt sein Protokoll beim Beenden zu Ende – kurz warten, dann melden
        setTimeout(() => { this.stopping = false; this.dropAuth(); this.set('fehler', 'Keine Verbindung nach 40 Sekunden'); }, 2500);
      }, 40000);
    }
    if (state === this.state && (err || '') === this.error) return;
    this.state = state; this.error = err || '';
    this.log('Status: ' + state + (err ? ' – ' + err : ''));
    this.emit('change', state, this.error);
  }

  log(line) {
    if (/username|password|passwort/i.test(line)) return;          // keine Zugangsdaten ins Protokoll
    this.logLines.push(new Date().toLocaleTimeString('de-DE') + ' ' + line);
    if (this.logLines.length > 300) this.logLines.splice(0, this.logLines.length - 300);
  }

  setProfile(conf, user, pass) {
    const s = this.store.get();
    s.conf = String(conf || ''); s.user = String(user || ''); s.pass = String(pass || '');
    this.store.set(s);
    if (!s.conf.trim() && this.state !== 'aus') this.disconnect();
  }

  setAuto(on) { const s = this.store.get(); s.auto = !!on; this.store.set(s); }

  // ---------- OpenVPN einrichten (einmal, mit Administrator-Rechten) ----------

  openvpnExe() {
    const base = process.env.ProgramW6432 || process.env.ProgramFiles || 'C:\\Program Files';
    return path.join(base, 'OpenVPN', 'bin', 'openvpn.exe');
  }
  installed() { return process.platform === 'win32' && fs.existsSync(this.openvpnExe()); }

  setup() {
    return new Promise((resolve, reject) => {
      const msi = path.join(this.resources, 'OpenVPN.msi');
      if (!fs.existsSync(msi)) { reject(new Error('OpenVPN-Paket fehlt in der App')); return; }
      const user = (process.env.USERDOMAIN ? process.env.USERDOMAIN + '\\' : '') + os.userInfo().username;
      const ps1 = path.join(os.tmpdir(), 'imperumtv-vpn-einrichten.ps1');
      fs.writeFileSync(ps1, [
        'param([string]$Msi, [string]$User)',
        '$p = Start-Process msiexec.exe -ArgumentList ("/i `"" + $Msi + "`" /qn /norestart") -Wait -PassThru',
        // Benutzer darf danach eigene Verbindungen über den OpenVPN-Dienst starten (so wie bei der OpenVPN-GUI)
        'try { Add-LocalGroupMember -Group "OpenVPN Administrators" -Member $User -ErrorAction Stop } catch { }',
        // OpenVPN-GUI nicht bei jedem Windows-Start mitstarten (ImperumTV steuert das VPN selbst)
        'foreach ($n in @("OPENVPN-GUI", "OpenVPN-GUI")) { Remove-ItemProperty -Path "HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run" -Name $n -ErrorAction SilentlyContinue }',
        'exit $p.ExitCode'
      ].join('\r\n'), 'utf8');
      this.settingUp = true;
      this.set('verbindet', 'VPN wird eingerichtet – bitte bei Windows auf „Ja“ klicken');
      // Start-Process -Verb RunAs zeigt die Windows-Abfrage (UAC). Abgelehnt → Fehler.
      const outer = 'try { $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList @(' +
        "'-NoProfile','-ExecutionPolicy','Bypass','-File','\"" + ps1 + "\"','-Msi','\"" + msi + "\"','-User','\"" + user + "\"'" +
        '); exit $p.ExitCode } catch { exit 1223 }';
      const ch = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', outer], { windowsHide: true });
      ch.on('exit', (code) => {
        this.settingUp = false;
        this.log('Einrichtung beendet, Code ' + code + ', OpenVPN da: ' + this.installed());
        if (this.installed() && (code === 0 || code === 3010)) { this.log('OpenVPN eingerichtet'); resolve(); return; }
        reject(new Error(code === 1223 ? 'Einrichtung abgebrochen (Windows-Abfrage nicht bestätigt)' : 'Einrichtung fehlgeschlagen (Fehler ' + code + ')'));
      });
      ch.on('error', (e) => { this.settingUp = false; reject(e); });
    });
  }

  // ---------- Verbinden / Trennen ----------

  async connect() {
    const s = this.store.get();
    if (!s.conf || !s.conf.trim()) { this.set('fehler', 'Kein VPN hinterlegt – auf der Website beim Gerät die .ovpn-Datei hochladen'); return; }
    if (this.state === 'an' || (this.state === 'verbindet' && this.mgmt)) return;
    if (process.platform !== 'win32') { this.set('fehler', 'VPN gibt es nur unter Windows'); return; }
    try {
      if (!this.installed()) await this.setup();
    } catch (e) { this.set('fehler', e.message); return; }
    this.set('verbindet', '');
    // Bereinigte Konfiguration speichern
    const lines = s.conf.replace(/\r/g, '').split('\n').filter((l) => !BLOCK.test(l));
    // Benutzername/Passwort: als Datei für OpenVPN (wird nach dem Verbinden gelöscht); „auth-user-pass“ ohne Datei aus der .ovpn entfernen
    for (let i = lines.length - 1; i >= 0; i--) if (/^\s*auth-user-pass\s*$/i.test(lines[i])) lines.splice(i, 1);
    this.authFile = path.join(this.dir, 'zugang.txt');
    fs.writeFileSync(this.authFile, String(s.user || '').replace(/[\r\n]+/g, '') + '\n' + String(s.pass || '').replace(/[\r\n]+/g, '') + '\n', { encoding: 'utf8', mode: 0o600 });
    // Ältere Anbieter-Dateien (z. B. Surfshark) nutzen „cipher AES-256-CBC“: OpenVPN 2.6 braucht dafür eine Zusatzangabe
    const cipher = lines.map((l) => /^\s*cipher\s+(\S+)/i.exec(l)).filter(Boolean).map((m) => m[1].toUpperCase())[0];
    if (!lines.some((l) => /^\s*data-ciphers\s/i.test(l))) {
      lines.push('data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305' + (cipher && !/GCM|CHACHA/.test(cipher) ? ':' + cipher : ':AES-256-CBC'));
      if (cipher && !/GCM|CHACHA/.test(cipher)) lines.push('data-ciphers-fallback ' + cipher);
    }
    const cfg = path.join(this.dir, 'imperumtv.ovpn');
    fs.writeFileSync(cfg, lines.join('\r\n') + '\r\n', 'utf8');
    this.port = 25340 + Math.floor(Math.random() * 400);
    this.mpass = require('crypto').randomBytes(12).toString('hex');
    this.svcAnswer = ''; this.mgmtSeen = false;
    this.log('Starte OpenVPN über den Dienst (Konfiguration ' + lines.length + ' Zeilen, Server ' + (this.info().server || '?') + ')');
    this.ovpnLogFile = path.join(this.dir, 'openvpn.log');
    try { fs.unlinkSync(this.ovpnLogFile); } catch (e) { /* gab es nicht */ }
    const options = '--config "' + cfg + '" --log "' + this.ovpnLogFile + '" --auth-user-pass "' + this.authFile + '" --auth-retry nointeract --management 127.0.0.1 ' + this.port + ' stdin --management-hold --verb 3';
    this.startViaService(options);
  }

  /** OpenVPN über den „OpenVPN Interactive Service“ starten (der setzt Netzwerk und Routen mit den nötigen Rechten) */
  startViaService(options) {
    const msg = Buffer.from(this.dir + '\0' + options + '\0' + this.mpass + '\n\0', 'utf16le');
    const p = net.connect(SERVICE_PIPE);
    this.svc = p;
    let buf = '';
    p.on('connect', () => { this.log('Dienst erreicht'); p.write(msg); });
    p.on('data', (d) => {
      buf += d.toString('utf16le');
      const parts = buf.split('\n');
      if (parts.length < 3) return;
      const code = parseInt(parts[0], 16);
      this.svcAnswer = parts.slice(0, 3).join(' | ').replace(/\0/g, '').slice(0, 200);
      this.log('Dienst antwortet: ' + this.svcAnswer);
      buf = '';
      if (this.stopping) return;                       // Beenden nach Zeitüberschreitung: Meldung kommt gleich
      if (code === 0) { this.log('OpenVPN gestartet (' + parts[2].replace(/\0/g, '') + ' ' + parseInt(parts[1], 16) + ')'); this.connectMgmt(0); }
      else {
        const why = (parts[1] || '').replace(/\0/g, '').trim();
        this.log('Dienst meldet Fehler 0x' + code.toString(16) + ': ' + why);
        this.set('fehler', /authori|berechtig|not allowed/i.test(why) ? 'Keine Berechtigung – bitte Windows einmal ab- und wieder anmelden' : 'OpenVPN-Dienst: ' + (why || 'Fehler ' + code));
      }
    });
    p.on('error', (e) => {
      if (this.svc !== p) return;
      this.svc = null;
      if (this.state !== 'verbindet') return;          // schon getrennt/Fehler gemeldet (z. B. EPIPE nach dem Beenden)
      this.set('fehler', 'OpenVPN-Dienst nicht erreichbar (' + e.code + ') – Windows einmal neu starten');
    });
    p.on('close', () => { if (this.svc === p) this.svc = null; });
  }

  connectMgmt(tries) {
    const m = net.connect(this.port, '127.0.0.1');
    let buf = '';
    m.on('connect', () => { this.mgmt = m; this.mgmtSeen = true; this.log('Management verbunden (Port ' + this.port + ')'); });
    this.pwSent = false; this.setupSent = false;
    m.on('data', (d) => {
      buf += d.toString('utf8');
      // Passwort-Abfrage kommt ohne Zeilenende und manchmal direkt vor der nächsten Antwort in derselben Zeile
      if (buf.indexOf('ENTER PASSWORD:') >= 0) {
        buf = buf.replace('ENTER PASSWORD:', '');
        if (!this.pwSent) { this.pwSent = true; this.send(this.mpass); }
      }
      let i;
      while ((i = buf.search(/\r?\n/)) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(buf[i] === '\r' ? i + 2 : i + 1);
        this.onLine(line);
      }
    });
    m.on('error', () => {
      if (this.mgmt === m) this.mgmt = null;
      if (this.state === 'verbindet' && tries < 120 && !this.mgmt) setTimeout(() => this.connectMgmt(tries + 1), 250);
      else if (!this.mgmt && this.state === 'verbindet') this.log('Management nicht erreichbar (Port ' + this.port + ')');
    });
    m.on('close', () => {
      if (this.mgmt !== m) return;
      this.mgmt = null;
      if (this.stopping) return;
      if (this.state !== 'fehler') this.set('aus', '');
    });
  }

  send(line) { if (this.mgmt) try { this.mgmt.write(line + '\n'); } catch (e) { /* zu */ } }

  onLine(line) {
    // Nach dem richtigen Passwort (oder falls keins nötig war): Status/Protokoll einschalten und loslegen – nur einmal
    if (/^SUCCESS: password is correct/.test(line) || (/^>INFO:/.test(line) && !this.pwSent)) {
      this.log('Management: ' + line);
      if (!this.setupSent) { this.setupSent = true; this.send('state on'); this.send('log on'); this.send('hold release'); this.pollState(); }
      return;
    }
    // Antwort auf „state“: „1730885416,CONNECTED,SUCCESS,10.8.8.18,…“
    if (/^\d+,CONNECTED,/.test(line)) { if (this.state !== 'an') { this.log('Status: verbunden (' + line.split(',')[3] + ')'); this.set('an', ''); this.dropAuth(); } return; }
    if (/^>LOG:.*Initialization Sequence Completed/.test(line) && this.state !== 'an') { this.log('Initialization Sequence Completed'); this.set('an', ''); this.dropAuth(); return; }
    if (/^>HOLD:/.test(line)) { this.send('hold release'); return; }
    if (/^>LOG:/.test(line)) { const p = line.split(','); this.log(p.slice(2).join(',')); return; }
    if (/^>PASSWORD:Need 'Auth'/.test(line)) {
      const s = this.store.get();
      const q = (v) => '"' + String(v || '').replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
      this.send('username "Auth" ' + q(s.user)); this.send('password "Auth" ' + q(s.pass));
      return;
    }
    if (/^>PASSWORD:Verification Failed/.test(line)) { this.set('fehler', 'Benutzername oder Passwort für das VPN falsch'); this.send('signal SIGTERM'); return; }
    if (/^>FATAL:/.test(line)) { this.dropAuth(); this.set('fehler', line.slice(7)); return; }
    if (/AUTH_FAILED/.test(line)) { this.dropAuth(); this.set('fehler', 'Benutzername oder Passwort für das VPN falsch'); return; }
    if (/^(SUCCESS|ERROR):/.test(line)) this.log('Management: ' + line);
    if (/^>STATE:/.test(line)) {
      const st = (line.split(',')[1] || '').toUpperCase();
      if (st === 'CONNECTED') { this.set('an', ''); this.dropAuth(); }
      else if (st === 'EXITING') { if (this.state !== 'fehler' && !this.stopping) this.set('aus', ''); }
      else if (this.state !== 'fehler') this.set('verbindet', '');
    }
  }

  /** Zusätzlich alle 3 s nach dem Stand fragen, bis verbunden (falls eine Echtzeit-Meldung untergeht) */
  pollState() {
    clearInterval(this.poller);
    this.poller = setInterval(() => {
      if (!this.mgmt || this.state !== 'verbindet') { clearInterval(this.poller); return; }
      this.send('state');
    }, 3000);
  }

  dropAuth() { if (this.authFile) { try { fs.unlinkSync(this.authFile); } catch (e) { /* schon weg */ } } }

  disconnect() {
    this.dropAuth();
    if (this.mgmt) { this.send('signal SIGTERM'); const m = this.mgmt; setTimeout(() => { try { m.destroy(); } catch (e) { /* egal */ } }, 3000); }
    if (this.svc) { const p = this.svc; this.svc = null; setTimeout(() => { try { p.destroy(); } catch (e) { /* egal */ } }, 3000); }
    this.set('aus', '');
  }
}

module.exports = Vpn;
