// 在真的瀏覽器裡跑 _probe.html，把量到的每一項寫進 measured.json。
// Tokens 板上印的數字、verify.mjs 下的判斷，都只讀這個檔 —— 不可能再自報不實。
// Run: node measure.mjs   （需要本機 http server：python3 -m http.server 8731）
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { H1_GROUPS } from './tokens.mjs';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const URLBASE = process.env.LS_URL || 'http://localhost:8731';

const dump = execFileSync(CHROME, [
  '--headless', '--disable-gpu', '--no-sandbox', '--virtual-time-budget=30000',
  '--dump-dom', `${URLBASE}/_probe.html`,
], { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] });

const m = /JSON&gt;&gt;([\s\S]*?)&lt;&lt;JSON|JSON>>([\s\S]*?)<<JSON/.exec(dump);
if (!m) { console.error('measure: 量不到 —— http server 有開嗎？'); process.exit(1); }
const raw = (m[1] || m[2]).replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
const R = JSON.parse(raw);

const prev = existsSync(new URL('measured.json', import.meta.url))
  ? JSON.parse(readFileSync(new URL('measured.json', import.meta.url), 'utf8')) : {};

/* ── 呼吸帶：手機與 iPad 分開統計（iPad 是分欄量的）── */
const ph = R.voids.filter((v) => !v.pad), pad = R.voids.filter((v) => v.pad);
const worst = (rows) => rows.reduce((a, b) => (b.interior > a.interior ? b : a), rows[0] || { interior: 0, file: '-', col: '-' });
const wPh = worst(ph), wPad = worst(pad);

/* ── H1 起跑線：照 tokens.mjs 宣告的分組算 ── */
const uniq = (a) => [...new Set(a)].sort((x, y) => x - y);
const h1groups = {};
for (const [g, list] of Object.entries(H1_GROUPS)) {
  h1groups[g] = { want: list.length,
    ys: uniq(R.h1.filter((x) => !x.cap && list.includes(x.file)).map((x) => Math.round(x.y * 10) / 10)),
    n: R.h1.filter((x) => !x.cap && list.includes(x.file)).length };
}

const insetCount = {};
for (const r of R.inset) insetCount[r || '(無 role)'] = (insetCount[r || '(無 role)'] || 0) + 1;

const out = {
  ...prev,
  count: R.boards.length,
  boards: R.boards,
  clipped: R.boards.filter((b) => b.clipped).map((b) => `${b.file}+${b.clipped}`),
  measuredAt: new Date().toISOString().slice(0, 10),

  voids: R.voids,
  maxVoid: wPh.interior, maxVoidFile: `${wPh.file}`,
  maxVoidPad: wPad.interior, maxVoidPadFile: `${wPad.file}/${wPad.col}`,

  insetUse: insetCount, insetTotal: R.inset.length, insetBad: R.insetBad,
  cta: R.cta, ctaMax: Math.max(...Object.entries(R.cta).filter(([k]) => !/Tokens|Notes|Stress/.test(k)).map(([, v]) => v)),
  ctaBoards: Object.keys(R.cta).filter((k) => !/Tokens|Notes|Stress/.test(k)).length,

  motifs: R.motifs, darkMotifs: R.darkMotifs,

  h1: { all: R.h1, groups: h1groups, padPair: R.h1.filter((x) => x.cap) },

  contrastNodes: R.contrast.n, contrastMin: R.contrast.min, contrastWorst: R.contrast.worst,
  contrastFails: R.contrast.fails, textOverPhoto: R.contrast.overPhoto,

  orphans: R.orphans,
  err: R.err, errCount: R.err.length,
  errGap: R.err.length ? Math.min(...R.err.map((e) => e.gap)) : null,
  errOverlap: R.err.filter((e) => e.overlap).length,

  approve: R.approve, subTap: R.taps,
};

writeFileSync(new URL('measured.json', import.meta.url), JSON.stringify(out, null, 2));
console.log(`measured ${out.count} boards · 呼吸帶 手機 ${out.maxVoid}px (${out.maxVoidFile}) / iPad ${out.maxVoidPad}px (${out.maxVoidPadFile})`);
console.log(`  對比節點 ${out.contrastNodes}（最低 ${out.contrastMin} @ ${out.contrastWorst}，未達 AAA ${out.contrastFails.length}）· 照片上文字 ${out.textOverPhoto}`);
console.log(`  inset 使用點 ${out.insetTotal}（白名單外 ${out.insetBad.length}）· 陶土最多 ${out.ctaMax}/板 · 孤兒斷行 ${out.orphans.length} · 裁切 ${out.clipped.length}`);
