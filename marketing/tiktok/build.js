// ImperumTV TikTok-Baukasten: node build.js videos/<name>.json <ausgabeordner>
// Baut <id>.mp4 (mit eigener Musik), <id>-ohne-musik.mp4 und <id>.txt (Beschreibung + Hashtags).
const { chromium } = require('playwright');
const fs = require('fs'), path = require('path'), { execFileSync } = require('child_process');
(async () => {
  const [specPath, outDir] = process.argv.slice(2);
  const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));
  const id = spec.id || path.basename(specPath, '.json');
  fs.mkdirSync(outDir, { recursive: true });
  const frames = fs.mkdtempSync(path.join(require('os').tmpdir(), 'tt-'));
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: 1080, height: 1920 }, deviceScaleFactor: 1 });
  await p.addInitScript(s => { window.SPEC = s; }, spec);
  await p.goto('file://' + path.resolve(__dirname, 'template.html'));
  await p.evaluate(() => document.fonts.ready);
  await p.waitForTimeout(300);
  const dur = await p.evaluate(() => window.DURATION), fps = 30, n = Math.round(dur * fps);
  for (let i = 0; i < n; i++) {
    await p.evaluate(t => setT(t), i / fps);
    await p.screenshot({ path: path.join(frames, 'f' + String(i).padStart(4, '0') + '.jpg'), type: 'jpeg', quality: 90 });
  }
  await b.close();
  const silent = path.join(outDir, id + '-ohne-musik.mp4'), withMusic = path.join(outDir, id + '.mp4'), wav = path.join(frames, 'm.wav');
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(frames, 'f%04d.jpg'), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', silent]);
  execFileSync('python3', [path.join(__dirname, 'music.py'), wav, String(spec.scenes.length)], { cwd: __dirname });
  execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', silent, '-i', wav, '-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart', withMusic]);
  fs.writeFileSync(path.join(outDir, id + '.txt'), (spec.caption || '') + '\n🌐 imperumtv.xyz\n' + (spec.hashtags || '#firetvstick #androidtv #smarttv #techtipps #fyp') + '\n');
  fs.rmSync(frames, { recursive: true, force: true });
  console.log('fertig: ' + id + ' (' + dur.toFixed(1) + ' s)');
})();
