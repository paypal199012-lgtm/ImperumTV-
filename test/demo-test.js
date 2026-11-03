// Simulator-Test: Demo-Filme, -Serie und -Sender nacheinander abspielen und den Zustand des Players protokollieren
(function () {
  var L = window.__tl = [], t0 = Date.now();
  function log(m) {
    var line = ((Date.now() - t0) / 1000 | 0) + 's ' + m;
    L.push(line);
    try { window.webkit.messageHandlers.ab.postMessage({ m: 'log', a: ['TEST ' + line] }); } catch (e) { /* nur im iPhone-Simulator */ }
  }
  function shot(name) { try { window.webkit.messageHandlers.ab.postMessage({ m: 'log', a: ['SHOT ' + name] }); } catch (e) { /* egal */ } }
  var A = window.AndroidBridge;
  if (A && A.open && !A.__w) { var o = A.open; A.__w = 1; A.open = function (u) { log('open ' + u); return o.apply(A, arguments); }; }
  function vis(sel) { return [].slice.call(document.querySelectorAll(sel)).filter(function (x) { return x.offsetParent !== null; }); }
  function click(re) { var r = new RegExp(re, 'i'); var e = vis('#app .focusable').filter(function (x) { return r.test(x.textContent); })[0]; if (e) e.click(); return !!e; }
  function key(k) { var e = vis('#app .focusable[data-key="' + k + '"]')[0]; if (e) e.click(); return !!e; }
  function back() {
    var b = document.querySelector('.ios-back');
    if (b && !b.classList.contains('hidden')) { b.click(); return 'knopf'; }
    document.dispatchEvent(new KeyboardEvent('keydown', { keyCode: 27, which: 27, bubbles: true })); return 'esc';
  }
  function state() {
    var s = window.__abState || {};
    var err = vis('#app .pp-error, #app .player-error, #app .error, .toast').map(function (x) { return x.textContent.trim().slice(0, 120); }).join(' / ');
    return 'playing=' + s.playing + ' pos=' + s.pos + ' dur=' + s.dur + ' vlc=' + s.vlcNow + ' kbps=' + s.kbps + (err ? ' FEHLER: ' + err : '');
  }
  var steps = [];
  function at(wait, fn) { steps.push([wait, fn]); }
  at(0, function () { return 'filme:' + click('^\\s*FILME\\s*$'); });
  [101, 102, 103, 104].forEach(function (id) {
    at(3, function () { return 'film ' + id + ':' + key('movie-' + id); });
    at(3, function () { return 'abspielen:' + click('Abspielen|Nochmal ansehen|Weiter ab'); });
    at(14, function () { shot('film-' + id); return 'FILM ' + id + ' ' + state(); });
    at(1, function () { return 'zurueck:' + back(); });
    at(2, function () { return 'zurueck:' + back(); });
  });
  at(2, function () { return 'zurueck:' + back(); });
  at(3, function () { return 'live:' + click('^\\s*LIVE TV\\s*$'); });
  [0, 1, 2].forEach(function (i) {
    at(3, function () { var r = vis('#app .col-list .row, #app .ch-row, #app .channel')[i]; if (r) r.click(); return 'sender ' + i + ':' + !!r; });
    at(14, function () { shot('sender-' + i); return 'SENDER ' + i + ' ' + state(); });
  });
  var i = 0, tries = 0;
  (function ready() {
    if (!vis('#app .focusable').filter(function (x) { return /^\s*FILME\s*$/i.test(x.textContent); })[0] && tries++ < 60) { setTimeout(ready, 1000); return; }
    log('Oberfläche bereit');
    next();
  })();
  function next() {
    if (i >= steps.length) { log('ENDE'); return; }
    var s = steps[i++];
    setTimeout(function () { try { log(s[1]()); } catch (e) { log('JS-Fehler: ' + e); } next(); }, s[0] * 1000);
  }
  return 'gestartet';
})();
