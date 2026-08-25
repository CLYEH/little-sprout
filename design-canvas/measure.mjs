// 在真的瀏覽器裡跑 _probe.html，把量到的每一項寫進 measured.json。
// Tokens 板上印的數字、verify.mjs 下的判斷，都只讀這個檔 —— 不可能再自報不實。
// Run: node measure.mjs   （需要本機 http server：python3 -m http.server 8731）
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { H1_GROUPS, RULE } from './tokens.mjs';

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

/* ── 尾段空白最大的板；主按鈕中心「位置最低」的板；以及其中用到尾段豁免的板 ──
   措辭統一（第 4 輪 R10）：位置最低＝畫面上最靠下＝百分比最大。measure 的 console、
   Tokens 板的實測句、verify 的 G10，三處同一個詞。btnMaxPct 這個 key 名裡的 Max
   指的是百分比最大，也就是位置最低的那一張。 */
const pct = (b) => (b ? Math.round((b.mid / b.h) * 1000) / 10 : null);
const trail = R.boards.reduce((a, b) => (b.trail > a.trail ? b : a), R.boards[0]);
const tailBoards = new Set(R.boards.filter((b) => b.trail > RULE.pause).map((b) => b.file));
const lowest = (rows) => rows.reduce((a, b) => (b.mid / b.h > a.mid / a.h ? b : a), rows[0] || null);
const btnTop = lowest(R.mainBtn);
const btnTail = lowest(R.mainBtn.filter((b) => tailBoards.has(b.file)));

const out = {
  ...prev,
  count: R.boards.length,
  boards: R.boards,
  clipped: R.boards.filter((b) => b.clipped).map((b) => `${b.file}+${b.clipped}`),
  measuredAt: new Date().toISOString().slice(0, 10),

  voids: R.voids,
  maxVoid: wPh.interior, maxVoidFile: `${wPh.file}`,
  maxVoidPad: wPad.interior, maxVoidPadFile: `${wPad.file}/${wPad.col}`,
  pauses: R.pauses, pauseBad: R.pauseBad,

  /* 尾段空白與主按鈕：呼吸帶規則 ② 用的兩個數 */
  maxTrail: trail.trail, maxTrailFile: trail.file,
  btnMaxPct: pct(btnTop), btnMaxFile: btnTop ? btnTop.file : '-',
  btnTailPct: btnTail ? pct(btnTail) : null, btnTailFile: btnTail ? btnTail.file : '-',
  mainBtn: R.mainBtn.map((b) => ({ ...b, pct: pct(b) })),

  lips: R.lips, lipNone: R.lipNone.length, lipNoneWho: R.lipNone, lipTotal: R.lipTotal,
  toggles: R.toggles,
  photos: R.photos,
  focus: R.photos.filter((p) => /^(Main|WelcomeIPad)$/.test(p.file)).map((p) => ({
    name: p.file === 'Main' ? '手機' : 'iPad',
    bw: p.bw, bh: p.bh,
    axis: p.cropX >= p.cropY ? '橫向' : '縱向',
    crop: Math.round(Math.max(p.cropX, p.cropY)),
    pos: p.pos,
    clamped: /(^|\s)(0%|100%)/.test(p.pos),
  })),

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
console.log(`  >${RULE.pause}px 空白 ${out.pauses.length} 段掛牌 / ${out.pauseBad.length} 段未掛牌 · 尾段最大 ${out.maxTrail}px (${out.maxTrailFile}) · 主按鈕中心位置最低 ${out.btnMaxPct}% (${out.btnMaxFile})`);
console.log(`  唇邊 ${JSON.stringify(out.lips)} · 無唇邊 ${out.lipNone}（${out.lipNoneWho.join(' ')}）· 開關列 ${out.toggles.map((t) => `${t.file}@${t.top}`).join(' ')}`);
