// 在真的瀏覽器裡跑 _probe.html，把量到的每一項寫進 measured.json。
// Tokens 板上印的數字、verify.mjs 下的判斷，都只讀這個檔 —— 不可能再自報不實。
// Run: node measure.mjs   （需要本機 http server：python3 -m http.server 8741）
import { writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { H1_GROUPS, RULE, TRACK, hash12, dERgb, cellSeen, STUB_USES } from './tokens.mjs';
import { CANCEL_COV } from './brush.mjs';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
/* 第 1 輪 R9：上一輪的預設埠 8731 指的是**軌 B 的根目錄**。兩軌的檔名、欄位、
   data-* 標記完全相容，所以那樣量出來的 measured.json 長得毫無異狀，
   31 張板的 gate 會全綠地放行別人的設計。兩道修法：
     ① 預設埠改 8741（軌 D 自己的），而且埠沒開時是硬失敗不是靜默；
     ② **開跑前先抓 server 上的 _root.json 與本地的比對**（軌別＋板清單指紋），
        不一致就 exit 1 —— 這一條才是真正的保險，換埠號也騙不過。 */
const URLBASE = process.env.LS_URL || 'http://localhost:8741';
/* 產物根目錄。平常是自己所在的目錄；負面對照（selftest）會指到一份動過手腳的複本 ——
   **URLBASE 不變**，所以「瀏覽器讀到的」與「本地磁碟上的」會不一致，
   三方對帳就必須當場 exit 1。那正是要驗的事（第 4 輪的 M8 把那三行改成恆真）。 */
const HERE = process.env.LS_ROOT ? pathToFileURL(`${process.env.LS_ROOT.replace(/\/?$/, '/')}`) : new URL('.', import.meta.url);
const at = (f) => new URL(f, HERE);

/* `node measure.mjs --selftest` ＝ 跑負面對照（票面指名的入口）。
   實作放在 selftest.mjs：它要對**同一份 gate 程式**餵壞樣本，包含這一支自己。 */
if (process.argv.includes('--selftest')) {
  const r = execFileSync(process.execPath, [new URL('selftest.mjs', import.meta.url).pathname], { encoding: 'utf8', stdio: 'inherit' });
  process.exit(0);
}

const rootFile = at('_root.json');
if (!existsSync(rootFile)) { console.error('measure: 找不到 _root.json —— 先跑 node build.mjs'); process.exit(1); }
const localRoot = JSON.parse(readFileSync(rootFile, 'utf8'));
const served = await fetch(`${URLBASE}/_root.json`).then((r) => (r.ok ? r.json() : null)).catch(() => null);
if (!served) {
  console.error(`measure: ${URLBASE}/_root.json 抓不到 —— server 沒開，或它的根目錄裡沒有這一軌的產物。`);
  console.error(`         本軌應該這樣開：python3 -m http.server 8741 （在 ${HERE.pathname}）`);
  process.exit(1);
}
if (served.track !== localRoot.track || served.fp !== localRoot.fp) {
  console.error(`measure: ${URLBASE} 服務的不是這一份產物 —— server 上是 ${served.track} #${served.fp}（${served.boards} 板），`);
  console.error(`         本地是 ${localRoot.track} #${localRoot.fp}（${localRoot.boards} 板）。量下去會把別軌的數字寫進這一軌，所以停在這裡。`);
  process.exit(1);
}
console.log(`measure: 根目錄核對 OK —— ${served.track} #${served.fp}（${served.boards} 板）`);
/* R9 第二版（第 3 輪）：上面那一關只證明「server 上的 _root.json 跟本地一樣」。
   reviewer 第 2 輪親自踩到的殘留 server 就是這樣過關的 —— 板名尺寸全同、
   _root.json 抄得一模一樣，量的卻是別的目錄。所以 fp 現在併入內容雜湊（build 端），
   而且 probe 會把**它真的 fetch 到的**原文再雜湊一次，見下面的內容核對。 */

const dump = execFileSync(CHROME, [
  '--headless', '--disable-gpu', '--no-sandbox', '--virtual-time-budget=30000',
  '--dump-dom', `${URLBASE}/_probe.html`,
], { encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] });

const m = /JSON&gt;&gt;([\s\S]*?)&lt;&lt;JSON|JSON>>([\s\S]*?)<<JSON/.exec(dump);
if (!m) { console.error('measure: 量不到 —— http server 有開嗎？'); process.exit(1); }
const raw = (m[1] || m[2]).replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
const R = JSON.parse(raw);

/* 內容核對：本地重算一次「板名:原文雜湊」，跟 probe 回報的比。
   probe 是從 URLBASE fetch 的，所以這一關咬的是「瀏覽器讀到的」≠「磁碟上的」。
   三個數字（瀏覽器讀到的／本地磁碟上的／_root.json 記的）必須完全一致。 */
{
  const dcFiles = readdirSync(HERE).filter((f) => f.endsWith('.dc.html')).sort();
  const local = hash12(JSON.stringify(dcFiles.map((f) => `${f}:${hash12(readFileSync(at(f), 'utf8'))}`).sort()));
  if (!R.contentFp) { console.error('measure: probe 沒有回報 contentFp —— _probe.html 是舊版，停在這裡。'); process.exit(1); }
  if (R.contentFp !== local || local !== localRoot.contentFp) {
    console.error(`measure: **內容核對失敗**。瀏覽器讀到的 ${dcFiles.length} 份原文雜湊 #${R.contentFp}，`);
    console.error(`         本地磁碟上是 #${local}，_root.json 裡記的是 #${localRoot.contentFp}。`);
    console.error('         三者必須一致 —— 不一致代表 server 的根目錄不是這一份產物（板名與尺寸相同也騙不過），或 build 沒重跑。');
    process.exit(1);
  }
  console.log(`measure: 內容核對 OK —— ${dcFiles.length} 份原文 #${local}（板清單、尺寸、內容三者都對上）`);
}

const prev = existsSync(at('measured.json')) ? JSON.parse(readFileSync(at('measured.json'), 'utf8')) : {};

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

/* 三格刻度的可讀性推導（D4-01）。逐格對位比，因為人讀的是「哪一格不一樣」：
     adjMin  相鄰兩個狀態之間，同一個格位的**最大** ΔE，取所有相鄰對裡最小的那一組
     endsMin 剛印好↔用完了，三個格位裡**最小**的那一個 ΔE
     bandMax 「還沒用的格」與號碼帶之間的 ΔE 最大值（這一條要趨近於 0：刻度＝帶子） */
const scaleDelta = (rows) => {
  const out = { adjMin: null, endsMin: null, bandMax: null, pairs: [], bands: [] };
  const seen = new Map();   // mode|uses → cells
  for (const r of rows) {
    if (r.uses === 'blank') continue;
    const key = `${r.dark ? 'dark' : 'light'}|${r.uses}`;
    if (!seen.has(key)) seen.set(key, r);
    if (r.band) {
      for (const c of r.cells) {
        if (c.state !== 'left') continue;
        const d = Math.round(dERgb(c.bg, r.band) * 100) / 100;
        out.bands.push({ file: r.file, uses: r.uses, dE: d });
        out.bandMax = out.bandMax === null ? d : Math.max(out.bandMax, d);
      }
    }
  }
  for (const mode of ['light', 'dark']) {
    const at = (u) => seen.get(`${mode}|${u}`);
    for (let i = 0; i < STUB_USES.length - 1; i++) {
      const a = at(STUB_USES[i]), b = at(STUB_USES[i + 1]);
      if (!a || !b) continue;
      const per = a.cells.map((c, j) => Math.round(dERgb(cellSeen(c, CANCEL_COV), cellSeen(b.cells[j], CANCEL_COV)) * 100) / 100);
      const mx = Math.max(...per);
      out.pairs.push({ mode, from: STUB_USES[i], to: STUB_USES[i + 1], per, max: mx });
      out.adjMin = out.adjMin === null ? mx : Math.min(out.adjMin, mx);
    }
    const a = at(STUB_USES[0]), z = at(STUB_USES.at(-1));
    if (a && z) {
      const per = a.cells.map((c, j) => Math.round(dERgb(cellSeen(c, CANCEL_COV), cellSeen(z.cells[j], CANCEL_COV)) * 100) / 100);
      const mn = Math.min(...per);
      out.pairs.push({ mode, from: STUB_USES[0], to: STUB_USES.at(-1), per, min: mn, ends: true });
      out.endsMin = out.endsMin === null ? mn : Math.min(out.endsMin, mn);
    }
  }
  return out;
};

/* 深色的照片少一格光（D4-03）：深色版對淺色版的平均亮度比與 p99 比。 */
const photoStats = (rows) => {
  const day = rows.filter((r) => r.mode === 'day'), night = rows.filter((r) => r.mode === 'night');
  if (!day.length || !night.length) return null;
  const avg = (a, k) => a.reduce((s, r) => s + r[k], 0) / a.length;
  return {
    n: rows.length, day: day.length, night: night.length,
    meanRatio: Math.round(avg(night, 'mean') / avg(day, 'mean') * 1000) / 1000,
    p99Ratio: Math.round(avg(night, 'p99') / avg(day, 'p99') * 1000) / 1000,
    dayMean: Math.round(avg(day, 'mean') * 1e4) / 1e4, nightMean: Math.round(avg(night, 'mean') * 1e4) / 1e4,
  };
};

const out = {
  ...prev,
  /* 這一份量測是在哪一個根目錄上量的（G21b）。verify 拿本地 _root.json 比對它 ——
     就算有人手動改埠號、或先開對再開錯，板上印的實測句也不可能出自別軌。 */
  root: { track: served.track, fp: served.fp, structFp: localRoot.structFp, boards: served.boards, contentFp: R.contentFp },
  light: { seen: R.lightSeen, bad: R.lightBad },
  brand: R.brand, brandBad: R.brandBad,
  insetDepth: R.insetDepth, folds: R.folds || [],
  knobs: R.knobs,
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
  ctaZero: Object.entries(R.cta).filter(([k, v]) => !/Tokens|Notes|Stress/.test(k) && v === 0).length,

  /* ── 漸層（G22）──────────────────────────────────────
     kinds  畫面上實際出現的「不同寫法」數（去重後的 CSS 字串）
     badDir 方向不是垂直的使用點 —— 量不出漸層最不利點，所以一個都不准有
     textOn 底下壓了字的文字節點數（對比就是以最不利點算出來的那一批） */
  grad: {
    total: R.grads.length,
    kinds: new Set(R.grads.filter((g) => !g.repeating).map((g) => g.css)).size,
    badDir: R.gradBad.length,
    textOn: R.contrast.onGrad,
    css: [...new Set(R.grads.map((g) => g.css))],
    byKind: Object.entries(R.grads.reduce((a, g) => { const k = g.kind || (g.repeating ? 'perf' : '(未標記)'); a[k] = (a[k] || 0) + 1; return a; }, {})),
  },
  gradBad: R.gradBad,
  /* G23②：平印面（與其後代）上的漸層。合法的只有掛牌的號碼帶與騎縫線。 */
  flatBad: R.flatBad, flatOk: [...new Set(R.flatOk)].sort(),
  /* R5：登入鍵與它坐的托盤之間的 ΔE。最小的那一顆就是「會不會糊在一起」的那一顆。 */
  trayDelta: R.trayDelta, trays: R.trays,
  trayDeltaMin: R.trayDelta.length ? Math.min(...R.trayDelta.map((d) => d.dE)) : null,
  trayDeltaMinWho: R.trayDelta.length
    ? (() => { const w = R.trayDelta.reduce((a, b) => (b.dE < a.dE ? b : a)); return `${w.file}/${w.who}`; })() : '-',
  gradMin: Math.round(R.contrast.min * 100) / 100,
  gradWorst: R.contrast.worst,
  grainMin: Math.round(R.contrast.grainMin * 100) / 100,
  grainWorst: R.contrast.grainWorst,
  grainFails: R.contrast.grainFails,

  motifs: R.motifs, darkMotifs: R.darkMotifs,

  h1: { all: R.h1, groups: h1groups, padPair: R.h1.filter((x) => x.cap) },

  contrastNodes: R.contrast.n, contrastMin: R.contrast.min, contrastWorst: R.contrast.worst,
  contrastFails: R.contrast.fails, textOverPhoto: R.contrast.overPhoto,

  orphans: R.orphans,
  err: R.err, errCount: R.err.length,
  errGap: R.err.length ? Math.min(...R.err.map((e) => e.gap)) : null,
  errOverlap: R.err.filter((e) => e.overlap).length,

  approve: R.approve, subTap: R.taps,

  /* ── 第 5 輪新增 ──────────────────────────────────────────
     騎縫線、三格刻度、深色照片、寬度階、AX 標籤、具名豁免、玻璃交界。
     這裡只做「彙整」與少量推導；判斷全部在 verify（而且 verify 從 raw 重算一次，
     不吃這裡算好的數 —— 兩邊各自從同一份原始量測出發，對不上就會 FAIL）。 */
  perf: R.perf,
  scale: R.scale,
  scaleDelta: scaleDelta(R.scale),
  cancelCov: CANCEL_COV,
  photo: photoStats(R.photoPix),
  photoPix: R.photoPix,
  widths: R.widths,
  ranks: R.ranks,
  axFit: R.axFit,
  brandLab: R.brandLab,
  exemptSeen: [...new Map(R.exemptSeen.map((e) => [`${e.file}|${e.marker}|${e.role}`, e])).values()],
  exemptBad: [...new Set(R.exemptBad)],
  glass: R.glass,
};

writeFileSync(at('measured.json'), JSON.stringify(out, null, 2));
console.log(`measured ${out.count} boards · 呼吸帶 手機 ${out.maxVoid}px (${out.maxVoidFile}) / iPad ${out.maxVoidPad}px (${out.maxVoidPadFile})`);
console.log(`  對比節點 ${out.contrastNodes}（漸層最不利點最低 ${out.contrastMin} @ ${out.contrastWorst}，未達 AAA ${out.contrastFails.length}）· 照片上文字 ${out.textOverPhoto}`);
console.log(`  漸層 ${out.grad.total} 個使用點／${out.grad.kinds} 種寫法（非垂直 ${out.grad.badDir}）· 壓字節點 ${out.grad.textOn} · 顆粒最暗格最低 ${out.grainMin} @ ${out.grainWorst}（低於 6 的 ${out.grainFails.length}）`);
console.log(`  平印面上的漸層：合法 ${out.flatOk.join('/')}／違規 ${out.flatBad.length}` + (out.flatBad.length ? ` — ${out.flatBad.slice(0,3).join(' | ')}` : ''));
console.log(`  托盤 ${out.trays.length} 個 · 鍵與托盤 ΔE 最小 ${out.trayDeltaMin} (${out.trayDeltaMinWho})`);
console.log(`  inset 使用點 ${out.insetTotal}（白名單外 ${out.insetBad.length}）· 陶土最多 ${out.ctaMax}/板 · 孤兒斷行 ${out.orphans.length} · 裁切 ${out.clipped.length}`);
console.log(`  >${RULE.pause}px 空白 ${out.pauses.length} 段掛牌 / ${out.pauseBad.length} 段未掛牌 · 尾段最大 ${out.maxTrail}px (${out.maxTrailFile}) · 主按鈕中心位置最低 ${out.btnMaxPct}% (${out.btnMaxFile})`);
console.log(`  唇邊 ${JSON.stringify(out.lips)} · 無唇邊 ${out.lipNone}（${out.lipNoneWho.join(' ')}）· 開關列 ${out.toggles.map((t) => `${t.file}@${t.top}`).join(' ')}`);
