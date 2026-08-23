// 自驗：設計稿上「宣稱」的每一件事，都必須在這裡跑得出來。
// 靜態項自己掃 HTML 原始碼；量測項讀 measured.json（measure.mjs 在真瀏覽器裡量的）。
// 第 2 輪被抓到三盞燈接錯線（grep helper 定義、只掃 gap、全幅量死帶），
// 所以 G1–G12 全部進管線，reviewer 拒絕管線外自證。
// Run: node measure.mjs && node verify.mjs
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import {
  T, GAPS, SIZES, FIX, AX, RULE, H1_GROUPS, H1_EXCLUDED, hash12,
  GRAD_KEYS, GRAD_WHY, NO_GRAD_WHY, CONTRAST, gradCss, SP,
  TRACK, TEMP, TEMP_TOL, HUE_MIN, LIGHT_DH, TIME_DH, LIGHT_KEYS, STUB_KEYS, STUB_KNEE, STUB_USES,
  lch, dHue, dE, hueDE, HUE_DE_MIN, INSET_KEYS, AX4, ax4, ax,
  PERF, perfMask, PERF_WHY, PERF_TILE, JITTER, PHOTO_STOP, PHOTO_DIM, PHOTO_STOP_TOL, SCALE_DE, EXEMPT, dERgb, cellSeen, measStamp, KNOB_CR, PEN_DH, lchHex, LIP_DE,
  SCOPE, inScope,
} from './tokens.mjs';
import { CANCEL_COV, CANCEL_PATH, CANCEL_BOX, polyArea } from './brush.mjs';
import { BANDS } from './bands.mjs';
import * as Ink from './ink.mjs';
import * as Icon from './icon.mjs';

/* ── 產物根目錄（第 5 輪 D4-07③）────────────────────────────────
   平常就是 verify.mjs 自己所在的目錄。負面對照（selftest）會把產物複製到一個
   暫存目錄、動一個手腳，再用 **同一份 gate 程式** 跑它 —— 所以「讀哪一份產物」
   必須可以從外面指定，否則沒有辦法對壞樣本做對照實驗。
   注意：import 進來的 tokens.mjs／icon.mjs 永遠是本尊（gate 的規格不隨樣本變），
   而「當作文字掃描的檔案」（build.mjs／tokens.mjs／measure.mjs／產物）走 HERE。 */
const HERE = process.env.LS_ROOT ? pathToFileURL(`${process.env.LS_ROOT.replace(/\/?$/, '/')}`) : new URL('.', import.meta.url);
const at = (f) => new URL(f, HERE);
const files = readdirSync(HERE).filter((f) => f.endsWith('.dc.html')).sort();
const read = (f) => readFileSync(at(f), 'utf8');
const src = readFileSync(at('build.mjs'), 'utf8');
let fail = 0;
const MJ = at('measured.json');
/* G21 用：現行 measured.json 的原文與指紋。verify 跑到最後會把 G1/G2 的統計寫回這個檔，
   所以指紋一律取「verify 開跑時讀到的那一份」—— 與 build 讀到的是同一個狀態。 */
const MEAS_RAW = existsSync(MJ) ? readFileSync(MJ, 'utf8') : '';
const M = MEAS_RAW ? JSON.parse(MEAS_RAW) : {};
/* 哪些 gate 家族真的跑過（MG1 用）。標籤的開頭就是它的代號：G19b／G23①／MG2… */
/* 兩個 hex 的對比（G23⑥ 用；與 icon.mjs／probe 的算式同一條 WCAG 公式）。 */
const crLin = (v) => (v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
const crLum = (h) => { const c = h.replace('#', ''); const s = [0, 2, 4].map((i) => crLin(parseInt(c.slice(i, i + 2), 16) / 255)); return .2126 * s[0] + .7152 * s[1] + .0722 * s[2]; };
const crHex = (a, b) => { const l1 = crLum(a), l2 = crLum(b); const [hi, lo] = l1 > l2 ? [l1, l2] : [l2, l1]; return (hi + .05) / (lo + .05); };
const RAN = new Map();
const famOf = (label) => { const m = /^(MG\d|G\d+[a-z]?)/.exec(label); return m ? m[1] : null; };
const ok = (pass, label, detail = '') => {
  if (!pass) fail++;
  const fam = famOf(label);
  if (fam) RAN.set(fam, (RAN.get(fam) || 0) + 1);
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${label}${detail ? `  ${detail}` : ''}`);
};
const need = (key, label) => { console.log(`SKIP  ${label} —— measured.json 缺 ${key}，先跑 node measure.mjs`); fail++; const fam = famOf(label); if (fam) RAN.set(fam, (RAN.get(fam) || 0) + 1); };

/* ══ 母體宣告（第 5 輪 D4-07①）════════════════════════════════════
   第 4 輪 reviewer 的裁定：meta-gate 要，但**不是「樣本數 > 0」** —— 那擋不住那一輪
   任何一發突變。真正漏掉的東西長這樣：G19b 量了 4 張板的開關，可是「深色 × ON」
   這一格**整個是空的**（畫面上根本沒有那張板），而 gate 印出來的是 PASS。
   一個 gate 如果沒有先說出「我應該看到哪些格」，它就只能證明「我看到的都合格」。

   所以每一條 gate 都要宣告它的母體：
     · 有笛卡兒積的（模式 × 狀態、外觀 × 尺寸 × 倍率…）→ pop() 宣告維度，缺格 FAIL 並印出缺哪一格
     · 沒有笛卡兒積的（母體就是全集：34 張板的每一個 gap、每一個文字節點…）→ NOPOP 具名登記理由
   MG1 再回頭驗三件事：跑過的家族有沒有宣告、宣告的格有沒有到齊、登記的理由有沒有對應到真的跑過的 gate。 */
const POPS = [];
const pop = (gate, dims, seen, why) => POPS.push({ gate, dims, seen: new Set(seen), why });
const cells = (dims) => Object.values(dims).reduce((acc, vals) => acc.flatMap((a) => vals.map((v) => (a ? `${a}|${v}` : String(v)))), ['']);
const NOPOP = {
  G1: '母體＝全部產物裡的每一個 gap／padding／margin 值（掃全集不抽樣），沒有維度可以交叉',
  G2: '母體＝全部產物裡出現過的每一個 font-size，同上',
  G3: '母體＝全部產物裡的每一個 opacity 使用點',
  G4: '母體＝每一張非交付板（朱的計數是逐板的全集）',
  G5: '母體＝畫面上每一個帶 inset 的使用點；兩族（可填／已鑲）各自的白名單本身就是它的維度宣告，已逐族印在斷言裡',
  G6: '母體＝全部產物的每一個文字節點（1800+ 個），逐節點量最不利點',
  G7: '母體＝每一張出現六位碼的板（票根與輸入格兩種正典各自逐板掃）',
  G8: '母體＝每一張流程板的最外層陶土區塊計數',
  G9: '母體＝畫面上每一道錯誤線',
  G10: '母體＝每一張流程板（呼吸帶與板高逐張量），交付板的排除清單印在斷言裡',
  G11: '母體＝三個具名分組裡的每一張板，排除的十張逐一列名（H1_EXCLUDED）',
  G13: '母體＝每一個文字區塊的末行',
  G14: '母體＝每一組核准↔拒絕、每一個底線連結',
  G15: 'Notes 宣稱與字標材質：母體＝Notes 上每一條「要有一張板畫出來」的宣稱，逐條列名在 claims 表裡',
  G16: '母體＝全部產物的原始碼（重複宣告、雙分號、未內插樣板語法都是全集掃描）',
  G17: '母體＝canvas.json 上的每一張板都要有一張 PNG，逐張比尺寸與內容指紋',
  G18: '母體＝tokens.mjs 的每一個 FIX／PERF 常數',
  G20: '母體＝canvas.json 上的每一則註記',
  G21: '母體＝每一張產物（都要蓋同一枚量測戳記）',
  G21b: '單一斷言：這一份量測是在哪一個根目錄上量的',
  G21c: '單一斷言：三方對帳有沒有真的跑過並留下憑證',
  G19: '母體＝畫面上每一個浮起面（唇邊逐個量）與每一列開關；沒有維度可以交叉（開關的四格母體宣告在 G19b）',
  G22: '母體＝畫面上每一個漸層使用點與每一種寫法（清冊本身就是全集）',
  G26: '暫停中（使用者否決字形 icon 概念）：母體＝掛著 data-veto 的那一張板，只剩「暫停有沒有被具名登記、板上有沒有說出來、恢復條件寫不寫得出來」三條 —— 恢復後改回笛卡兒積宣告',
  G26b: '母體＝落款印的八筆，逐筆對位（八筆就是全集，沒有可以交叉的第二個維度）；與 G26 一起暫停中',
  G26c: '母體＝驗收排上的每一格（三種外觀 × 四個尺寸，笛卡兒積宣告在 G26）；與 G26 一起暫停中',
  G25: '母體＝畫面上每一顆第三方品牌鍵與它的整個子樹',
  MG1: '它自己就是母體檢查，不能用自己宣告自己',
  MG2: '母體＝畫面上出現的每一個豁免標記 ∪ 登記簿上的每一筆（等式的兩邊都是全集）',
  MG3: '母體＝負面對照的樣本表，每一發都具名列出（見 selftest.mjs）',
  G34: '母體＝板級排除登記簿上的每一筆（登記簿本身就是全集），加上 verify／measure 兩份原始碼的全文掃描',
  G33: '母體＝字樣的那一份出處（來源檔＋描摹參數）與畫面上每一張帶字標的板，逐張比 path；④重跑一次描摹、⑤從同一份 path 算字距，兩者的母體都是那一份 d 的全部',
  G35: '母體＝**全部產物**裡「同一支筆」這個字串的每一次出現（凍結板上的逐一比對是否落在過期標記內，其餘板上一次都不准出現）',
  MG4: '母體＝gate 拿來做比較的每一條門檻，逐條列在 THRESHOLDS 登記簿上（登記簿本身就是母體宣告；MG4④ 反過來驗沒有死掉的登記）',
};

/* ══ G1  間距級距：gap ＋ padding ＋ margin 全部掃 ══════════════════
   第 2 輪只掃 gap（370 個），放走了 133 個級距外的 padding/margin。 */
{
  const AXV = new Set();
  for (const n of [...SIZES, 12, 18, 21, 25, 40, 56, 80]) { AXV.add(Math.round(n * AX)); AXV.add(Math.round(n * AX4)); }
  const allowed = new Set([0, ...GAPS, ...Object.values(FIX).map(Math.abs), ...AXV]);
  const bad = new Map();
  let total = 0, gapTotal = 0;
  const PROP = /(?:^|;|")\s*(gap|padding|margin|padding-top|padding-left|padding-bottom|padding-right|margin-top|margin-left|margin-bottom|margin-right):\s*([^;"]+)/g;
  for (const f of files) {
    for (const m of read(f).matchAll(PROP)) {
      const isGap = m[1] === 'gap';
      for (const tok of m[2].trim().split(/\s+/)) {
        const v = /^-?(\d+(?:\.\d+)?)px$/.exec(tok);
        if (!v) continue;
        total++; if (isGap) gapTotal++;
        if (!allowed.has(Math.abs(+v[1]))) bad.set(`${f}:${m[1]}:${tok}`, 1);
      }
    }
  }
  M.gapCount = gapTotal; M.padCount = total;
  ok(bad.size === 0, `G1 間距：${total} 個 gap/padding/margin 值（其中 gap ${gapTotal}）全部落在七階或 FIX 常數`,
    bad.size ? `違規 ${[...bad.keys()].slice(0, 10).join(' ')}${bad.size > 10 ? ` …共 ${bad.size}` : ''}` : '');
}

/* ══ G2  字級階數 ══════════════════════════════════════════════ */
{
  const derived = new Set();
  for (const n of [...SIZES, 12, 18, 21, 25, 40, 56, 80]) { derived.add(Math.round(n * AX)); derived.add(Math.round(n * AX4)); }
  const seen = new Set();
  for (const f of files) for (const m of read(f).matchAll(/font-size:(\d+)px/g)) seen.add(+m[1]);
  const bad = [...seen].filter((v) => !SIZES.includes(v) && !derived.has(v));
  const declared = [...seen].filter((v) => SIZES.includes(v)).sort((a, b) => b - a);
  M.sizesUsed = declared; M.axDerived = [...seen].filter((v) => !SIZES.includes(v)).sort((a, b) => b - a);
  ok(bad.length === 0, `G2 字級：只出現宣告的 ${declared.length} 階 [${declared}] ＋ AX 推導值 ${M.axDerived.length} 個`,
    bad.length ? `未宣告 ${bad.sort((a, b) => b - a)}` : '');
  ok(declared.length === SIZES.length, 'G2 字級：宣告的十階全部有用到，沒有虛報',
    declared.length !== SIZES.length ? `宣告但沒用到 ${SIZES.filter((s) => !declared.includes(s))}` : '');
}

/* ══ G3  透明度：只剩卡紙顆粒一處 ══════════════════════════════ */
{
  const hits = [];
  for (const f of files) {
    const s = read(f);
    for (const m of s.matchAll(/opacity:([.\d]+)/g)) {
      const ctx = s.slice(Math.max(0, m.index - 120), m.index);
      if (/\.g::after|stroke-opacity/.test(ctx + m[0])) continue;
      hits.push(`${f}:${m[1]}`);
    }
  }
  ok(hits.length === 0, 'G3 透明度：沒有任何文字或元件帶 opacity（卡紙顆粒與 stroke-opacity 除外）', hits.slice(0, 8).join(' '));
}

/* ══ G4  紅訊號：一張板最多兩處朱 ══════════════════════════════ */
{
  const rows = [];
  for (const f of files) {
    if (!inScope('G4', f)) continue;   // 排除清單與理由在 tokens.mjs 的 SCOPE 登記簿上（印在下面的斷言裡）
    /* 第 5 輪：票根刻度上的朱筆銷記不是「錯誤訊號」，是紅筆的另一個本業（劃掉）。
       它是**具名豁免**（tokens.mjs 的 EXEMPT：marker data-cancel／role stub／逐板列名／理由），
       MG2 會反過來驗「畫面上有的」與「登記簿上的」是同一個集合 ——
       所以這裡把它剝掉之前，它已經先被登記過一次了。 */
    const body = read(f).replace(/--ls-pen:[^;]+;/g, '').replace(/<svg[^>]*data-cancel="[^"]*"[\s\S]*?<\/svg>/g, '');
    const n = [...body.matchAll(new RegExp(T.light.pen, 'gi'))].length + [...body.matchAll(new RegExp(T.dark.pen, 'gi'))].length;
    if (n) rows.push([f, n]);
  }
  const bad = rows.filter(([, n]) => n > 2);
  ok(bad.length === 0, `G4 紅訊號：有朱的 ${rows.length} 張板，每張 ≤2 處`,
    bad.length ? bad.map(([f, n]) => `${f}=${n}`).join(' ') : rows.map(([f, n]) => `${f.replace('.dc.html','')}:${n}`).join(' '));
}

/* ══ G5  「凹＝可以填」：掃使用點的 computed box-shadow ══════════
   第 2 輪只 grep helper 定義，實測 49 個非可填元件帶 inset。 */
if (M.insetBad) {
  /* 第 2 輪 reviewer：「凹＝可填」的白名單一路漂移到八個角色，因為那八個其實不是同一件事。
     本輪拆兩族，各自一條斷言，而且再加一條「兩族的實測深度真的不同」——
     不然「兩族」只是兩個標籤。 */
  ok(M.insetBad.length === 0, `G5 凹的兩族：${M.insetTotal} 個帶 inset 的使用點，全部落在自己那一族的白名單上（可填 ${INSET_KEYS.fillable.join('／')}；已鑲 ${INSET_KEYS.mount.join('／')}）`,
    M.insetBad.length ? M.insetBad.slice(0, 6).join(' | ') : Object.entries(M.insetUse).map(([k, v]) => `${k}×${v}`).join(' '));
  if (M.insetDepth) {
    const dp = (k) => (M.insetDepth[k] || []);
    const fmin = Math.min(...dp('fillable')), mmax = Math.max(...dp('mount'));
    ok(dp('fillable').length > 0 && dp('mount').length > 0 && fmin > mmax,
      `G5 兩族的深度真的不同：可填 ${dp('fillable').length} 個（模糊半徑 ${fmin}px）比已鑲 ${dp('mount').length} 個（${mmax}px）深 —— 空的槽看得到深度，鑲好的東西是齊平的`,
      `fillable min ${fmin} / mount max ${mmax}`);
    ok(new Set(dp('fillable')).size === 1 && new Set(dp('mount')).size === 1,
      'G5 同一族只有一個深度：兩族各自的模糊半徑在全稿只出現一個值（第 2 輪同族內有 4／6／8 三種手寫深度）',
      `fillable ${[...new Set(dp('fillable'))].join('/')} · mount ${[...new Set(dp('mount'))].join('/')}`);
  } else need('insetDepth', 'G5 兩族深度');
  if (M.folds) {
    ok(M.folds.length >= 2 && M.folds.every((f) => f.n === 1 && f.blur === 0),
      `G5 摺邊不是凹：${M.folds.length} 個 fold（紙壓在照片上的裁邊）只有一層零模糊的受光邊，沒有槽 —— 它因此不進凹的白名單（第 2 輪它掛在 win/seam 底下，白名單多養了一個不是洞的角色）`,
      JSON.stringify(M.folds));
  } else need('folds', 'G5 摺邊');
  ok(!/inset/.test(/const raise = [\s\S]*?;\n/.exec(src)[0]),
    'G5 浮起只有兩層：raise() 的函式體裡沒有 inset（第三層 topLight 已移除）');
  ok(/border-bottom:\$\{FIX\.lip\}px/.test(src), 'G5 浮起保留 3pt 唇邊');
  ok(!/const flat =[\s\S]*?box-shadow/.test(src.slice(src.indexOf('const flat ='), src.indexOf('const noWt ='))), 'G5 平印：flat() 沒有 inset、沒有 box-shadow');
  ok(/const insetShadow[\s\S]{0,400}?inset 0 \$\{d\.edge\}px 0 \$\{t\.bevelTop\}/.test(src), 'G5 凹窗：insetShadow() 保留上緣內陰影（真凹沒有被動到）');
} else need('insetBad', 'G5 凹的白名單');

/* ══ G6  對比：節點級，全部 AAA，而且沒有字壓在照片上 ══════════
   這一稿每張紙都是漸層，所以「一個底色對一個字色」的算法已經不成立：
   G6 讀到的最低值是 measure 沿著每一行字上下緣取樣、取**最不利那一點**算出來的
   （見 G22②）。門檻仍然是 AAA。 */
if (M.contrastNodes) {
  ok(M.contrastFails.length === 0, `G6 對比：${M.contrastNodes} 個文字節點全部 ≥${CONTRAST.aaa}:1（以漸層最不利點計，最低 ${M.contrastMin} @ ${M.contrastWorst}）`,
    M.contrastFails.slice(0, 6).join(' | '));
  ok(M.textOverPhoto === 0, `G6 照片上文字：${M.textOverPhoto} 個（壓在照片上的對比無法定義，所以一個都不能有）`);
} else need('contrastNodes', 'G6 對比');

/* ══ G22  漸層（本輪新增；規則＝「每個漸層要有理由」＋「量不了就不准壓字」）══
   ① 可量性：只有 180deg 線性漸層量得出「字底下最不利的那一點」。斜的一律 FAIL。
   ② 最不利點：壓在漸層上的字，以取樣到的最低對比計，門檻 AAA。（數字由 G6 印）
   ③ 清冊：畫面上出現的每一種漸層，都必須登記在 tokens.mjs 的 GRAD_KEYS，
      而且它的**理由**與兩端 hex 印在 Tokens 板上 —— 沒印理由的漸層就是裝飾。
   ④ 鏡像：深色的兩端與淺色相反（seam 例外，理由印在板上）。
   ⑤ 顆粒容差：紙的顆粒是 multiply，會把底乘暗；以「最暗的那一格」重算，下限 6:1。 */
{
  const sheet = read('Tokens.dc.html');

  if (M.grad) {
    ok(M.grad.badDir === 0,
      `G22① 漸層可量性：${M.grad.total} 個漸層使用點全部是 180deg 垂直線性漸層（斜的量不出字底下最不利的那一點，所以不准壓字）`,
      (M.gradBad || []).slice(0, 4).join(' | '));
    ok(M.grad.textOn > 0,
      `G22② 最不利點：${M.grad.textOn} 個文字節點壓在漸層上，逐行取樣後最低 ${M.contrastMin}（${M.contrastWorst}），門檻 ${CONTRAST.aaa}`,
      M.grad.textOn === 0 ? '一個都沒有 —— 這張檢查沒在守東西' : '');
    ok((M.grainFails || []).length === 0,
      `G22⑤ 顆粒容差：以顆粒最暗的一格重算，最低 ${M.grainMin}（${M.grainWorst}），下限 ${CONTRAST.grain}`,
      (M.grainFails || []).slice(0, 4).join(' | '));

    /* 清冊：畫面上真的出現的每一種寫法，都要對得上 tokens.mjs 的某一個 key。
       比的是**解析後的色停**不是字串 —— Chrome 會把 180deg（＝預設方向）正規化掉，
       rgba 的小數寫法也和我們寫進 CSS 的不同；比字串會比出假的不一致。 */
    const canon = (css) => {
      const inner = css.slice(css.indexOf('(') + 1, css.lastIndexOf(')'));
      const parts = []; let depth = 0, cur = '';
      for (const ch of inner) {
        if (ch === '(') depth++;
        if (ch === ')') depth--;
        if (ch === ',' && depth === 0) { parts.push(cur.trim()); cur = ''; continue; }
        cur += ch;
      }
      parts.push(cur.trim());
      const out = [];
      for (const raw of parts) {
        let p = raw;
        const hx = /^#([0-9A-Fa-f]{6})/.exec(p);
        if (hx) p = p.replace(hx[0], `rgb(${parseInt(hx[1].slice(0, 2), 16)},${parseInt(hx[1].slice(2, 4), 16)},${parseInt(hx[1].slice(4, 6), 16)})`);
        const c = /rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:[,\s/]+([\d.]+))?\s*\)/.exec(p);
        if (!c) continue;
        const a = c[4] === undefined ? 1 : +c[4];
        const pos = /([\d.]+)(%|px)/.exec(p.slice(c[0].length));
        out.push(`${+c[1]},${+c[2]},${+c[3]},${a}@${pos ? pos[1] + pos[2] : '-'}`);
      }
      return (/^repeating-/.test(css) ? 'rep:' : '') + out.join('|');
    };
    const legal = new Map();
    for (const th of [T.light, T.dark]) for (const k of GRAD_KEYS) legal.set(canon(gradCss(th, k)), k);
    /* 明暗漸層逐個比色停；騎縫線（repeating）是圖樣，另外一條規則驗：
       只有兩種顏色（該主題的 edge 與全透明）、6/12px 的節拍，而且只能是它。 */
    const shading = (M.grad.css || []).filter((c) => !/^repeating-/.test(c));
    const patterns = (M.grad.css || []).filter((c) => /^repeating-/.test(c));
    const seen = shading.map(canon);
    const stray = seen.filter((c) => !legal.has(c));
    ok(stray.length === 0,
      `G22③ 漸層清冊：畫面上出現的 ${seen.length} 種明暗漸層全部出自 tokens.mjs 的 ${GRAD_KEYS.length} 個 key，共 ${new Set(seen.map((c) => legal.get(c))).size} 個 key 真的用到`,
      stray.slice(0, 3).join(' | '));
    /* 第 5 輪 D4-04：騎縫線已經不是背景漸層了（它是遮罩挖出來的洞，見 G27），
       所以「唯一的方向例外」這條豁免整個消失 —— 畫面上**不准再有任何 repeating 背景漸層**。
       這是一條比上一版更緊的規則：上一版允許一種橫向圖樣，這一版一種都不允許。 */
    ok(patterns.length === 0,
      `G22③ 沒有橫向的背景圖樣了：騎縫線改成遮罩挖出來的洞（G27），所以「唯一的方向例外」這條豁免自己消失 —— repeating 背景漸層 ${patterns.length} 種`,
      patterns.slice(0, 2).join(' | '));
  } else need('grad', 'G22 漸層');

  // 理由與端點都要印在 Tokens 板上：沒印理由的漸層就是裝飾，不是設計
  {
    const missWhy = [], missHex = [];
    if (!sheet.includes(PERF_WHY)) missWhy.push('perf（騎縫線的理由）');
    for (const k of GRAD_KEYS) {
      if (!sheet.includes(GRAD_WHY[k])) missWhy.push(k);
      for (const th of [T.light, T.dark]) {
        for (const [hex, pos] of th.grad[k]) if (!sheet.includes(`${hex} ${pos}%`)) missHex.push(`${k}:${hex}@${pos}%`);
      }
    }
    ok(missWhy.length === 0 && missHex.length === 0,
      `G22③ 漸層理由：${GRAD_KEYS.length} 種漸層的理由與兩端 hex（淺／深各一組）全部印在 Tokens 板上，另加騎縫線（不是漸層，理由另印）`,
      [...missWhy.map((k) => `${k} 沒印理由`), ...missHex.map((s) => `${s} 沒印`)].join(' · '));
    const missNo = Object.values(NO_GRAD_WHY).filter((v) => !sheet.includes(v));
    ok(missNo.length === 0,
      `G22③ 刻意沒有漸層的 ${Object.keys(NO_GRAD_WHY).length} 種表面（平印／載入中／品牌鍵），理由也印在板上`,
      missNo.length ? '有理由沒印出來' : '');
  }

  // 深色＝鏡像：每一種漸層的兩端在深色是反過來的（seam 例外）
  {
    const L6 = (h) => { const m = /#([0-9A-Fa-f]{6})/.exec(h); if (!m) return null;
      const c = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255)
        .map((v) => (v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4));
      return .2126 * c[0] + .7152 * c[1] + .0722 * c[2]; };
    const bad = [];
    for (const k of GRAD_KEYS) {
      const l = [T.light.grad[k].at(0)[0], T.light.grad[k].at(-1)[0]].map(L6);
      const d = [T.dark.grad[k].at(0)[0], T.dark.grad[k].at(-1)[0]].map(L6);
      if (l[0] === null || d[0] === null) continue;            // seam 是 rgba，本來就不比明度
      const sl = Math.sign(l[0] - l[1]), sd = Math.sign(d[0] - d[1]);
      if (sl !== -sd) bad.push(`${k} 淺色 ${sl > 0 ? '上亮' : '上暗'}、深色 ${sd > 0 ? '上亮' : '上暗'}`);
    }
    ok(bad.length === 0,
      `G22④ 深色是鏡像：${GRAD_KEYS.length - 1} 種帶明度的漸層，深色兩端與淺色相反（seam 是 rgba 的「有無」漸層，由幾何決定、不隨光源翻面）`,
      bad.join(' · '));
  }
}

/* ══ G23  色彩語意（第 2 輪新增）════════════════════════════════
   第 1 輪的病：管線守著「漸層有沒有登記、字壓在上面對比夠不夠」，卻沒有一項在守
   **色彩自己說的那套意思**。證據是 reviewer 的兩發突變全綠通過：
     M1  把四階台紙的溫度極性整個倒轉（凹變暖、手澤變冷）→ 71 項全綠
     M2b 把台紙漸層加到平印面上（違反「平印不接光」）→ 全綠，而且 G22③ 自己印 PASS
   兩發都不是漏抓，是**根本沒有那條檢查**。G23 補四條：
     ① 溫度階梯：四階與染料相對台紙的 LCh 色相角 ＝ 宣告的 TEMP（淺深各驗，容差 ±3°）；
        再加漸層層級的排序 h(win) < h(paper) < h(win3/face) 與三個實測下限。
        **深色套同一條** —— 第 1 輪的深色四階全落 6.5° 內，這一條會直接 FAIL；
        本輪的深色是「固定 L*、只轉色相」修出來的，所以對比一位元都沒動。
     ② 平印不接光：掃平印**使用點與它自己的皮**的 computed background-image，
        出現漸層一律 FAIL，除非掛牌且是號碼帶（stub*）或騎縫線（perf）。
     ③ L* 與 C* 階梯：淺色 C* 隨老化上升（紙會染上顏色）、深色 C* 隨 L* 上升
        （暗處的彩度被明度綁住）—— 兩條方向相反的階梯**各自**要成立。
     ④ 光與時間分家：光的漸層只改明度（|Δh| ≤ LIGHT_DH）、時間的漸層會改色相
        （≥TIME_DH）；而且只有號碼帶是三色停的非等速漸層，褪色階三個量單調衰減。 */
{
  const modes = [['淺色', T.light], ['深色', T.dark]];
  const gm = (th, k) => { const s = th.grad[k].filter(([c]) => /^#/.test(c)); const a = lch(s[0][0]), b = lch(s.at(-1)[0]); return a.h + dHue(b.h, a.h) / 2; };

  // ① 溫度：宣告的 TEMP 對實測的 LCh 色相角
  {
    const bad = [], seen = [];
    for (const [name, th] of modes) {
      const base = lch(th.board).h;
      for (const [k, want] of Object.entries(TEMP)) {
        const got = dHue(lch(th[k]).h, base), de = hueDE(th, k);
        seen.push(`${name}${k} ${got > 0 ? '+' : ''}${got.toFixed(1)}°／ΔE ${de.toFixed(2)}`);
        if (Math.abs(got - want) > TEMP_TOL) bad.push(`${name} ${k} 實測 ${got.toFixed(1)}°、宣告 ${want}°（容差 ±${TEMP_TOL}）`);
        /* 第 3 輪 R1：角度在低彩度上等於沒有溫度。淺色 lit 宣告 +6.0°、實測 +6.05°，
           這一項第 2 輪一路綠燈 —— 可是它的 C* 只有 4.2，那 6° 單獨貢獻的 ΔE 是 0.51，
           在 JND（≈1）之下：「四階有溫度層次」在最亮的那一階上是量得出來的假。
           所以門檻改成 ΔE：固定 L* 與 C*、只把色相轉回台紙本體，量兩者的距離。 */
        if (de < HUE_DE_MIN) bad.push(`${name} ${k} 的色相位移單獨只貢獻 ΔE ${de.toFixed(2)}（門檻 ${HUE_DE_MIN}，JND 以下＝看不見的溫度）`);
      }
    }
    ok(bad.length === 0,
      `G23① 溫度階梯：四階台紙與染料相對台紙本體的色相角等於宣告的 TEMP（±${TEMP_TOL}°），而且每一階的色相位移**單獨**貢獻 ΔE ≥ ${HUE_DE_MIN}（${seen.join(' · ')}）`,
      bad.join(' · '));
  }

  // ①b 漸層層級的排序與下限（凹偏冷 < 台紙 < 次要面偏暖）
  {
    const bad = [], seen = [];
    for (const [name, th] of modes) {
      const p = gm(th, 'paper'), w = dHue(gm(th, 'win'), p), w3 = dHue(gm(th, 'win3'), p), f = dHue(gm(th, 'face'), p);
      seen.push(`${name} win ${w.toFixed(1)}° / win3 +${w3.toFixed(1)}° / face +${f.toFixed(1)}°`);
      if (!(w < 0 && w3 > 0 && f > 0)) bad.push(`${name} 排序破了：win ${w.toFixed(1)}、win3 ${w3.toFixed(1)}、face ${f.toFixed(1)}（要 win < 台紙 < win3/face）`);
      if (-w < HUE_MIN.cool) bad.push(`${name} 凹只比台紙冷 ${(-w).toFixed(1)}°，下限 ${HUE_MIN.cool}°`);
      if (Math.min(w3, f) < HUE_MIN.warm) bad.push(`${name} 次要面只比台紙暖 ${Math.min(w3, f).toFixed(1)}°，下限 ${HUE_MIN.warm}°`);
      if (w3 - w < HUE_MIN.span) bad.push(`${name} 四階溫度跨距只有 ${(w3 - w).toFixed(1)}°，下限 ${HUE_MIN.span}°（跨距太小＝「一個色相的四個明度」，正是這一稿說自己不是的東西）`);
    }
    ok(bad.length === 0, `G23① 溫度排序：凹偏冷 < 台紙 < 次要面偏暖，兩個模式都成立且跨距達標（${seen.join('；')}）`, bad.join(' · '));
  }

  // ② 平印不接光（掃使用點的 computed background）
  if (M.flatBad) {
    ok(M.flatBad.length === 0 && !(M.flatOk || []).some((x) => /perf/.test(x)),
      `G23② 平印不接光：${files.length} 張板的平印使用點（連同它自己的皮）上，只有掛牌的號碼帶與騎縫線帶漸層 —— 實際掛出來的 ${(M.flatOk || []).length} 處`,
      M.flatBad.slice(0, 5).join(' | '));
  } else need('flatBad', 'G23② 平印不接光');

  // ③ L* 與 C* 的兩條階梯
  {
    const bad = [], seen = [];
    const Lv = (th, k) => lch(th[k]).L, Cv = (th, k) => lch(th[k]).C;
    for (const [name, th] of modes) {
      // 跨模式不變式：亮面永遠比台紙亮；凹永遠比台紙暗（洞就是洞，不隨光源翻面）
      if (!(Lv(th, 'lit') > Lv(th, 'board'))) bad.push(`${name} 亮面沒有比台紙亮`);
      if (!(Lv(th, 'board2') < Lv(th, 'board'))) bad.push(`${name} 凹沒有比台紙暗（陰影不隨光源翻面）`);
      if (Math.abs(Lv(th, 'board3') - Lv(th, 'board')) < 5) bad.push(`${name} 次要面與台紙的明度只差 ${Math.abs(Lv(th, 'board3') - Lv(th, 'board')).toFixed(1)} L*，下限 5`);
      seen.push(`${name} L* lit ${Lv(th, 'lit').toFixed(1)} / board ${Lv(th, 'board').toFixed(1)} / b2 ${Lv(th, 'board2').toFixed(1)} / b3 ${Lv(th, 'board3').toFixed(1)}`);
    }
    // 次要面是浮起面，它與台紙的明度方向在兩個模式必須相反（深色的光從下面來）
    const s = (th) => Math.sign(Lv(th, 'board3') - Lv(th, 'board'));
    if (s(T.light) === s(T.dark)) bad.push('次要面與台紙的明度方向兩個模式同號 —— 深色沒有鏡像');
    // 淺色：越老彩度越高（紙會染上顏色）；深色：彩度隨明度（暗處畫不出高彩度）
    const asc = (arr) => arr.every((v, i) => i === 0 || v > arr[i - 1]);
    const cl = ['lit', 'board', 'board2', 'board3'].map((k) => Cv(T.light, k));
    const cd = ['board2', 'board', 'board3', 'lit'].map((k) => Cv(T.dark, k));
    if (!asc(cl)) bad.push(`淺色 C* 不是隨老化遞增：${cl.map((v) => v.toFixed(1)).join(' → ')}`);
    if (!asc(cd)) bad.push(`深色 C* 不是隨 L* 遞增：${cd.map((v) => v.toFixed(1)).join(' → ')}`);
    ok(bad.length === 0,
      `G23③ 明度與彩度階梯：${seen.join('；')}；淺色 C* 隨老化遞增 ${cl.map((v) => v.toFixed(1)).join('→')}、深色 C* 隨明度遞增 ${cd.map((v) => v.toFixed(1)).join('→')}（兩條方向相反的階梯各自成立）`,
      bad.join(' · '));
  }

  // ④ 光與時間分家 ＋ 褪色階單調衰減
  {
    const bad = [], seen = [];
    const dh = (th, k) => Math.abs(dHue(lch(th.grad[k].at(0)[0]).h, lch(th.grad[k].at(-1)[0]).h));
    for (const [name, th] of modes) {
      for (const k of LIGHT_KEYS) {
        if (dh(th, k) > LIGHT_DH) bad.push(`${name} ${k} 是「光」，兩端色相差 ${dh(th, k).toFixed(1)}° > ${LIGHT_DH}°（光只改明度）`);
      }
      for (const k of ['paper', 'stub3']) {
        if (dh(th, k) < TIME_DH) bad.push(`${name} ${k} 是「時間」，兩端色相差只有 ${dh(th, k).toFixed(1)}° < ${TIME_DH}°（時間會改色相，不然它就只是一支光）`);
      }
      seen.push(`${name} 光最大 ${Math.max(...LIGHT_KEYS.map((k) => dh(th, k))).toFixed(1)}° / 時間最小 ${Math.min(dh(th, 'paper'), dh(th, 'stub3')).toFixed(1)}°`);
      // 停點形狀：只有號碼帶是三色停、非等速
      for (const k of GRAD_KEYS) {
        const st = th.grad[k], isStub = STUB_KEYS.includes(k);
        if (!isStub && !(st.length === 2 && st[0][1] === 0 && st[1][1] === 100)) bad.push(`${name} ${k} 不是等速的兩色停（光是等速的）`);
        if (isStub && !(st.length === 3 && st[1][1] === STUB_KNEE)) bad.push(`${name} ${k} 不是「三色停、膝點 ${STUB_KNEE}%」`);
        if (isStub) {
          const r = dE(st[0][0], st[1][0]) / Math.max(.01, dE(st[1][0], st[2][0]));
          if (r < 3) bad.push(`${name} ${k} 的膝點沒有邊緣加權：0→${STUB_KNEE}% 與 ${STUB_KNEE}→100% 的 ΔE 只差 ${r.toFixed(1)} 倍，下限 3`);
        }
      }
      // 褪色階：三個量一起單調衰減，褪完了就沒有方向
      const q = (k) => { const s = th.grad[k]; return { h: dh(th, k), l: Math.abs(lch(s[0][0]).L - lch(s[2][0]).L), c: (lch(s[0][0]).C + lch(s[2][0]).C) / 2 }; };
      const seq = STUB_KEYS.map(q);
      for (const key of ['h', 'l', 'c']) {
        const v = seq.map((x) => x[key]);
        if (!v.every((x, i) => i === 0 || x < v[i - 1])) bad.push(`${name} 褪色階的 ${key} 沒有單調衰減：${v.map((x) => x.toFixed(2)).join(' → ')}`);
      }
    }
    ok(bad.length === 0,
      `G23④ 光與時間分家：${seen.join('；')}；${GRAD_KEYS.length - STUB_KEYS.length} 種等速兩色停 vs ${STUB_KEYS.length} 階號碼帶（三色停、膝點 ${STUB_KNEE}%、邊緣加權），褪色階的色相位移／明度差／彩度三個量一起單調衰減到零`,
      bad.join(' · '));
  }

  // ⑤ 褪色階 ＝ 剩餘次數：板上畫的階數要等於板上寫的次數（設計自己的對帳）
  {
    /* 第 3 輪：票根多了三格刻度（把「褪色」變成一張畫面裡就讀得出來的比較），
       所以這一條也一起長大 —— 現在對帳的是**三件事**：
         ① 號碼帶（data-band="code"）畫的階數
         ② 三格刻度裡「還沒褪」的格數
         ③ 票根上印出來的那句話（N 次／用完了）
       三者必須是同一個數。改了文案不改階數會 FAIL，改了刻度不改文案也會 FAIL。 */
    const bad = [], seen = [];
    for (const f of files) {
      const s = read(f);
      const band = [...new Set([...s.matchAll(/data-grad="stub(\d)" data-band="code"/g)].map((m) => +m[1]))];
      const scale = [...s.matchAll(/data-scale="(\d|blank)"/g)].map((m) => m[1]);
      const say = [...s.matchAll(/還可以用 (\d) 次|(這組號碼用完了)/g)].map((m) => (m[2] ? 0 : +m[1]));
      if (!band.length && !scale.length && !say.length) continue;
      if (!inScope('G23-stub', f)) { seen.push(`${f.replace('.dc.html', '')} 印了全部 ${[...new Set([...s.matchAll(/data-grad="stub(\d)"/g)].map((m) => +m[1]))].length} 階`); continue; }
      const uniq = [...new Set([...band, ...scale.filter((x) => x !== 'blank').map(Number), ...say])];
      const blanks = scale.filter((x) => x === 'blank').length;
      if (!band.length && blanks) { seen.push(`${f.replace('.dc.html', '')} 空票根（刻度 ${blanks} 組全空、沒有褪色漸層）`); continue; }
      if (uniq.length !== 1) bad.push(`${f} 號碼帶 stub${band.join('/')}、刻度 ${scale.join('/')}、文案 ${say.join('/')} —— 三者不同`);
      else seen.push(`${f.replace('.dc.html', '')} ${uniq[0]}`);
    }
    ok(bad.length === 0,
      `G23⑤ 褪色階＝剩餘次數：${seen.length} 張有票根的板，號碼帶的階數＝三格刻度剩下的格數＝票根上印的那句話（${seen.join(' · ')}）`,
      bad.join(' · '));
    /* 三格刻度自己的規則（第 5 輪 D4-01 改）：
         · 還沒用的格 ＝ **當前階**（stub{剩餘次數}）—— 第 4 輪這裡永遠畫 stub3，
           所以號碼帶走到第幾階從來沒有出現在刻度上（五態裡三態逐格 ΔE=0）
         · 用掉的格 ＝ 褪到底（stub0）**而且蓋一道朱筆銷記**
       這一條守的是「刻度是這組碼的資料，不是裝飾」。 */
    {
      const wrong = [];
      for (const f of files) {
        if (!inScope('G23-scale', f)) continue;
        const s2 = read(f);
        for (const m of s2.matchAll(/data-scale="(\d)"[\s\S]*?<\/span>\s*<\/span>/g)) {
          const n = +m[1];
          const left = [...m[0].matchAll(new RegExp(`data-cell="left" data-grad="stub${n}"`, 'g'))].length;
          const spent = [...m[0].matchAll(/data-cell="spent" data-grad="stub0"/g)].length;
          const marks = [...m[0].matchAll(/data-cancel="stub"/g)].length;
          if (left !== n || left + spent !== 3 || marks !== spent) {
            wrong.push(`${f} 刻度寫 ${m[1]}，實際 ${left} 格畫當前階 stub${n}＋${spent} 格褪完＋${marks} 道銷記`);
          }
        }
      }
      ok(wrong.length === 0,
        'G23⑤b 三格刻度：還沒用的格畫**當前階**（與號碼帶同一支漸層）、用掉的每一格褪到底並蓋一道朱筆銷記，三格不多不少（第 4 輪未用格永遠畫 stub3，等於刻度上看不到帶子走到哪一階）',
        wrong.join(' · '));
    }
  }

  /* ⑥ 朱是筆不是紙（第 6 輪 D5-03）──────────────────────────────────
     第 5 輪 reviewer：深色的朱比淺色的朱**往暖轉 +17.94°**，而全稿四階台紙在深色下
     一致往冷轉 −19°～−21° —— 一支顏料在同一份設計裡往兩個相反的方向跑，
     而且它不在 G23① 的母體裡（TEMP 只有四階台紙），所以沒有任何一條 gate 看得到。
     表態：**朱不加入台紙那條規則，因為它不是紙**。紙會因為時間與光改變顏色；
     筆的顏料不會 —— 白天寫的紅字與晚上寫的紅字是同一支筆。
     三個斷言把這句話變成可否證的：色相同一個角、亮度是被對比逼的、彩度是被色域夾的。 */
  {
    const pl = lch(T.light.pen), pd = lch(T.dark.pen);
    const dh = Math.abs(dHue(pd.h, pl.h));
    ok(dh <= PEN_DH,
      `G23⑥ 朱是筆不是紙：深色與淺色的朱是**同一個色相角**（實測差 ${dh.toFixed(2)}°，上限 ${PEN_DH}°）—— 四階台紙在深色下往冷轉 ${Math.abs(dHue(lch(T.dark.board).h, lch(T.light.board).h)).toFixed(1)}°，朱刻意不跟著轉，因為顏料不會因為天黑而變色`,
      `Δh ${dh.toFixed(2)}° > ${PEN_DH}°（第 5 輪是 +17.94°，方向還與台紙相反）`);
    /* 亮度為什麼一定要動：深底上要維持 AAA。這一條量的是「不動會怎樣」——
       把淺色的朱原封放到深色的四階台紙上，對比會掉到多少。 */
    const worstLight = Math.min(...['board', 'board2', 'board3', 'lit'].map((k) => crHex(T.light.pen, T.dark[k])));
    const worstDark = Math.min(...['board', 'board2', 'board3', 'lit'].map((k) => crHex(T.dark.pen, T.dark[k])));
    ok(worstLight < CONTRAST.aaa && worstDark >= CONTRAST.aaa,
      `G23⑥ 朱在深色變亮是被對比逼的：淺色那支朱原封放到深色台紙上只有 ${worstLight.toFixed(2)}:1（AAA ${CONTRAST.aaa} 過不了），改亮之後對四階實測最低 ${worstDark.toFixed(2)}:1`,
      `淺 ${worstLight.toFixed(2)} / 深 ${worstDark.toFixed(2)}`);
    /* 彩度為什麼掉：在深色朱的 L* 上，這個色相角的 sRGB 可表示彩度就到頂了。
       掃一遍找出上限，斷言「我們用的就是那個上限」——不是我們選擇讓它變淡。 */
    let capC = 0;
    for (let c = 0; c <= 60; c += 0.5) {
      const hx = lchHex(pd.L, c, pl.h), b = lch(hx);
      if (Math.abs(dHue(b.h, pl.h)) < 1 && Math.abs(b.C - c) < 0.6) capC = c;
    }
    ok(Math.abs(pd.C - capC) <= 1,
      `G23⑥ 朱在深色變淡是被色域夾的：L*${pd.L.toFixed(1)}、色相 ${pl.h.toFixed(1)}° 上，sRGB 的可表示彩度上限掃出來是 ${capC}，我們用的是 ${pd.C.toFixed(2)} —— 貼著上限，不是選擇讓它變淡（淺色的朱在 L*${pl.L.toFixed(1)} 上可以到 ${pl.C.toFixed(2)}）`,
      `實際 ${pd.C.toFixed(2)} vs 掃出來的上限 ${capC}`);
  }
}

/* ══ G24  光的方向（第 3 輪新增）════════════════════════════════
   第 2 輪 reviewer 的 M3 突變：把 87 個 inset 從凹翻成凸 —— 71 項 gate 全綠。
   原因是 G5 只做**字串比對**（「有沒有 inset」「helper 定義裡有沒有那一段」），
   沒有一項在問「光從哪一邊來」。而且管線自己也有同一個病的真實版本：
   深色的 bevelTop／bevelBot 沒有鏡像，同一個元件上兩個互相牴觸的光源，
   而且錯的那一支振幅是對的那一支的三倍。

   這一條驗的是**顏色的明度**不是字串：measure 把每一層陰影的顏色疊到元件自己的
   底色上算相對亮度 Y，再比上下緣。三個子句：
     ① 凹：淺色（dir=+1）上暗下亮、深色（dir=−1）上亮下暗；
     ② 有模糊的那一層（凹的柔影／浮起的落影）：y 位移的正負號 ＝ dir；
     ③ 具名豁免只有兩種：系統 chrome（[data-sys]）與幾何投影（[data-light="geometry"]）。
   ①②在 measure 端就判完了（那裡才有 computed style），這裡驗結論與涵蓋率。 */
if (M.light) {
  const seen = M.light.seen || [], bad = M.light.bad || [];
  ok(bad.length === 0,
    `G24 光的方向：${seen.length} 個帶上下緣的表面，受光緣與背光緣的實測相對亮度都與該模式的光源方向一致（淺色光從上、深色光從下），有模糊的陰影層位移正負號也都等於 dir`,
    bad.slice(0, 6).join(' | '));
  const dl = seen.filter((x) => x.dir < 0), lt = seen.filter((x) => x.dir > 0);
  ok(dl.length >= 8 && lt.length >= 20,
    `G24 兩個模式都被涵蓋：淺色 ${lt.length} 個使用點、深色 ${dl.length} 個 —— 深色不是「沒有樣本所以沒 FAIL」`,
    `light ${lt.length} / dark ${dl.length}`);
  /* 極性是推出來的，不是兩邊各寫一次（tokens.mjs 由 dir 生出 bevelTop／bevelBot）。
     這一條擋的是「有人回頭把其中一邊硬寫死」。 */
  ok(/th\.bevelTop = th\.dir > 0 \? th\.bevelDark : th\.bevelLit/.test(readFileSync(at('tokens.mjs'), 'utf8')),
    'G24 位置別名是推導的：bevelTop／bevelBot 由 dir 從 bevelLit／bevelDark 生出來，不是兩個模式各寫一次（第 2 輪就是各寫一次，深色那一份忘了翻）');
  const dirs = [...(readFileSync(at('tokens.mjs'), 'utf8').matchAll(/dir: ([+-]\d)/g))].map((m) => +m[1]);
  ok(dirs.join() === '1,-1', `G24 兩個模式各宣告一次光源方向：淺色 ${dirs[0]}（上）、深色 ${dirs[1]}（下）`, dirs.join('/'));
} else need('light', 'G24 光的方向');

/* ══ G25  品牌鍵不接光（第 3 輪新增）════════════════════════════
   第 2 輪 reviewer 的 M4c 突變：把漸層貼到 Google 鍵上 —— 全綠。
   「兩顆鍵不加漸層、不加唇邊、只借幾何」這條規則只寫在 Tokens 板的散文裡，
   零個 gate 在掃它。這一條掃 [data-brand] **與它整個子樹**的 computed 裝飾：
   背景圖（漸層）、box-shadow、text-shadow 一律 FAIL；描邊只准品牌規範指定的那一種。
   它在本輪一開始就先咬到我們自己：兩顆鍵原本都掛著我們的 lift 落影。 */
if (M.brandBad) {
  ok(M.brandBad.length === 0,
    `G25 品牌鍵不接光：${(M.brand || []).length} 顆第三方登入鍵（與它們的子樹）上，沒有任何一處我們的裝飾 —— 沒有漸層、沒有落影、沒有壓印、描邊只有它們自己規範的那一道`,
    M.brandBad.slice(0, 6).join(' | '));
  ok((M.brand || []).length >= 8, `G25 涵蓋率：${(M.brand || []).length} 顆鍵被掃到（歡迎頁三張＋AX5 壓力板，各 Apple/Google 兩顆）`);
  // 官方四色 G 是商標，色值不可被我們的色階「順手」改掉
  const g4 = ['#EA4335', '#4285F4', '#FBBC05', '#34A853'];
  const miss = g4.filter((c) => !src.includes(c));
  ok(miss.length === 0, `G25 Google 標誌的官方四色原封不動（${g4.join(' ')}）`, miss.join(' '));
} else need('brandBad', 'G25 品牌鍵');

/* ══ G26  圖示在實際尺寸讀不讀得出來（第 3 輪新增；reviewer 已裁規格）══
   第 2 輪的 AppIcon 板自己寫著「20pt 讀不讀得出來是目視項，第 3 輪要變成量得出來的」。
   reviewer 量了：20pt 最細筆畫 0.44 裝置像素、墨覆蓋 7.63% —— 物理上讀不出來。
   規格（reviewer 裁定三條，第四條是設計自己加嚴的）：
     ① 最細筆畫 ≥1.5 裝置像素   ② 墨覆蓋率 ≥12%   ③ 前景對比 ≥3:1
     ④ 反白 p05 ≥1 裝置像素（自己加的：筆畫夠粗但反白塞死，字一樣是一團墨）
   三種外觀（Light／Dark／Tinted）× 四個尺寸 × @2x/@3x 全部要過。
   Tinted 的底是官方中灰玻璃（取樣 kit-AppIcons 第三排的眾數像素），不是純黑 ——
   黑底會讓任何白色前景都好看，等於沒有驗。
   數字不是板上手打的：icon.mjs 把 1024 母稿真的光柵化（4×4 超取樣）算出來，
   板上印的與這裡判的是同一支函式。

   ══ 第 6 輪：整族暫停（使用者裁決）════════════════════════════════
   使用者於 2026-08-23 否決了「app icon ＝ 一個字」這個**概念**（不是筆觸、不是尺寸）。
   G26／G26b／G26c 量的全部是「那顆落款印讀不讀得出來」—— 而那顆印已經不是要交的東西。
   讓它們繼續綠著會製造一種假象：這張板還在被守。所以三族在 AppIcon 板上暫停，
   而**暫停本身是一條斷言**：豁免要在具名登記簿上（MG2 的等式兩邊都咬）、
   板上要自己說出來、恢復條件要寫得出來。刪掉登記簿那一筆，三族立刻自動回來。 */
const ICON_SUSPEND = EXEMPT.find((e) => e.marker === 'data-veto' && e.gate === 'G26');
if (ICON_SUSPEND) {
  const sheet26 = read('AppIcon.dc.html');
  const seen = (M.exemptSeen || []).filter((e) => e.marker === 'data-veto');
  /* 三條斷言各掛在一族的名下（G26／G26b／G26c），所以三族都還「跑過」——
     暫停不是消失：MG1 仍然看得到它們，母體宣告仍然要對得上。 */
  ok(seen.length === ICON_SUSPEND.files.length && ICON_SUSPEND.files.every((f) => seen.some((s) => s.file === f)),
    `G26 暫停（不是通過）：AppIcon 板的圖示概念經使用者否決，三族在這張板上停跑 —— 豁免登記在具名清單上（${ICON_SUSPEND.marker}="${ICON_SUSPEND.role}"→${ICON_SUSPEND.gate}），畫面上量到 ${seen.length} 個使用點`,
    `登記 ${ICON_SUSPEND.files.join('/')} vs 畫面 ${seen.map((s) => s.file).join('/') || '（一個都沒有 —— 板上沒有標記，等於沒人知道它被停了）'}`);
  ok(/這張板的概念已被否決/.test(sheet26) && /外部 icon 素材/.test(sheet26),
    'G26b 暫停要印在板上：被否決的板必須自己說出來，而且說得出「否決的是什麼」與「接下來會發生什麼」—— 只寫在登記簿裡的暫停，看板的人不會知道',
    'AppIcon 板上找不到否決說明');
  ok(ICON_SUSPEND.why.length >= 80 && /恢復條件/.test(ICON_SUSPEND.why),
    'G26c 暫停寫得出恢復條件：登記簿那一筆必須說明「什麼情況下這一筆會被刪掉」—— 沒有出口的暫停就是永久關掉一族 gate',
    ICON_SUSPEND.why.slice(0, 40));
} else {
  const R26 = Icon.RULE;
  const cs = Icon.strokeStats(Icon.SEAL), ws = Icon.strokeStats(Icon.WRITTEN);
  ok(cs.median >= 90 && cs.min >= 45,
    `G26 母稿筆寬：1024 母稿上中位筆畫 ${cs.median.toFixed(1)}px（門檻 90）、最細 ${cs.min.toFixed(1)}px（門檻 45）—— 刻的那支筆是寫的那支的 ${(cs.median / ws.median).toFixed(2)} 倍（寫的中位 ${ws.median.toFixed(1)}／最細 ${ws.min.toFixed(1)}）`,
    `median ${cs.median.toFixed(1)} / min ${cs.min.toFixed(1)}`);
  const looks = {
    淺色: { fg: T.light.ink, bg: T.light.grad.paper.map(([c]) => c) },
    深色: { fg: T.dark.ink, bg: T.dark.grad.paper.map(([c]) => c) },
    Tinted: { fg: Icon.TINT_FG, bg: [Icon.TINT_BASE] },
  };
  const bad = [], rows = [];
  for (const [name, look] of Object.entries(looks)) {
    // 有漸層的底：對比量在最不利的那一端（與 G22② 同一條規則）
    const worst = look.bg.reduce((a, b) => (Icon.contrast(Icon.rgbOf(look.fg), Icon.rgbOf(b)) < Icon.contrast(Icon.rgbOf(look.fg), Icon.rgbOf(a)) ? b : a));
    for (const [pt] of Icon.SIZES) for (const sc of Icon.SCALES) {
      const m = Icon.measureAt(pt, sc, { fg: look.fg, bg: worst });
      const why = [];
      if (m.minStrokeDev < R26.minStrokeDev) why.push(`最細筆畫 ${m.minStrokeDev.toFixed(2)} 裝置像素`);
      if (m.coverage < R26.coverage) why.push(`墨覆蓋 ${(m.coverage * 100).toFixed(2)}%`);
      if (m.contrast < R26.contrast) why.push(`前景對比 ${m.contrast.toFixed(2)}:1（底 ${worst}）`);
      if (m.counterDev < R26.counterDev) why.push(`反白 p05 ${m.counterDev}`);
      if (why.length) bad.push(`${name} ${pt}pt@${sc}x：${why.join('、')}`);
      rows.push(Object.assign(m, { look: name }));
    }
  }
  const mins = (k) => Math.min(...rows.map((r) => r[k]));
  ok(bad.length === 0,
    `G26 圖示最小尺寸：${Object.keys(looks).length} 種外觀 × ${Icon.SIZES.length} 個尺寸 × ${Icon.SCALES.length} 個倍率＝${rows.length} 格全過（最壞值：最細筆畫 ${mins('minStrokeDev').toFixed(2)}／${R26.minStrokeDev} 裝置像素、墨覆蓋 ${(mins('coverage') * 100).toFixed(2)}%／${R26.coverage * 100}%、前景對比 ${mins('contrast').toFixed(2)}／${R26.contrast}:1、反白 p05 ${mins('counterDev')}／${R26.counterDev}）`,
    bad.slice(0, 6).join(' | '));
  ok(Icon.TINT_BASE === '#808080',
    `G26 Tinted 的驗收底是官方的中灰玻璃 ${Icon.TINT_BASE}（取樣自 Apple design kit 匯出的 kit-AppIcons 第三排；第 2 輪用純黑，黑底會讓任何白色前景都好看）`);
  // 板上印的數字必須出自同一支函式（不是手打的）
  const sheet26 = read('AppIcon.dc.html');
  const shown = rows.filter((m) => sheet26.includes(`${m.minStrokeDev.toFixed(2)}px`)).length;
  ok(shown === rows.length, `G26 板上印的 ${rows.length} 格全部出自 icon.mjs 的實測（不是手打的）`, `板上找得到 ${shown}/${rows.length}`);
  /* 第 5 輪 D4-10（後半）：全表最薄的一格是 Tinted 的前景對比，餘裕只有 0.95。
     它**不隨尺寸變**，因為它是「白對官方中灰玻璃」這兩個顏色決定的 —— 這一條把那句話
     變成斷言：Tinted 那一排在所有尺寸上的對比必須完全相同，而且等於兩色直算的值。
     這樣一來，「我們在 Tinted 能改的只有形狀」就不是說法，是被驗過的事實。 */
  {
    const tint = rows.filter((r) => r.look === 'Tinted').map((r) => +r.contrast.toFixed(4));
    const direct = +Icon.contrast(Icon.rgbOf(Icon.TINT_FG), Icon.rgbOf(Icon.TINT_BASE)).toFixed(4);
    const margin = +(direct - R26.contrast).toFixed(2);
    ok(tint.length === Icon.SIZES.length * Icon.SCALES.length && new Set(tint).size === 1 && tint[0] === direct,
      `G26 Tinted 的對比是顏色的性質不是尺寸的性質：${tint.length} 格全部是 ${direct}:1（門檻 ${R26.contrast}，餘裕只有 ${margin}）—— 前景與底都由系統給，我們一個像素都改不動；能改也真的被驗的是形狀（墨覆蓋與最細筆畫）`,
      `${[...new Set(tint)].join('/')} vs 兩色直算 ${direct}`);
  }
  /* 這一條是本輪突變測試逼出來的（M-G26 第一版全綠漏網）：上面量的是 icon.mjs 裡的
     **規格**，不是板上**畫出來的東西**。把 build 端換回「寫的那支筆」，量測完全不受影響 ——
     跟第 2 輪 G5 只 grep helper 定義是同一個病。所以再加一條：板上那顆印的
     路徑資料與 viewBox，必須逐字元等於被量的那一份幾何。 */
  const seals = [...sheet26.matchAll(/viewBox="([^"]+)"[^>]*data-ink="brush" data-seal="(\w+)"[^>]*>([\s\S]*?)<\/svg>/g)];
  const wantVB = `${Icon.SEAL.vb.x} ${Icon.SEAL.vb.y} ${Icon.SEAL.vb.w} ${Icon.SEAL.vb.h}`;
  const carved = seals.filter(([, , kind]) => kind === 'carved');
  const written = seals.filter(([, , kind]) => kind === 'written');
  ok(carved.length >= 10 && carved.every(([, vb, , d]) => vb === wantVB && d === Icon.SEAL.d),
    `G26 板上畫的就是被量的那一份幾何：AppIcon 上 ${carved.length} 顆落款印的 path 與 viewBox 逐字元等於 icon.mjs 量的那一份（把 build 端換回「寫的那支筆」會在這裡 FAIL —— 只驗規格不驗畫面，就是第 2 輪 G5 的病，本輪的突變測試就是這樣漏過一次的）`,
    `${carved.filter(([, vb, , d]) => vb !== wantVB || d !== Icon.SEAL.d).length} 顆不同`);
  ok(written.length === 1 && written.every(([, , , d]) => d === Icon.WRITTEN.d),
    `G26 對照用的舊筆只准出現 ${written.length} 顆（第 2 輪那一版，畫在「刻的比寫的粗」那一組旁邊）—— 排除項自己也要是斷言，不然排除就是漏洞`,
    `written ${written.length}`);
  ok(new RegExp(`width:\\s*${Math.round(Icon.ICON * Icon.SEAL_FRAC)}px`).test(sheet26),
    `G26 墨跡佔畫布的比例是 ${Math.round(Icon.SEAL_FRAC * 100)}%（板上畫的寬度 ${Math.round(Icon.ICON * Icon.SEAL_FRAC)}px 於 ${Icon.ICON} 母稿）`);
}

/* ══ G7  六位數字的兩種正典 ＋ 3+3 分格 ＋ 兩種分組怎麼分開 ══════
   第 3 輪的「、」斷言量錯東西：/、/.test(join) 連畫面下方那句散文
   「念的時候是『七四二、九三六』。」都算數 —— 把真正的分隔 span 刪掉也不會叫，
   而且與下一行的散文檢查重複。第 4 輪 R11：兩種分隔各自量自己的元素 ——
   輸入格量分隔 span，票根量組間距（印刷品用間距不用標點）。 */
{
  const faces = new Set();
  for (const f of files) {
    if (!inScope('G7', f)) continue;   // 同上：登記簿 SCOPE.G7
    for (const m of read(f).matchAll(/tabular-nums;font-size:(\d+)px/g)) faces.add(+m[1]);
  }
  ok([...faces].sort((a, b) => a - b).join() === '36,60', `G7 六位數字只有兩種正典：${[...faces].sort((a, b) => b - a).join(' / ')}pt`);
  const join = read('JoinCode.dc.html'), otp = read('Otp.dc.html');
  const cells = (s) => [...s.matchAll(new RegExp(`height:${FIX.cell}px`, 'g'))].length;
  ok(cells(join) === 6 && cells(otp) === 6, `G7 3+3 六格：JoinCode ${cells(join)} 格 · Otp ${cells(otp)} 格（同一個元件）`);

  /* ① 輸入格（第 5 輪 D4-13 改）：兩組之間**一個標點都沒有**，分組靠組間距。
        第 4 輪邀請碼那一版中間印一個「、」，理由是「它要唸出來」——但票根上的兩組
        中間本來就一個字元都沒有（下面 ② 在驗），同一組碼在同一條流程裡有兩種分組寫法。
        印刷品用間距分組不用標點，這是這一稿自己的規則，現在兩種碼都照它。
        這一條**兩邊都咬**：塞回任何標點會 FAIL，把組間距拿掉也會 FAIL。 */
  const GRP = /<div data-group="1"[^>]*gap:(\d+)px[^>]*>[\s\S]*?<div data-group="2"/;
  const grpGap = (s2) => { const m = /<div data-cellgroups="1" style="display:flex;gap:(\d+)px">/.exec(s2); return m ? +m[1] : null; };
  const punct = (s2) => [...s2.matchAll(/flex:none">[、，·\-–—]<\/span>/g)].length;
  ok(grpGap(join) === SP.xl && grpGap(otp) === SP.xl && punct(join) === 0 && punct(otp) === 0,
    `G7 分隔（輸入格）：兩種碼的 3＋3 都靠 ${SP.xl}px 組間距分組，中間沒有任何標點（邀請碼 gap=${grpGap(join)}／驗證碼 gap=${grpGap(otp)}，標點 ${punct(join)}／${punct(otp)} 個）`,
    `join gap=${grpGap(join)} otp gap=${grpGap(otp)} 標點 ${punct(join)}/${punct(otp)}`);
  ok(!files.some((f) => /flex:none">、<\/span>/.test(read(f))),
    'G7 分隔（輸入格）：全稿沒有任何一個分隔標點 span 殘留（第 4 輪那一個已經撤掉）',
    files.filter((f) => /flex:none">、<\/span>/.test(read(f))).join(' '));

  /* ② 票根：兩組數字之間「什麼字元都沒有」，分組靠的是它們共同容器的組間距。
        插一個「、」進去 → 兩個 span 不再相鄰，這裡就找不到 3＋3；
        把組間距拿掉 → 找不到級距內的 gap。兩種破壞都會叫。 */
  const GROUPS = /<span[^>]*>([A-Z0-9]{3})<\/span>\s*<span[^>]*>([A-Z0-9]{3})<\/span>/;
  const tickets = files.filter((f) => /data-m="ticket"/.test(read(f)));
  const badT = [];
  for (const f of tickets) {
    const s = read(f), i = s.indexOf('data-m="ticket"');
    const m = GROUPS.exec(s.slice(i));
    if (!m) { badT.push(`${f} 找不到相鄰的 3＋3 兩組（中間被塞了東西？）`); continue; }
    const before = s.slice(i, i + m.index);
    const gaps = [...before.matchAll(/gap:(\d+)px/g)];
    const gap = gaps.length ? +gaps[gaps.length - 1][1] : null;
    if (!gap || !GAPS.includes(gap)) badT.push(`${f} 兩組之間沒有級距內的組間距（gap=${gap}）`);
  }
  ok(tickets.length >= 3 && badT.length === 0,
    `G7 分隔（票根）：${tickets.length} 張票根板的號碼是相鄰的 3＋3 兩組、中間一個字元都沒有，分組靠組間距（印刷品用間距不用標點）`,
    badT.join(' | '));

  /* ③ 使用者核定：邀請碼是 6 位**英數**（對齊 LS-33 已上線的產生器），不是純數字。
        而且「畫面上印的碼」與「唸法那一句引的碼」必須是同一組 —— 改了一邊沒改另一邊就 FAIL。 */
  {
    const tk = files.find((f) => /data-m="ticket"/.test(read(f)) && !/AX/.test(f));
    const m = GROUPS.exec(read(tk).slice(read(tk).indexOf('data-m="ticket"')));
    const said = /念的時候分兩組：「([A-Z0-9]{3})」、「([A-Z0-9]{3})」。/.exec(join);
    ok(!!m && !!said && m[1] === said[1] && m[2] === said[2],
      `G7 唸法同源：票根上印的是 ${m ? `${m[1]} ${m[2]}` : '(找不到)'}，唸法那一句引的是 ${said ? `${said[1]} ${said[2]}` : '(找不到)'} —— 畫面的分組＝嘴巴唸的分組，同一組碼`);
    ok(!!m && /[A-Z]/.test(m[1] + m[2]),
      `G7 邀請碼是 6 位英數不是純數字（使用者核定，對齊 LS-33 已上線的產生器）`,
      m && !/[A-Z]/.test(m[1] + m[2]) ? `票根上是純數字 ${m[1]} ${m[2]} —— 那一版已作廢` : '');
    ok(!/七四二|九三六/.test(files.map(read).join('')), 'G7 作廢的純數字唸法（「七四二、九三六」）全稿已清乾淨');
    /* ④ 文案對帳：「6 位數字」只能出現在信裡的驗證碼那條流程。
          邀請碼是英數，任何一張邀請／加入的板還在說「數字」就是文案沒跟著改。 */
    /* 只擋「講邀請碼卻說數字」的那幾句 —— 板中板（StressContent）同時放了驗證碼與邀請碼
       兩條流程，用整張板當單位會誤殺驗證碼那一欄，所以量的是句子不是檔名。 */
    const BAD = /(家人給你[^。]{0,8}|產生一組 )6 位數字/;
    const drift = files.filter((f) => BAD.test(read(f))).map((f) => f.replace('.dc.html', ''));
    ok(drift.length === 0,
      'G7 文案對帳：邀請碼的句子一律說「字母和數字」；「6 位數字」只留給信裡的驗證碼',
      drift.length ? `${drift.join(' ')} 還在說邀請碼是「6 位數字」，但它已經是英數` : '');
    ok(/6 個字母和數字/.test(read('JoinCode.dc.html')) && /6 位數字/.test(read('Otp.dc.html')),
      'G7 兩條流程說法各自到位：邀請碼「6 個字母和數字」、驗證碼「6 位數字」—— 兩者長度相同、分組相同，但不是同一種東西');
  }
}

/* ══ G8  陶土：每張流程板最多一個最外層陶土區塊 ══════════════════ */
if (M.cta) {
  const bad = Object.entries(M.cta).filter(([k, v]) => inScope('G8', k) && v > 1);
  ok(bad.length === 0, `G8 陶土：${M.ctaBoards} 張流程板，最外層陶土區塊最多 ${M.ctaMax} 個／板（排除 ${SCOPE.G8.skip.join('／')}：${SCOPE.G8.why}）`,
    bad.length ? bad.map(([k, v]) => `${k}=${v}`).join(' ') : '');
} else need('cta', 'G8 陶土');

/* ══ G9  錯誤幾何不得與可按幾何重合 ══════════════════════════════ */
if (M.err) {
  ok(M.err.length >= 4, `G9 錯誤線由同一個元件產生，出現在 ${M.err.length} 處`);
  ok(M.errOverlap === 0, `G9 錯誤幾何與可按唇邊沒有任何重合（重合 ${M.errOverlap} 處）`);
  ok(M.errGap >= 4, `G9 錯誤線與最近的唇邊最小距離 ${M.errGap}px（門檻 4px）`);
  ok(M.err.every((e) => Math.round(e.h) === FIX.errBar), `G9 錯誤線一律 ${FIX.errBar}pt（唇邊是 ${FIX.lip}pt，兩者不同寬）`,
    M.err.filter((e) => Math.round(e.h) !== FIX.errBar).map((e) => `${e.file}=${e.h}`).join(' '));
} else need('err', 'G9 錯誤幾何');

/* ══ G10  呼吸帶（兩句規則）、板高、裁切 ══════════════════════════
   ①「內容首末之間，任何一段連續空白 ≤120px（手機 iPad 同一條）」——
      超過的必須掛 data-pause="理由"，未掛牌一律 FAIL（意圖 gate，不是門檻放寬）。
   ②「內容末端到板底不設上限，但主按鈕中心須落在畫面 70% 以內」——
      落地範圍：尾段空白 >120px 的流程板（交付板／壓力板不是畫面）。理由印在 Tokens 板上。 */
if (M.voids) {
  // 交付板不是畫面（Tokens／Notes／壓力板／AppIcon／GlassSeam），呼吸帶與板高的兩條規則不適用；
  // 排除清單明講在這裡，不是靠 verify 靜靜跳過 —— AppIcon 與 GlassSeam 兩張板上也各自
  // 印了它自己的豁免清單（「沒印出來的例外就是 bug」）。
  const PAUSE = RULE.pause, FLOW = (f) => inScope('G10', f);
  const SKIP10 = SCOPE.G10.skip.join('／');
  ok(M.pauseBad.filter((v) => FLOW(v.file)).length === 0,
    `G10 呼吸帶①：內容之間 >${PAUSE}px 的空白共 ${M.pauses.length} 段，全部掛了 data-pause 說明理由（手機 iPad 同一條門檻；排除 ${SCOPE.G10.skip.length} 張：${SKIP10}）`,
    M.pauseBad.filter((v) => FLOW(v.file)).map((v) => `${v.file}/${v.col}=${v.len}px@${v.at} 未掛牌`).join(' '));
  ok(M.pauses.every((p) => p.why.length >= 8),
    `G10 呼吸帶①：掛牌的理由都是句子不是敷衍`, M.pauses.filter((p) => p.why.length < 8).map((p) => p.file).join(' '));
  {
    const tails = new Set(M.boards.filter((b) => FLOW(b.file) && b.trail > PAUSE).map((b) => b.file));
    const rows = M.mainBtn.filter((b) => tails.has(b.file));
    const bad = rows.filter((b) => b.pct > RULE.btnPct);
    ok(bad.length === 0,
      `G10 呼吸帶②：尾段空白 >${PAUSE}px 的 ${tails.size} 張流程板，主按鈕中心位置最低 ${rows.length ? Math.max(...rows.map((b) => b.pct)) : '-'}%（門檻 ${RULE.btnPct}；排除 ${SKIP10}）`,
      bad.map((b) => `${b.file}=${b.pct}%`).join(' '));
    ok([...tails].every((f) => rows.some((b) => b.file === f)),
      `G10 呼吸帶②：有尾段的板都量得到主按鈕（沒有主按鈕就沒有豁免這回事）`,
      [...tails].filter((f) => !rows.some((b) => b.file === f)).join(' '));
  }
  /* 板高只有兩種合法值：內容連同安全區放得下 → 844；放不下 → 長高（會捲動的畫面）。
     內容末端＝有字有圖的最後一列，不是背景畫到哪裡（歡迎頁的卡紙本來就畫到板底）。 */
  {
    const phones = M.boards.filter((b) => FLOW(b.file) && !/IPad/.test(b.file));
    const bad = phones.filter((b) => {
      const need = (b.h - b.trail) + FIX.safeBottom;
      return need <= 844 ? b.h !== 844 : b.h < need;
    });
    ok(bad.length === 0, `G10 板高：${phones.length} 張手機板（排除 ${SKIP10} 與 iPad 兩張），放得下的一律 844、放不下的才長高（${phones.filter((b) => b.h > 844).map((b) => `${b.file} ${b.h}`).join(' ')}）`,
      bad.map((b) => `${b.file} h=${b.h} 需要 ${(b.h - b.trail) + FIX.safeBottom}`).join(' '));
  }
  ok(M.clipped.length === 0, 'G10 裁切：沒有任何板的內容被框裁掉', M.clipped.join(' '));
} else need('voids', 'G10 呼吸帶');

/* ══ G11  H1 起跑線：三組手機畫面，每組內部同一條線
   分組是明講的，不是用 regex 猜。排除的板也明講：
   iPad 兩板走跨欄基線（下一項）、AX 壓力板字級是 ×3.1、板中板與交付板不是畫面。 */
if (M.h1) {
  const GROUPS = H1_GROUPS, EXCLUDED = H1_EXCLUDED;
  const seen = new Set();
  for (const [gname, list] of Object.entries(GROUPS)) {
    list.forEach((f) => seen.add(f));
    const g = M.h1.groups[gname];
    ok(g.n === list.length && g.ys.length === 1, `G11 H1 起跑線「${gname}」：${list.length} 張板同在 ${g.ys.join('／')}px`,
      g.ys.length > 1 ? M.h1.all.filter((x) => !x.cap && list.includes(x.file)).map((x) => `${x.file}=${x.y}`).join(' ') : '');
  }
  const stray = M.h1.all.filter((x) => !x.cap && !seen.has(x.file) && !EXCLUDED.includes(x.file));
  ok(stray.length === 0, `G11 每一張畫面都被分進某一組（排除的 ${EXCLUDED.length} 張已明列）`, stray.map((x) => x.file).join(' '));
  const L = M.h1.padPair.find((x) => x.cap === 'L'), R = M.h1.padPair.find((x) => x.cap === 'R');
  ok(L && R && Math.abs(L.y - R.y) <= 2,
    `G11 iPad 跨欄 cap-height：左欄 H1 ${L ? L.y : '?'} / 右欄首卡標題 ${R ? R.y : '?'}（差 ${L && R ? Math.abs(L.y - R.y).toFixed(1) : '?'}px，門檻 2）`);
} else need('h1', 'G11 H1 起跑線');

/* ══ G12  深色板：四個母題都要入鏡 ══════════════════════════════ */
{
  const darks = files.filter((f) => /Dark\.dc\.html$/.test(f));
  ok(darks.length >= 4, `G12 深色板 ${darks.length} 張：${darks.map((f) => f.replace('.dc.html', '')).join(' ')}`);
  if (M.darkMotifs) {
    const wanted = ['ticket', 'cells', 'errbar', 'switch'];
    const missing = wanted.filter((w) => !M.darkMotifs[w]);
    ok(missing.length === 0, `G12 深色母題指紋：${wanted.map((w) => `${w}×${M.darkMotifs[w] || 0}`).join(' ')}`,
      missing.length ? `缺 ${missing}` : '');
    /* 第 5 輪 D4-02：第 4 輪這裡是 switch×1 —— 而那一顆是**關閉**的。
       「深色 × ON」整格是空的，卻沒有任何一條斷言在問「這一格有沒有樣本」，
       所以 gate 一路綠燈。現在開關的母體是 {淺,深}×{ON,OFF} 四格（見 G19b 的 pop 宣告），
       而這裡順手咬住它的必要條件：深色板上的開關**至少兩顆**（一顆 ON 一顆 OFF）。 */
    ok((M.darkMotifs.switch || 0) >= 2,
      `G12 深色的開關不只一顆：深色板上量到 ${M.darkMotifs.switch || 0} 顆開關（ON 與 OFF 各至少一顆 —— 第 4 輪只有 OFF 那一顆，深色 ON 從來沒有被畫過）`,
      `switch×${M.darkMotifs.switch || 0}`);
  } else need('darkMotifs', 'G12 深色母題');
  ok(/press: '0 -1px 0/.test(readFileSync(at('tokens.mjs'), 'utf8')),
    'G12 深色光源反轉：letterpress 由「下緣亮」翻成「上緣暗」（token 層）');
}

/* ══ G13  孤兒斷行 ══════════════════════════════════════════════ */
if (M.orphans) {
  ok(M.orphans.length === 0, `G13 孤兒斷行：沒有任何一行的末行只剩 1 個中文字／≤2 個西文字元`, M.orphans.slice(0, 6).join(' | '));
} else need('orphans', 'G13 孤兒斷行');

/* ══ G14  核准↔拒絕、次要連結命中盒（原 _tap2，併進管線）══════════ */
if (M.approve) {
  const bad = M.approve.filter((a) => a.gap < 32 || a.rejectW > a.approveW * 0.75);
  ok(M.approve.length > 0 && bad.length === 0,
    `G14 核准↔拒絕：${M.approve.length} 組，間距 ${[...new Set(M.approve.map((a) => a.gap))].join('/')}px（≥32），拒絕不滿版`,
    bad.map((a) => `${a.file} gap=${a.gap} w=${a.rejectW}/${a.approveW}`).join(' '));
  ok(M.subTap.length === 0, `G14 底線連結：全部 ≥44pt 命中盒`, M.subTap.slice(0, 6).join(' | '));
} else need('approve', 'G14 核准↔拒絕');

/* ══ G15  Notes 上寫的版式，逐一要有一張板畫出來 ══════════════════ */
{
  const claims = [
    ['AX3 以上按鈕拿掉 icon', 'StressType.dc.html'],
    ['驗證碼六格 AX 改兩排三格', 'StressCodeAX.dc.html'],
    ['票根 60pt 在 AX 的降版', 'StressCodeAX.dc.html'],
    ['錯誤只有兩個紅', 'EmailError.dc.html'],
    ['出錯時明細表收成一行', 'OtpError.dc.html'],
    ['過期與次數用盡是兩段文案', 'JoinExpired.dc.html'],
    ['過期與次數用盡是兩段文案（第二段）', 'JoinUsedUp.dc.html'],
    ['載入就地轉態', 'CreateFamilySending.dc.html'],
    ['空狀態指向產生邀請碼', 'InviteEmpty.dc.html'],
    ['審核開關關掉的後果', 'InviteApprovalOff.dc.html'],
    ['審核關閉的警語條用 lit', 'InviteApprovalOff.dc.html'],
    ['三顆登入鍵在 AX5', 'StressLoginAX.dc.html'],
    ['待核清單收成一列', 'InviteRequestsMany.dc.html'],
    ['有人在等的時候票根不縮（第 3 輪改，第 5 輪對帳）', 'InviteRequestsMany.dc.html'],
    ['深色的審核開關 ON（第 5 輪新增）', 'InviteReadyDark.dc.html'],
    ['AX4／AX5 兩階登入標籤', 'StressLoginAX.dc.html'],
    ['iPad 三段式登入', 'WelcomeIPad.dc.html'],
    ['iPad 雙欄三岔路', 'ForkIPad.dc.html'],
    ['深色光源反轉', 'InviteApprovalOffDark.dc.html'],
  ];
  const missing = claims.filter(([, f]) => !files.includes(f));
  ok(missing.length === 0, `G15 Notes 要求的 ${claims.length} 種版式，每一種都有板畫出來`, missing.map(([c]) => c).join(' '));
  // 手寫字標的三個使用點
  /* 字標＝手寫「萌芽」＋系統字「日記」。整組只掛一個無障礙名稱＝產品全名，
     所以這裡掃的就是那個名稱；順帶保證沒有任何一處把舊名留在畫面上。 */
  const inkBoards = files.filter((f) => /aria-label="萌芽日記"/.test(read(f)));
  ok(inkBoards.length >= 8, `G15 字標出現在 ${inkBoards.length} 張板（歡迎×3、信件明細×3、建立家庭×2、Tokens）`);
  ok(/Main|Welcome/.test(inkBoards.join()) && /Email\.dc/.test(inkBoards.join()) && /CreateFamily\.dc/.test(inkBoards.join()),
    'G15 字標跨板縫合：歡迎頁 → 信件明細「寄件人」 → 建立家庭即時預覽');
  {
    const old = files.filter((f) => /小芽/.test(read(f)));
    ok(old.length === 0, `G15 舊名清乾淨：${files.length} 張板上沒有任何一處還寫著「小芽」（產品中文名＝${'萌芽日記'}）`, old.join(' '));
    const lock = files.filter((f) => /aria-label="萌芽日記"/.test(read(f)) && !/>日記</.test(read(f)));
    ok(lock.length === 0, 'G15 lockup 完整：每一個字標都是「手寫萌芽＋系統字日記」兩塊，沒有只出現一半的', lock.join(' '));
    /* 第 2 輪這一條靠「板上有沒有出現『萌芽』『日記』這幾個字元」判斷 —— 那是拿內容當結構用：
       正文裡出現一次產品全名就會讓斷言變綠，而真正要守的是**材質**
       （哪一塊是手寫的圖、哪一塊是會跟著 Dynamic Type 長大的真文字）。改成屬性標記。 */
    const mat = [];
    for (const f of files) {
      const s2 = read(f);
      /* 上界不能設 —— 手寫那兩個字的 path 資料就超過 4000 字元，
         設了上界正則會一個都對不上，這一條就變成「沒有樣本所以不會 FAIL」
         （本輪的突變測試 M-G15 就是這樣漏網的）。用非貪婪配到第一個收尾即可。 */
      for (const m of s2.matchAll(/data-lockup="1"[\s\S]*?<\/span><\/span>/g)) {
        const brush = (m[0].match(/data-ink="brush"/g) || []).length;
        const sys = (m[0].match(/data-ink="system"/g) || []).length;
        if (brush !== 1 || sys !== 1) mat.push(`${f} 一組 lockup 裡 brush×${brush}／system×${sys}`);
      }
      /* 落單的筆跡（不在 lockup 裡的 brush）只准出現在 AppIcon 板上 ——
         那張板講的就是「同一支筆單獨拿去刻成印」，落款印本來就只有筆跡沒有系統字。
         其他任何板上出現半組字標一律 FAIL。 */
      const loose = (s2.match(/data-ink="brush"/g) || []).length - (s2.match(/data-lockup="1"/g) || []).length;
      if (inScope('G15', f) && loose !== 0) mat.push(`${f} 有 ${loose} 個不在 lockup 裡的筆跡`);
    }
    const nLock = files.reduce((a, f) => a + (read(f).match(/data-lockup="1"/g) || []).length, 0);
    ok(nLock >= 8, `G15 字標的樣本數：全稿 ${nLock} 組 lockup 被掃到（沒有樣本就不會 FAIL，所以樣本數自己也是一條斷言）`, `nLock=${nLock}`);
    ok(mat.length === 0,
      `G15 字標的材質是標出來的不是猜出來的：每一組 data-lockup 裡剛好一塊 data-ink="brush"（筆跡，是圖，不隨 Dynamic Type 長大）＋一塊 data-ink="system"（真文字，會長大）——判準與字元無關，換名字換語言都不會失效`,
      mat.join(' · '));
  }
}

/* ══ G16  原始碼衛生：重複宣告與雙分號 ══════════════════════════ */
{
  const dups = [], semis = [];
  for (const f of files) {
    const s = read(f);
    for (const m of s.matchAll(/style="([^"]*)"/g)) {
      const props = [...m[1].matchAll(/(^|;)\s*([a-z-]+):/g)].map((x) => x[2]);
      const seen = new Set(), dup = new Set();
      for (const p of props) { if (seen.has(p)) dup.add(p); seen.add(p); }
      if (dup.size) dups.push(`${f}:${[...dup].join(',')}`);
    }
    if (/;;/.test(s)) semis.push(f);
  }
  ok(dups.length === 0, 'G16 沒有重複的 CSS 宣告（font-weight 等）', [...new Set(dups)].slice(0, 8).join(' | '));
  ok(semis.length === 0, 'G16 沒有雙分號', semis.join(' '));

  /* 第 1 輪 R2：build.mjs 有兩行用了單引號，`${CODE2}` 六個字元原封不動印在
     InviteRequestsMany 板上給人看 —— 71 項 gate 沒有一項會叫（沒有人在掃產物的字面）。
     這一條是 fail-closed 的：產物與畫布註記裡出現未內插的樣板語法一律 FAIL。 */
  const raw = [];
  for (const f of [...files, 'canvas.json']) {
    const s = read(f);
    for (const m of s.matchAll(/\$\{[^}]{0,40}\}?/g)) raw.push(`${f} 「${m[0].slice(0, 24)}」`);
  }
  ok(raw.length === 0, `G16 沒有沒內插的樣板語法：${files.length} 張板＋canvas.json 裡不存在 \${…}`, raw.slice(0, 6).join(' | '));
}

/* ══ G18  Tokens 板印的常數 ＝ tokens.mjs 的常數 ══════════════════
   第 3 輪 R1：板上印 capAlign 27、實際建出來的是 39 —— 印的規格與建的規格是兩份東西。
   現在 FIX 表整張改成內插，這一項逐個 key 斷言「有印出來，而且值一樣」。
   （能過這一關，ios-dev 抄板上的數字就等於抄 tokens.mjs。） */
{
  const sheet = read('Tokens.dc.html');
  const miss = [], wrong = [];
  for (const [k, v] of Object.entries(FIX)) {
    const any = new RegExp(`${k}\\s+(-?\\d+)`, 'g');
    const hits = [...sheet.matchAll(any)].map((m) => +m[1]);
    if (!hits.length) miss.push(k);
    else if (!hits.includes(v)) wrong.push(`${k} 板上印 ${hits.join('/')}、tokens.mjs 是 ${v}`);
  }
  ok(miss.length === 0 && wrong.length === 0,
    `G18 常數同源：tokens.mjs 的 ${Object.keys(FIX).length} 個 FIX 全部印在 Tokens 板上，值一致`,
    [...miss.map((k) => `${k} 沒印`), ...wrong].join(' · '));
}

/* ══ G19  唇邊與開關列（第 3 輪 R1 / R4）══════════════════════════ */
if (M.lips) {
  const w = new Set(Object.keys(M.lips).map((k) => k.split('@')[1]));
  ok([...w].join() === String(FIX.lip), `G19 唇邊一律 ${FIX.lip}pt：${Object.entries(M.lips).map(([k, v]) => `${k}×${v}`).join(' ')}`, [...w].join('/'));
  ok(Object.keys(M.lips).every((k) => /^(ctaDeep|ctaBusy|board3|edge|pen)@/.test(k)),
    'G19 唇邊一律是「該表面的深一階」：濃玫瑰→ctaDeep、台紙→edge、朱→pen；載入中→與底同色（主要 ctaBusy／次要 board3）＝按不動',
    Object.keys(M.lips).filter((k) => !/^(ctaDeep|ctaBusy|board3|edge|pen)@/.test(k)).join(' '));
  /* 第 1 輪 R6 裁定「Google 的描邊被借做唇邊＝巧合不是融入」，本輪表態：
     兩顆品牌鍵都不加唇邊。量測端的判準也一起改成幾何的 —— 唇邊＝下緣比上緣厚；
     四邊等寬的是描邊。所以就算有人再把 border-bottom 調成 3px，它也會立刻出現在
     lips 而不是 lipNone，這一條就會 FAIL。 */
  {
    const brand = M.lipNoneWho.filter((s) => /\/(apple|google)$/.test(s));
    const sw = M.lipNoneWho.filter((s) => /:switch$/.test(s));
    /* 第 5 輪：品牌鍵的顆數不再寫死 8（AX 板本輪多了一組 AX4 的堆疊）——
       改成推導：畫面上量到幾顆 [data-brand]，就必須有幾顆落在「沒有唇邊」這一類。 */
    const brandN = (M.brand || []).length;
    ok(brand.length + sw.length === M.lipNone && brand.length === brandN && sw.length === 0,
      `G19 沒有唇邊的浮起面只有兩種、共 ${M.lipNone} 個（品牌鍵總數 ${brandN}，兩者必須相等）：兩顆品牌鍵（Apple ${brand.filter((s) => /apple/.test(s)).length}＋Google ${brand.filter((s) => /google/.test(s)).length}，我們不改別人的外觀 —— 連加一道唇邊、連把它規範的 1px 描邊加粗成 3px 都算改）。第 2 輪這裡還有第三種例外：ON 的開關軌道 —— 本輪它不再是浮起面了（軌道在兩個狀態都是同一個凹槽，差別只有槽裡填什麼），所以那個例外自己消失了，現在是 ${sw.length} 個`,
      M.lipNoneWho.join(' '));
  }
} else need('lips', 'G19 唇邊');

/* ══ G19b  審核開關（第 3 輪 R1：全稿唯一會出事的可用性缺陷）══════════
   第 2 輪實測 OFF 的把手對軌道只有 1.04:1 —— 一個看不出停在哪一邊的開關，
   而它管的是「陌生人能不能直接看到孩子的照片」。三條：
     ① OFF 的把手對軌道 ≥3:1（ON 不設這條：ON 的訊號是**軌道的顏色**不是把手的邊，
        官方 kit 的 Light/Dark ON 兩顆也都是白把手坐在綠軌道上、對比 1.x）；
     ② 把手在四種組合裡是同一個顏色（它是同一個零件，不會因為狀態換色）；
     ③ 行程看得見：把手中心在兩端的距離 ＝ 軌道寬 − 把手 − 兩側間隙。 */
if (M.knobs) {
  const off = M.knobs.filter((k) => !k.on), on = M.knobs.filter((k) => k.on);
  const travel = FIX.switchW - FIX.switchKnob - FIX.knob * 2;
  ok(off.length >= 2 && off.every((k) => k.cr >= KNOB_CR),
    `G19b OFF 的把手看得見：${off.length} 張關閉態的板，把手對軌道實測 ${off.map((k) => `${k.file.replace('Invite', '')} ${k.cr}:1`).join('／')}（門檻 ${KNOB_CR}:1，出處 WCAG 2.1 SC 1.4.11；第 2 輪是 1.04:1）`,
    off.filter((k) => k.cr < KNOB_CR).map((k) => `${k.file} ${k.cr}`).join(' '));
  ok(on.length >= 3, `G19b ON 態也被量到 ${on.length} 張（把手對芽綠軌道 ${[...new Set(on.map((k) => k.cr))].join('／')}:1 —— 這一條刻意不設 3:1 門檻，ON 的訊號是軌道的顏色，官方 kit 的 ON 也是白把手坐綠軌道）`);
  const cx = { on: [...new Set(on.map((k) => k.cx))], off: [...new Set(off.map((k) => k.cx))] };
  ok(cx.on.length === 1 && cx.off.length === 1 && cx.on[0] - cx.off[0] === travel,
    `G19b 行程看得見：把手中心 OFF 在 ${cx.off[0]}px、ON 在 ${cx.on[0]}px，相差 ${cx.on[0] - cx.off[0]}px ＝ 軌道 ${FIX.switchW} − 把手 ${FIX.switchKnob} − 兩側間隙 ${FIX.knob}×2`,
    `on ${cx.on.join('/')} off ${cx.off.join('/')} 應差 ${travel}`);
  ok(/const knob = `<div data-role="knob"[^`]*background:\$\{t\.knob\}/.test(src),
    'G19b 把手是同一個零件：兩個狀態走同一行程式、同一個 t.knob（第 2 輪 ON 用 onSprout、OFF 用 board3 —— 一顆會變色的把手是兩個零件）');
} else need('knobs', 'G19b 審核開關');

if (M.toggles) {
  const ys = [...new Set(M.toggles.map((t) => t.top))];
  ok(M.toggles.length >= 5 && ys.length === 1,
    `G19 開關列固定在票根正下方：${M.toggles.length} 張板（空／產生中／已產生／審核關閉／深色）全部在 y=${ys.join('／')}`,
    ys.length > 1 ? M.toggles.map((t) => `${t.file}@${t.top}`).join(' ') : '');
} else need('toggles', 'G19 開關列');

/* ══ G26b  逐筆中線：「重排」與「同一個字」各自是一個數（第 5 輪 D4-10）══
   第 4 輪 reviewer：「刻是為刀重排但同一個字」這句話印在板上，可是那張 24 格的表
   量的是**可讀性**（最細筆畫／墨覆蓋／對比／反白），其中兩個還是規格算術 ——
   「同不同一個字」從來沒有被量過。這一條把那句話拆成八筆各一組數，門檻的出處
   寫在 icon.mjs（四分之一字身、刻刀最細的一劃、20°、長度比、身分比值）。
   **第 6 輪與 G26 一起暫停**（使用者否決字形 icon 概念，見 G26 的說明與 EXEMPT 登記簿）。 */
if (!ICON_SUSPEND) {
  const rows = Icon.centerlineDev(), RC = Icon.CARVE_RULE;
  const bad = [];
  for (const r of rows) {
    if (r.move > RC.moveMax) bad.push(`第 ${r.i} 筆位移 ${r.move} > ${RC.moveMax}（那不是重排，是重寫）`);
    if (r.tilt > RC.tiltMax) bad.push(`第 ${r.i} 筆轉了 ${r.tilt}° > ${RC.tiltMax}°（換了方向）`);
    if (r.len < RC.lenLo || r.len > RC.lenHi) bad.push(`第 ${r.i} 筆長度比 ${r.len} 出界`);
    if (r.nearest > RC.nearest) bad.push(`第 ${r.i} 筆離自己的對應筆不夠近（比值 ${r.nearest} > ${RC.nearest}）—— 它被搬成了另一支筆`);
  }
  ok(rows.length === 8 && bad.length === 0,
    `G26b 同一個字：八筆逐一對位，位移 ${Math.min(...rows.map((r) => r.move))}–${Math.max(...rows.map((r) => r.move))}（上界 ${RC.moveMax}）、角度差最大 ${Math.max(...rows.map((r) => r.tilt))}°（上界 ${RC.tiltMax}）、長度比 ${Math.min(...rows.map((r) => r.len))}–${Math.max(...rows.map((r) => r.len))}、身分比值最大 ${Math.max(...rows.map((r) => r.nearest))}（上界 ${RC.nearest}）`,
    bad.join(' · '));
  ok(Math.max(...rows.map((r) => r.move)) >= RC.reMin,
    `G26b 重排真的發生了：位移最大的那一筆搬了 ${Math.max(...rows.map((r) => r.move))} 個字身單位，比刻刀最細的一劃（${RC.reMin}）還遠 —— 這是**下界**，防的是「只是加粗卻說自己重排了」`,
    `max move ${Math.max(...rows.map((r) => r.move))} < ${RC.reMin}`);
  const shown = rows.filter((r) => read('AppIcon.dc.html').includes(`>${r.move.toFixed(2)}<`)).length;
  ok(shown === rows.length, `G26b 板上印的八筆全部出自 icon.mjs 的實測（不是手打的）`, `板上找得到 ${shown}/${rows.length}`);
}

/* ══ G26c  驗收排畫的就是它宣告的那個尺寸（第 5 輪 D4-07 的 M2b）════════
   第 4 輪 reviewer 的 M2b：把驗收排上某一顆圖示**偷偷畫大**，G26 全綠 ——
   因為它驗的是 path 與 viewBox（畫的是不是同一份幾何），沒有一項在問「畫多大」。
   一張以「這一排是驗收不是展示」自居的表，如果尺寸可以偷改，那它就是展示。
   **第 6 輪與 G26 一起暫停**（使用者否決字形 icon 概念，見 G26 的說明與 EXEMPT 登記簿）。 */
if (!ICON_SUSPEND) {
  const sheet26 = read('AppIcon.dc.html');
  const want = Icon.SIZES.map(([px]) => px);
  /* 驗收排的每一格都掛 data-icon-acc="宣告的尺寸"，而且**同一個標籤裡**的 width/height
     必須等於它 —— 標籤與畫出來的尺寸因此不可能各說各話（M2b 就是偷改畫出來的那一個）。 */
  const tiles = [...sheet26.matchAll(/data-icon-acc="(\d+)" style="width:(\d+)px;height:(\d+)px/g)]
    .map((m) => ({ dec: +m[1], w: +m[2], h: +m[3] }));
  const acc = tiles.filter((x) => x.dec === x.w && x.w === x.h).map((x) => x.w);
  const stray = [...tiles.filter((x) => !(x.dec === x.w && x.w === x.h)).map((x) => `宣告 ${x.dec} 卻畫 ${x.w}×${x.h}`),
    ...acc.filter((px) => !want.includes(px)).map((px) => `未宣告的尺寸 ${px}`)];
  const perSize = want.map((px) => [px, acc.filter((x) => x === px).length]);
  void 0;
  ok(perSize.every(([, n]) => n === Object.keys(Icon.APPEARANCE).length) && stray.length === 0,
    `G26c 驗收排的尺寸是宣告的那四個：${perSize.map(([px, n]) => `${px}pt×${n} 種外觀`).join('、')}（把任何一格偷偷畫大或畫小都會在這裡 FAIL）`,
    [...perSize.filter(([, n]) => n !== 3).map(([px, n]) => `${px}pt 只有 ${n} 顆`), ...stray].join(' · '));
}

/* ══ G27  騎縫線是紙的形狀（第 5 輪 D4-04）════════════════════════
   第 4 輪判定：那條「騎縫線」是 1px 高的 repeating-linear-gradient，畫材是 edge
   （＝我們用來畫「印上去的框」的顏色），撕了不會有東西分開，AX5 下也不變大 ——
   它是一條裝飾線。現在它是遮罩挖出來的洞，這一條逐個使用點驗四件事。 */
if (M.perf) {
  const rows = M.perf;
  const joined = rows.filter((r) => /^joined/.test(r.kind)), torn = rows.filter((r) => r.kind === 'torn-t');
  const LAYERS = PERF_TILE + 2;
  ok(rows.length >= 8 && rows.every((r) => r.layers === LAYERS && r.holes === LAYERS && /intersect|source-in/.test(r.composite)),
    `G27① 真的是洞不是線：${rows.length} 個騎縫線使用點，每一個都是 ${LAYERS} 層遮罩取交集（${PERF_TILE} 顆一循環的齒 ∩ 左缺口 ∩ 右缺口），洞裡透出來的是台紙本身`,
    rows.filter((r) => !(r.layers === LAYERS && r.holes === LAYERS)).map((r) => `${r.file}/${r.kind} 層數 ${r.layers}／洞 ${r.holes}`).join(' '));
  /* 齒距綁字級：一般板 PERF.pitch、AX4 板 ax4()、AX5 板 ax()。紙變大，紙上的齒跟著變大。
     AX 板上出現一般齒距 ＝ 那張紙長大了、齒沒有跟著長大 ＝ 它又變回一張貼上去的圖樣。 */
  /* 遮罩的 tile 寬 ＝ PERF_TILE × 齒距（五顆一循環），所以還原齒距要先除回去。 */
  const perTooth = (r) => Math.round(r.pitch / PERF_TILE);
  const pitches = [...new Set(rows.map(perTooth))].sort((a, b) => a - b);
  const legalP = [PERF.pitch, ax4(PERF.pitch), ax(PERF.pitch)];
  const axBad = rows.filter((r) => (/AX/.test(r.file) ? perTooth(r) === PERF.pitch : perTooth(r) !== PERF.pitch));
  ok(pitches.every((p2) => legalP.includes(p2)) && axBad.length === 0,
    `G27② 齒距綁字級：一般板 ${PERF.pitch}px、AX4 ${ax4(PERF.pitch)}px、AX5 ${ax(PERF.pitch)}px —— 實測只出現這些：${pitches.join('／')}`,
    axBad.map((r) => `${r.file}/${r.kind} pitch=${perTooth(r)}`).join(' '));
  const pairBad = [];
  for (const f of [...new Set(joined.map((r) => r.file))]) {
    const bs = joined.filter((r) => r.file === f && r.kind === 'joined-b'), ts = joined.filter((r) => r.file === f && r.kind === 'joined-t');
    if (bs.length !== ts.length) { pairBad.push(`${f} 上半 ${bs.length} 個、下半 ${ts.length} 個`); continue; }
    for (const b of bs) if (!ts.some((t2) => Math.abs(t2.edgeY - b.edgeY) <= 1)) pairBad.push(`${f} 有一半的齒對不上（上半下緣 y=${b.edgeY}）`);
  }
  ok(joined.length > 0 && pairBad.length === 0,
    `G27③ 還沒撕的是完整圓孔、撕下來的是半圓扇貝邊：票根 ${joined.length / 2} 張（上下兩半各切自己那一緣的一半，兩緣的 y 對得上才會合成整個圓孔）、托盤 ${torn.length} 個（只切上緣）`,
    pairBad.join(' · '));
  ok(!/repeating-linear-gradient/.test(src) && !files.some((f) => /repeating-linear-gradient/.test(read(f))),
    'G27④ 沒有人把它改回畫上去的線：build.mjs 與 35 張產物裡不存在 repeating-linear-gradient（第 4 輪的騎縫線就是那個寫法）',
    files.filter((f) => /repeating-linear-gradient/.test(read(f))).join(' '));
  /* ⑤ 撕邊不是機器切的（第 6 輪 D5-06）──────────────────────────────
     第 5 輪把線改成洞，但那些洞**等距而且一樣大** —— 那是打孔機。真的撕開一張紙，
     齒的間距與大小都會抖，而且撕口的斷面會露出紙芯，在光下是一道很細的亮唇。
     兩件事逐個使用點量：抖動的幅度（不是零）、斷面唇的方向與顏色（由 dir 決定）。 */
  {
    const jr = JITTER.map((j) => j.dr), jx = JITTER.map((j) => j.dx);
    const flat = rows.filter((r) => !r.radii || new Set(r.radii.slice(0, PERF_TILE).map((v) => Math.round(v * 100))).size < 3);
    ok(flat.length === 0 && new Set(jr).size === PERF_TILE,
      `G27⑤ 齒不等大：一個循環 ${PERF_TILE} 顆，半徑比例 ${jr.join('／')}（實測最小 ${Math.min(...rows.flatMap((r) => r.radii || [99])).toFixed(2)}px、最大 ${Math.max(...rows.flatMap((r) => r.radii || [0])).toFixed(2)}px）—— 等大的圓孔是打孔機打的，抖動是手撕的`,
      flat.map((r) => `${r.file}/${r.kind} 的齒全部一樣大`).join(' '));
    const off = rows.filter((r) => !r.cxs || r.cxs.length < PERF_TILE);
    ok(off.length === 0 && jx.some((v) => v !== 0),
      `G27⑤ 齒不等距：圓心偏移 ${jx.map((v) => `${v > 0 ? '+' : ''}${v}`).join('／')} 個齒距（寫死的一組抖動，不是亂數 —— 產物可重現、gate 驗得到，而且「抖多少」是設計決定的）`,
      off.map((r) => `${r.file}/${r.kind} 讀不到圓心`).join(' '));
    const lipBad = rows.filter((r) => !/drop-shadow/.test(r.lip || ''));
    /* computed filter 是 `drop-shadow(rgba(…) 0px -1px 0px)` —— 顏色在前、位移在後，
       所以位移取的是整串裡最後三個 px 的中間那一個（dy）。 */
    const dyOf = (s2) => { const px = [...String(s2).matchAll(/(-?[\d.]+)px/g)].map((m2) => +m2[1]); return px.length >= 3 ? px[px.length - 2] : 0; };
    const dirBad = rows.filter((r) => (r.kind.endsWith('-t') ? dyOf(r.lip) >= 0 : dyOf(r.lip) <= 0));
    ok(lipBad.length === 0 && dirBad.length === 0,
      `G27⑤ 撕口有斷面：${rows.length} 個使用點都有一道 1px 的唇，而且它是 drop-shadow 不是 box-shadow —— drop-shadow 吃的是**遮罩之後的輪廓**，所以那道唇沿著每一顆扇貝的弧走（box-shadow 只會沿著矩形）。方向由切的是哪一緣決定，顏色由 dir 決定（撕口朝光＝亮邊、背光＝暗邊），沒有第二個光源`,
      [...lipBad.map((r) => `${r.file}/${r.kind} 沒有斷面唇`), ...dirBad.map((r) => `${r.file}/${r.kind} 唇的方向反了：${r.lip}`)].join(' '));
    /* ⑥ 第 5 輪 reviewer 對這一手的評語是「加了一個沒人看得到的東西」。第 8 輪的表態
       （二選一裡選「板上承認」，而不是把它做得更明顯 —— 做明顯就不是 1px 的斷面了）：
       把它拆成兩件可以分開判斷的事，兩件都印在 Tokens 板上（PERF_WHY）。
         · 顏色：唇與台紙合成後的色差必須在 JND 之上 —— 它不是一個看不見的顏色
         · 高度：它就是 1 個裝置像素，所以在縮圖上確實看不到（那是尺度的事實，不是缺陷）
       沒有這一條，「留著它」就只是一句品味宣稱。 */
    ok(Math.min(...LIP_DE) >= HUE_DE_MIN,
      `G27⑥ 斷面唇的誠實話：唇與台紙合成之後的色差 ΔE ${LIP_DE.map((v) => v.toFixed(1)).join('–')}（JND ${HUE_DE_MIN}）—— **顏色差得到**；而它只有 1 個裝置像素高，所以板被縮小看的時候**看不到**。兩件事分開講、都印在 Tokens 板上，不留給看板的人自己發現`,
      `最小 ΔE ${Math.min(...LIP_DE).toFixed(2)} 在 JND 以下 —— 那就真的是一個看不見的顏色，該拿掉而不是留著`);
  }
} else need('perf', 'G27 騎縫線');

/* ══ G28  版式的寬度階（第 5 輪 D4-06）════════════════════════════
   第 4 輪實測：156 個區塊只有 6 種寬度、72% 是同一個 342px；歡迎頁的出血自己
   證明了破欄有效，然後一次都沒有再用。「材質做滿、空間沒做」。
   兩條：① 每一張板至少兩種區塊寬度 ② 掛牌的階要符合它自己的定義。 */
if (M.widths && M.ranks) {
  const thin = Object.entries(M.widths).filter(([, w]) => w.kinds < 2);
  const all = new Set(Object.values(M.widths).flatMap((w) => w.list));
  ok(thin.length === 0,
    `G28① 每板至少兩種區塊寬度：${Object.keys(M.widths).length} 張板全部通過，全稿共 ${all.size} 種區塊寬度（第 4 輪是 6 種）`,
    thin.map(([f, w]) => `${f} 只有 ${w.list.join('/')}`).join(' '));
  const bleed = M.ranks.filter((r) => r.rank === 'bleed'), note = M.ranks.filter((r) => r.rank === 'note');
  const bBad = bleed.filter((r) => r.delta !== 2 * FIX.gutter), nBad = note.filter((r) => r.delta !== -2 * SP.xl);
  ok(bleed.length > 0 && note.length > 0 && bBad.length === 0 && nBad.length === 0,
    `G28② 三階寬度各自成立：出血 ${bleed.length} 個（比它的容器內容盒寬 ${2 * FIX.gutter}px＝把版心的兩道 ${FIX.gutter}pt 邊界吃掉）、旁註 ${note.length} 個（窄 ${2 * SP.xl}px）、其餘一律欄寬`,
    [...bBad.map((r) => `${r.file} 出血差 ${r.delta}`), ...nBad.map((r) => `${r.file} 旁註差 ${r.delta}`)].slice(0, 6).join(' · '));
  ok(!/const noteBox = [\s\S]{0,320}?data-s="flat"/.test(src),
    'G28③ 說明框沒有皮：noteBox() 不再是一張平印卡（主體物件與幫助文字不得同寬同皮）—— 平印的皮從此只代表「這是一張真的印刷品」');
} else need('widths', 'G28 版式寬度階');

/* ══ G29  三格刻度讀得出來（第 5 輪 D4-01）════════════════════════
   第 4 輪 reviewer 遮住說明文字實測：五個狀態裡有三個狀態的刻度**逐格顏色一樣**（ΔE=0），
   因為未用格永遠畫 stub3、用掉的格永遠畫 stub0 —— 號碼帶走到第幾階從來沒有上刻度。
   這一條全部從 raw 重算（不吃 measure 算好的數，兩邊各自從同一份量測出發）。 */
if (M.scale && M.scale.length) {
  /* ① 銷記的覆蓋率是**板上那條 path** 算出來的（與 G26「板上畫的就是被量的那一份」同一招）*/
  const svgTag = /<svg ([^>]*data-cancel="stub"[^>]*)>(<path d="[^"]*"\/>)<\/svg>/.exec(read('InviteSpent.dc.html'));
  const vb = svgTag ? /viewBox="(-?[\d.]+) (-?[\d.]+) ([\d.]+) ([\d.]+)"/.exec(svgTag[1]) : null;
  const onBoard = svgTag && vb ? [null, null, null, vb[3], vb[4], svgTag[2]] : null;
  const cov = onBoard ? +(polyArea(onBoard[5]) / (+onBoard[3] * +onBoard[4])).toFixed(4) : null;
  ok(!!onBoard && cov === CANCEL_COV && M.cancelCov === CANCEL_COV,
    `G29① 銷記的墨量是量出來的：板上那一道 path 的多邊形面積佔格子的 ${(CANCEL_COV * 100).toFixed(2)}%，與 brush.mjs 算的、measure 用的同一個數`,
    onBoard ? `板上 ${cov} vs brush ${CANCEL_COV} vs measured ${M.cancelCov}` : 'InviteSpent 上找不到銷記');
  /* ② 逐格對位、逐態比：全部重算 */
  const at2 = (mode, u) => M.scale.find((r) => (r.dark ? 'dark' : 'light') === mode && r.uses === String(u));
  const perCell = (a, b) => a.cells.map((c, j) => +dERgb(cellSeen(c, CANCEL_COV), cellSeen(b.cells[j], CANCEL_COV)).toFixed(2));
  const bad = [], seen = [];
  for (const mode of ['light', 'dark']) {
    for (let i = 0; i < STUB_USES.length - 1; i++) {
      const a = at2(mode, STUB_USES[i]), b = at2(mode, STUB_USES[i + 1]);
      if (!a || !b) { bad.push(`${mode} 缺 ${STUB_USES[i]}→${STUB_USES[i + 1]} 的樣本`); continue; }
      const mx = Math.max(...perCell(a, b));
      seen.push(`${mode} ${STUB_USES[i]}→${STUB_USES[i + 1]} ${mx}`);
      if (mx < SCALE_DE.adj) bad.push(`${mode} ${STUB_USES[i]}→${STUB_USES[i + 1]} 逐格最大 ΔE 只有 ${mx}（門檻 ${SCALE_DE.adj}）—— 遮住文字看不出換了狀態`);
    }
    const a = at2(mode, STUB_USES[0]), z = at2(mode, STUB_USES.at(-1));
    if (a && z) {
      const mn = Math.min(...perCell(a, z));
      seen.push(`${mode} 剛印好↔用完了 最小 ${mn}`);
      if (mn < SCALE_DE.ends) bad.push(`${mode} 剛印好↔用完了，最小的那一格只有 ΔE ${mn}（門檻 ${SCALE_DE.ends}）`);
    }
  }
  ok(bad.length === 0, `G29② 遮住文字也讀得出來：逐格對位比，${seen.join('；')}（門檻 相鄰 ${SCALE_DE.adj}／兩端 ${SCALE_DE.ends}）`, bad.join(' · '));
  /* ③ 刻度就是帶子：未用格與號碼帶同一支漸層，ΔE→0 */
  const bandBad = [];
  for (const r of M.scale) {
    if (!r.band) continue;
    for (const c of r.cells) {
      if (c.state !== 'left') continue;
      const d = dERgb(c.bg, r.band);
      if (d > SCALE_DE.band) bandBad.push(`${r.file} 未用格對號碼帶 ΔE ${d.toFixed(2)}`);
    }
  }
  ok(bandBad.length === 0,
    `G29③ 刻度＝帶子：${M.scale.filter((r) => r.band).length} 組有票根的刻度，未用格與號碼帶是同一支漸層（實測 ΔE ≤ ${SCALE_DE.band}，第 4 輪未用格永遠是 stub3，帶子走到第幾階刻度上看不到）`,
    bandBad.slice(0, 4).join(' · '));
} else need('scale', 'G29 三格刻度');

/* ══ G30  玻璃與紙的交界：板上自己承諾的三條規則（第 5 輪 D4-11）════
   第 4 輪：那張板寫著「三條可以被咬的規則（第 4 輪要變成斷言）」—— 而它們一直是文字。 */
if (M.glass && M.glass.length) {
  const OKUNDER = ['paper', 'glassDim', 'seamMark'];
  const bad1 = M.glass.filter((g) => g.under.some((u) => !OKUNDER.includes(u)));
  ok(bad1.length === 0,
    `G30① 玻璃上的字，底下只能是台紙：${M.glass.length} 片玻璃，與它相交而且真的上色的東西只有 ${OKUNDER.join('／')}（glassDim 是玻璃自己的壓暗層、seamMark 是這張板的標註線，兩者都印在板上）`,
    bad1.map((g) => `${g.file} 底下有 ${g.under.join('/')}`).join(' · '));
  const bad2 = M.glass.filter((g) => g.nearRaise !== null && g.nearRaise < SP.l);
  ok(bad2.length === 0,
    `G30② 交界 ${SP.l}pt 之內沒有我們的浮起面：實測最近的一個 ${M.glass.map((g) => (g.nearRaise === null ? '無' : `${g.nearRaise}px`)).join('／')}（交界線的 y 是量出來的，不是寫死的）`,
    bad2.map((g) => `${g.file} 只差 ${g.nearRaise}px`).join(' '));
  ok(M.glass.every((g) => g.textN > 0),
    `G30③ 兩片玻璃上都真的有字（沒有字就沒有「玻璃上的對比」這回事，規則①會變成空的）：${M.glass.map((g) => g.textN).join('／')} 個文字節點`);
} else need('glass', 'G30 玻璃交界');

/* ══ G31  深色的照片少一格光（第 5 輪 D4-03）══════════════════════
   第 4 輪實測 ΔRGB −2.6：「這一稿蓋了一個有光源、有時間的世界，唯獨照片不在裡面。」 */
if (M.photo) {
  const P = M.photo, tol = PHOTO_STOP_TOL;
  ok(Math.abs(P.meanRatio - PHOTO_STOP) <= tol && Math.abs(P.p99Ratio - PHOTO_STOP) <= tol,
    `G31① 夜裡少一格光：逐像素實測，深色版對淺色版平均亮度比 ${P.meanRatio}、p99 比 ${P.p99Ratio}（一格＝${PHOTO_STOP}，容差 ±${tol}）`,
    `mean ${P.meanRatio} / p99 ${P.p99Ratio}`);
  const night = (M.photoPix || []).filter((r) => r.mode === 'night'), day = (M.photoPix || []).filter((r) => r.mode === 'day');
  ok(night.length > 0 && day.length > 0
    && night.every((r) => r.filter.includes(String(PHOTO_DIM))) && day.every((r) => r.filter === 'none'),
    `G31② 光是加在照片上的、不是加在別的地方：深色板 ${night.length} 張的 computed filter 都是 brightness(${PHOTO_DIM})，淺色板 ${day.length} 張一律 none`,
    [...night.filter((r) => !r.filter.includes(String(PHOTO_DIM))).map((r) => `${r.file} ${r.filter}`), ...day.filter((r) => r.filter !== 'none').map((r) => `${r.file} ${r.filter}`)].join(' '));
  ok(Math.abs(PHOTO_DIM - PHOTO_STOP ** (1 / 2.2)) < 0.005,
    `G31③ ${PHOTO_DIM} 是推出來的不是調出來的：sRGB 的 brightness() 是通道乘法，一格（亮度剩 ${PHOTO_STOP}）＝${PHOTO_STOP}^(1/2.2)＝${(PHOTO_STOP ** (1 / 2.2)).toFixed(4)}`);
} else need('photo', 'G31 深色照片');

/* ══ G32  登入鍵組的標籤（第 5 輪 D4-05；第 6 輪 D5-01 母體擴到第三顆）══════
   第 4 輪：AX5 下兩顆品牌鍵都只剩「登入」二字 —— 等高達標但語意塌。
   第 5 輪修了那兩顆，**但母體宣告寫的是「品牌鍵」** —— 我們自己那顆 Email 不是品牌鍵，
   於是它跟著掉成「登入」而 G32 的每一條都看不到它：三顆鍵的最後一顆，
   沒有商標、沒有無障礙名稱、讀螢幕唸出來就是「登入」。母體現在是**登入鍵組的每一顆**。 */
const SIGNIN_TEXT = {
  apple: { full: '透過 Apple 登入', brand: 'Apple 登入', short: '登入' },
  google: { full: '透過 Google 登入', brand: 'Google 登入', short: '登入' },
  email: { full: '用 Email 登入', brand: 'Email 登入', short: 'Email 登入' },
};
if (M.brandLab && M.brandLab.length) {
  const wrap = M.brandLab.filter((b) => b.lines !== 1), over = M.brandLab.filter((b) => b.over >= 0);
  ok(wrap.length === 0 && over.length === 0,
    `G32① 每一顆都不折行也不溢出：${M.brandLab.length} 顆登入鍵（Apple／Google／Email 三種都在母體裡），全部一行，最擠的一顆還剩 ${-Math.max(...M.brandLab.map((b) => b.over))}px`,
    [...wrap.map((b) => `${b.file}/${b.brand} 折了 ${b.lines} 行`), ...over.map((b) => `${b.file}/${b.brand} 溢出 ${b.over}px`)].join(' '));
  const cell = (who, tt) => M.brandLab.filter((b) => b.brand === who && b.title === tt);
  const kinds = Object.keys(SIGNIN_TEXT);
  const holes = kinds.flatMap((w) => ['full', 'brand', 'short'].filter((tt) => cell(w, tt).length === 0).map((tt) => `${w}|${tt}`));
  ok(holes.length === 0,
    `G32② 三顆 × 三階都真的畫出來了：${kinds.map((w) => `${w} ${['full', 'brand', 'short'].map((tt) => cell(w, tt).length).join('/')}`).join('、')}（順序 full／brand／short）`,
    holes.length ? `缺 ${holes.join('、')}` : '');
  /* 第 5 輪這一條只驗兩顆品牌鍵的字面。現在逐顆對規格表 —— 而規格表對三顆各有一列，
     所以「AX5 的第三顆是什麼字」是被寫死驗的，不是被順便放過的。 */
  const wrongText = M.brandLab.filter((b) => SIGNIN_TEXT[b.brand] && b.text !== SIGNIN_TEXT[b.brand][b.title]);
  ok(wrongText.length === 0 && M.brandLab.every((b) => !!SIGNIN_TEXT[b.brand]),
    `G32③ 每一顆的每一階都照規格表：借來的兩顆走它們自己的短標題（AX5「登入」），我們自己那顆 AX4／AX5 都是「${SIGNIN_TEXT.email.short}」—— 三階的字面逐格對表`,
    [...wrongText.map((b) => `${b.file}/${b.brand}@${b.title} 印的是「${b.text}」`),
      ...M.brandLab.filter((b) => !SIGNIN_TEXT[b.brand]).map((b) => `${b.brand} 不在規格表上`)].join(' · '));
  /* ④ 兩條示範行：一條放不下（所以換短標題）、一條放得下（所以不換）。
        「第三顆不縮」因此是算術不是通融 —— 兩個數都由 probe 在真瀏覽器裡量。 */
  const fitG = (M.axFit || []).find((x) => x.id === 'ax5-google');
  const fitE = (M.axFit || []).find((x) => x.id === 'ax5-email');
  ok(!!fitG && fitG.short > 0 && !!fitE && fitE.short < 0,
    `G32④ 換不換短標題是量出來的：AX5 同一階字級下「Google 登入」需要 ${fitG ? fitG.need : '?'}px、那顆鍵剩 ${fitG ? fitG.room : '?'}px（差 ${fitG ? fitG.short : '?'}px，放不下）；「Email 登入」需要 ${fitE ? fitE.need : '?'}px、那顆鍵剩 ${fitE ? fitE.room : '?'}px（還有 ${fitE ? -fitE.short : '?'}px 沒用到，放得下）。兩條示範行都畫在板上`,
    [!fitG ? '找不到 ax5-google 示範行' : '', !fitE ? '找不到 ax5-email 示範行' : '',
      fitE && fitE.short >= 0 ? `Email 也放不下了（差 ${fitE.short}px）—— 那就該重新裁「第三顆要不要縮」` : ''].filter(Boolean).join(' '));
  /* ⑤ WCAG 2.5.3 Label in Name：無障礙名稱必須**包含**畫面上看得到的字。
        用語音控制的人唸的是他看得到的那幾個字；名稱裡沒有那幾個字，他就按不到這顆鍵。
        第 5 輪三顆都掛 `使用 X 帳號登入`，在 AX4（可見「Apple 登入」）反而違反這一條。 */
  const nameBad = M.brandLab.filter((b) => !String(b.name || '').includes(b.text));
  const ariaWhere = M.brandLab.filter((b) => b.aria !== null && b.aria !== undefined);
  ok(nameBad.length === 0,
    `G32⑤ 可見文字是無障礙名稱的一部分（WCAG 2.5.3 Label in Name）：${M.brandLab.length} 顆逐顆比對，${ariaWhere.length} 顆有 aria-label（只有 AX5 的兩顆品牌鍵；其餘可見文字自己就是名稱）`,
    nameBad.map((b) => `${b.file}/${b.brand}@${b.title} 可見「${b.text}」不在名稱「${b.name}」裡`).join(' · '));
  ok(ariaWhere.every((b) => b.title === 'short' && b.brand !== 'email')
    && M.brandLab.filter((b) => b.title === 'short' && b.brand !== 'email').every((b) => b.aria),
    'G32⑤ aria-label 只出現在該出現的地方：可見文字塌成「登入」的那一階（AX5 的兩顆品牌鍵）一顆不漏，其餘一顆不多 —— 多掛的 aria-label 會蓋掉可見文字，那正是上一輪違反 2.5.3 的原因',
    ariaWhere.filter((b) => b.title !== 'short' || b.brand === 'email').map((b) => `${b.file}/${b.brand}@${b.title} 多掛了 aria-label`).join(' '));
  /* ⑥ 在不在無障礙樹裡（第 8 輪 D7-03）。第 5 輪 r5 抓到的那一顆 Email 鍵是個
     **沒有 role 的 div** —— 名稱算得出來、可見文字對得上，而 VoiceOver 根本找不到它。
     第 6 輪把 role 補上了，但補上這件事沒有任何一條 gate 在看：下一次誰刪掉它，
     G32①–⑤ 一條都不會叫（它們數的是文字，不是「這顆鍵存不存在」）。
     順帶驗名稱**是從哪裡算出來的**：probe 現在照 accname 的順序認四個來源
     （aria-labelledby → aria-label → 內容 → title），沒有來源的一顆就是沒有名字。 */
  const roleBad = M.brandLab.filter((b) => b.role !== 'button');
  const fromBad = M.brandLab.filter((b) => !b.nameFrom || b.nameFrom === 'none');
  const froms = [...new Set(M.brandLab.map((b) => b.nameFrom))];
  ok(roleBad.length === 0 && fromBad.length === 0,
    `G32⑥ 三顆鍵都在無障礙樹裡：${M.brandLab.length} 顆逐顆帶 role="button"（它們是 div —— 沒有 role 就不是按鈕，第 5 輪 r5 的那一顆就是這樣消失的），而且每一顆的名稱都算得出來源（本稿用到 ${froms.join('／')}；probe 依 accname 順序認 aria-labelledby／aria-label／內容／title 四種）`,
    [...roleBad.map((b) => `${b.file}/${b.brand}@${b.title} 的 role 是「${b.role ?? '（沒有）'}」`),
      ...fromBad.map((b) => `${b.file}/${b.brand}@${b.title} 算不出名稱`)].join(' · '));
} else need('brandLab', 'G32 登入標籤');

/* ══ G20  畫布註記的數值同源（G18 的守備範圍擴到 canvas.json）══════
   第 3 輪 R1 只治了 Tokens 板，canvas.json 的 10 則註記沒跟著對帳：capAlign 印 27
   （實建 29）、開關「移到畫面最上面」（已否決的行為）、板高 1140（實為 1280）、
   呼吸帶整句過期 —— ios-dev 照抄註記就會實作出錯規格。三道檢查：
   ①「來源＋數字」的鍵值比對（FIX 名稱、板高、measured.json 的具名量）；
   ② 門檻只有 tokens.mjs 一個出處；
   ③ build.mjs 的註記模板不得手打規格數字（阿拉伯數字一律出自 ${}）。 */
{
  const cv = JSON.parse(read('canvas.json'));
  const notes = cv.annotations;
  const all = notes.map((a) => a.text).join('\n');

  // ① FIX 名稱後面接的數字必須等於 tokens.mjs（與 G18 同一套判法）
  {
    const wrong = [], hits = [];
    for (const [k, v] of Object.entries(FIX)) {
      for (const m of all.matchAll(new RegExp(`${k}\\s+(-?\\d+)`, 'g'))) {
        hits.push(`${k}=${m[1]}`);
        if (+m[1] !== v) wrong.push(`${k} 註記印 ${m[1]}、tokens.mjs 是 ${v}`);
      }
    }
    ok(wrong.length === 0 && hits.length > 0,
      `G20 註記同源（FIX）：註記裡具名的 FIX 常數 ${hits.join(' ') || '（一個都沒有 —— 這張檢查沒在守東西）'} 等於 tokens.mjs`,
      wrong.join(' · '));
  }

  // ② 具名量 → 出處。左邊是註記上的說法，右邊是它唯一的來源。
  const hOf = (f) => (cv.artboards.find((a) => a.file === f) || {}).h;
  const cite = [
    ['單人 (\\d+)px', (n) => n === hOf('InviteRequests.dc.html'), () => `canvas.json 的 InviteRequests 板高 ${hOf('InviteRequests.dc.html')}`],
    ['多人 (\\d+)px', (n) => n === hOf('InviteRequestsMany.dc.html'), () => `canvas.json 的 InviteRequestsMany 板高 ${hOf('InviteRequestsMany.dc.html')}`],
    ['都放不下 (\\d+)', (n) => n === 844, () => '真實螢幕高 844'],
    ['≤(\\d+)px', (n) => n === RULE.pause, () => `RULE.pause=${RULE.pause}`],
    ['尾段 >(\\d+)px', (n) => n === RULE.pause, () => `RULE.pause=${RULE.pause}`],
    ['落在畫面 (\\d+)% 以內', (n) => n === RULE.btnPct, () => `RULE.btnPct=${RULE.btnPct}`],
    ['y=(\\d+)', (n) => (M.toggles || []).every((t) => t.top === n), () => `measured.toggles=[${(M.toggles || []).map((t) => t.top).join(',')}]`],
    ['(\\d+) 個使用點', (n) => n === M.insetTotal, () => `measured.insetTotal=${M.insetTotal}`],
    ['白名單有 (\\d+) 個角色', (n) => n === Object.keys(M.insetUse || {}).length, () => `measured.insetUse 有 ${Object.keys(M.insetUse || {}).length} 個 key`],
    ['(\\d+) 道錯誤線', (n) => n === M.errCount, () => `measured.errCount=${M.errCount}`],
    ['距離最小 (\\d+)px', (n) => n === M.errGap, () => `measured.errGap=${M.errGap}`],
    ['重合 (\\d+) 處', (n) => n === M.errOverlap, () => `measured.errOverlap=${M.errOverlap}`],
    ['(\\d+) 段掛牌', (n) => n === (M.pauses || []).length, () => `measured.pauses=${(M.pauses || []).length}`],
    ['(\\d+) 段未掛牌', (n) => n === (M.pauseBad || []).length, () => `measured.pauseBad=${(M.pauseBad || []).length}`],
    ['欄內最大 (\\d+)px', (n) => n === M.maxVoidPad, () => `measured.maxVoidPad=${M.maxVoidPad}`],
    ['漸層 (\\d+) 處', (n) => n === (M.grad || {}).total, () => `measured.grad.total=${(M.grad || {}).total}`],
    ['(\\d+) 種寫法', (n) => n === (M.grad || {}).kinds, () => `measured.grad.kinds=${(M.grad || {}).kinds}`],
    ['非垂直 (\\d+) 處', (n) => n === (M.grad || {}).badDir, () => `measured.grad.badDir=${(M.grad || {}).badDir}`],
    ['上的字 (\\d+) 個節點', (n) => n === (M.grad || {}).textOn, () => `measured.grad.textOn=${(M.grad || {}).textOn}`],
  ];
  {
    const wrong = [], unseen = [];
    for (const [re, test, why] of cite) {
      const hits = [...all.matchAll(new RegExp(re, 'g'))];
      if (!hits.length) { unseen.push(re); continue; }
      for (const m of hits) if (!test(+m[1])) wrong.push(`「${m[0]}」≠ ${why()}`);
    }
    ok(wrong.length === 0 && unseen.length === 0,
      `G20 註記同源（具名量）：${cite.length} 條「說法→出處」全部對得上（板高、呼吸帶門檻、開關 y、實測量）`,
      [...wrong, ...unseen.map((r) => `${r} 在註記裡找不到（改了文案就要改這張表）`)].join(' · '));
  }

  // ③ build.mjs 的註記模板不得手打規格數字。例外只有三個，都印在這裡。
  {
    const start = src.indexOf('annotations: [');
    const end = src.indexOf('  pages: [', start);
    const block = src.slice(start, end);
    // 級名（AX3／AX5／H1）、gate 代號（G23②）、歷史敘述、票號 —— 都是標籤，不是規格數字
    const LIT_OK = [/AX[35]/g, /H1/g, /G\d+[①②③④⑤⑥⑦⑧⑨]?/g, /\bR\d+/g, /第 [1234567] 輪/g, /LS-\d+/g];
    const bad = [];
    for (const m of block.matchAll(/text: `/g)) {
      let i = m.index + m[0].length, depth = 0, lit = '';
      for (; i < block.length; i++) {
        const c = block[i];
        if (depth === 0 && c === '`') break;
        if (depth === 0 && c === '$' && block[i + 1] === '{') { depth = 1; i++; continue; }
        if (depth > 0) { if (c === '{') depth++; else if (c === '}') depth--; continue; }
        lit += c;
      }
      let rest = lit;
      for (const re of LIT_OK) rest = rest.replace(re, '');
      const digits = rest.match(/\d/g);
      if (digits) bad.push(`…${rest.slice(Math.max(0, rest.search(/\d/) - 12), rest.search(/\d/) + 8)}…`);
    }
    ok(bad.length === 0,
      `G20 註記無手打數字：${notes.length} 則註記的模板裡，阿拉伯數字一律出自 \${}（例外只有 AX3／AX5／H1 級名、G23／R6 這類 gate 與 finding 代號、「第 N 輪」這種歷史敘述、LS 票號）`,
      bad.join(' | '));
  }
}

/* ══ G21  產物與量測同版（防 build↔measure 的一輪陳舊窗口）══════
   第 4 輪 reviewer 實測重現：改了畫面後只跑一輪，板上印著上一版的實測句
   （板印 96.8%／實測 91.1），G1–G19 卻全部通過 —— 因為沒有人比對「板上的數字
   是哪一次量的」。build.mjs 現在把當次讀到的 measured.json 指紋蓋進每一張產物，
   這裡拿現行 measured.json 的指紋比對。不一致＝再跑一次 build（要跑到收斂）。 */
{
  const stamps = files.map((f) => [f, (/<!-- ls-measured:([a-z0-9-]+) -->/.exec(read(f)) || [])[1]]);
  const missing = stamps.filter(([, s]) => !s).map(([f]) => f);
  const uniq = [...new Set(stamps.map(([, s]) => s))];
  const now = measStamp(MEAS_RAW);   // 與 build 蓋章用同一個函式（root 欄位排除，見 D4-09）
  ok(missing.length === 0 && uniq.length === 1,
    `G21 產物同版：${files.length} 張板都蓋了量測指紋，而且是同一次 build 的（${uniq.join('/')}）`,
    [...missing.map((f) => `${f} 沒蓋章`), uniq.length > 1 ? `指紋不只一種：${uniq.join(' ')}` : ''].filter(Boolean).join(' '));
  ok(uniq.length === 1 && uniq[0] === now,
    `G21 產物同版：板上印的實測句出自現行 measured.json（#${now}）`,
    uniq[0] !== now ? `板上是 #${uniq[0]}、現行是 #${now} —— 板上的實測數字是上一版的，重跑 node build.mjs` : '');

  /* G21b（第 1 輪 R9）：這一份量測是在哪一個根目錄上量的。
     上一輪 measure 的預設埠指向軌 B 的根目錄，而兩軌的檔名與欄位完全相容 ——
     量到別人的畫面時 measured.json 長得毫無異狀，所有 gate 會全綠地放行別人的設計。
     build 把軌別＋板清單指紋寫成 _root.json，measure 開跑前抓 server 上的同名檔比對，
     這裡再比對一次「量測時記下的根目錄」＝「現在這一份產物」。 */
  const rootFile = at('_root.json');
  const local = existsSync(rootFile) ? JSON.parse(readFileSync(rootFile, 'utf8')) : null;
  ok(!!local && !!M.root && M.root.track === local.track && M.root.structFp === local.structFp && M.root.boards === local.boards,
    `G21b 量測來源：measured.json 是在本軌的根目錄上量的（${local ? `${local.track} 結構 #${local.structFp}／${local.boards} 板` : '_root.json 不見了'}）`,
    !local ? '沒有 _root.json —— 先跑 node build.mjs'
      : !M.root ? 'measured.json 沒有記下根目錄 —— 重跑 node measure.mjs'
        : `量測時是 ${M.root.track} 結構 #${M.root.structFp}（${M.root.boards} 板）`);

  /* G21c（第 3 輪 R9 第二版）：內容核對**有沒有真的跑過**。
     第 2 輪 reviewer 親自踩到的殘留 server 之所以能一邊印「核對 OK」一邊量別的目錄，
     是因為指紋只吃板清單。現在 measure 開跑前要三方對帳（server 的 _root.json、
     本地磁碟、瀏覽器真的 fetch 到的原文），任何一方不同就 exit 1。
     這裡驗的是那一關留下的憑證：measured.json 裡有 contentFp，而且它就是
     probe 回報的那一個。**它不會等於現在磁碟上的內容雜湊** —— 因為管線是
     build→measure→build，第二次 build 才把量到的數字印上板，內容必然變一次。
     這條邊界寫在這裡，不寫在註解以外的地方：G21c 管「有沒有查」，
     G21 的 ls-measured 鏈管「現在的板是不是從這一份量測建出來的」，兩條合起來才閉環。 */
  ok(!!M.root && /^[0-9a-f]{12}$/.test(M.root.contentFp || ''),
    `G21c 內容核對留下憑證：measured.json 記著量測當下三方對帳過的內容雜湊 #${(M.root || {}).contentFp}（server 的 _root.json ＝ 本地磁碟 ＝ 瀏覽器真的讀到的那 ${(M.root || {}).boards} 份原文）`,
    M.root ? `contentFp=${M.root.contentFp}` : 'measured.json 沒有 root');
  ok(/R\.contentFp !== local \|\| local !== localRoot\.contentFp/.test(readFileSync(at('measure.mjs'), 'utf8')),
    'G21c 三方對帳的程式還在 measure.mjs 裡（拿掉它，上面那個憑證就變成自報）');
}

/* ══ G17  截圖：尺寸、底部一致、**而且與現行產物同版**（第 5 輪 D4-08）══════
   第 4 輪：shot 排在第二次 build 之前，所以 PNG 永遠是「印上實測數字之前」的那一版 ——
   而 PNG 才是人真的會看的東西，它身上卻一條 gate 都沒有。兩道修法：
     ① run.mjs 把 shot 移到第二次 build 之後（截的是最終產物）
     ② 這裡逐張比對「截圖當下那張板的原文雜湊」與「現在磁碟上的」——
        順序被人改回去、或有人手動只重跑 build，這一條就會 FAIL。 */
{
  const SJ = at('shots.json');
  const S17 = existsSync(SJ) ? JSON.parse(readFileSync(SJ, 'utf8')) : null;
  if (S17) {
    ok(S17.sizeBad.length === 0, `G17 截圖尺寸：${S17.n} 張 PNG 的像素尺寸全部等於板的 w×h`, S17.sizeBad.join(' '));
    ok(S17.tailBad.length === 0, `G17 截圖底部 40px 與重渲染一致（最大差 ${S17.maxDiff}）`, S17.tailBad.join(' '));
    const drift = files.filter((f) => S17.srcFp[f] !== hash12(read(f)));
    ok(files.every((f) => S17.srcFp[f]) && drift.length === 0,
      `G17 截圖與產物同版：${files.length} 張 PNG 逐張比對「截圖當下的板原文雜湊」＝「現在磁碟上的」（第 4 輪截的是第二次 build 之前的板，PNG 上永遠印著上一版的實測數字）`,
      drift.length ? `${drift.slice(0, 4).join(' ')} 的 PNG 是別版產物截的 —— 重跑 node _shot.mjs（而且要在第二次 build 之後）`
        : files.filter((f) => !S17.srcFp[f]).join(' '));
  } else {
    console.log('SKIP  G17 截圖一致性 —— 先跑 node _shot.mjs');
    fail++;
  }
}

/* ══════════════════════════════════════════════════════════════════
   ══ meta-gate：三條「驗 gate 的 gate」（第 5 輪 D4-07）══
   第 4 輪 reviewer 的裁定寫得很清楚：meta-gate 要，但**不是「樣本數 > 0」** ——
   那擋不住那一輪任何一發突變。三條各自對應一種漏法：
     MG1 母體宣告：gate 沒說它應該看到哪些格 → 空的那一格永遠不會 FAIL（M1b／深色 ON）
     MG2 豁免登記：豁免是任意值、沒有清單 → 加一個屬性就能讓自己不被檢查（M1b）
     MG3 負面對照：沒有人證明 gate 對壞樣本會叫 → 全綠只證明沒人破壞（M2b／M8）
   ══════════════════════════════════════════════════════════════════ */

/* ── 母體宣告：每一條 gate 說出它的笛卡兒積，缺格 FAIL 並印出缺哪一格 ── */
{
  const kn = M.knobs || [];
  pop('G19b', { mode: ['light', 'dark'], state: ['ON', 'OFF'] },
    kn.map((k) => `${/Dark/.test(k.file) ? 'dark' : 'light'}|${k.on ? 'ON' : 'OFF'}`),
    '開關管的是「陌生人能不能直接看到孩子的照片」，四種組合都必須有一張板畫出來');
  pop('G12', { mode: ['dark'], motif: ['ticket', 'cells', 'errbar', 'switch'] },
    Object.keys(M.darkMotifs || {}).map((m2) => `dark|${m2}`),
    '深色不是換色票：四個母題都要在深色下被畫過一次');
  const ls = (M.light || {}).seen || [];
  pop('G24', { mode: ['light', 'dark'], surface: ['win', 'raise'] },
    ls.map((x) => `${x.dir > 0 ? 'light' : 'dark'}|${x.kind}`),
    '光的方向：凹與浮在兩個模式下各自都要有樣本（第 2 輪的 bug 正好只出現在深色的凹上）');
  pop('G23', { mode: ['light', 'dark'], stage: Object.keys(TEMP).filter((k) => k !== 'cta') },
    [T.light, T.dark].flatMap((th) => Object.keys(TEMP).filter((k) => k !== 'cta').map((k) => `${th.dir > 0 ? 'light' : 'dark'}|${k}`)),
    '四階台紙的溫度：每一階在兩個模式下都要被算過');
  /* G26 的笛卡兒積只在它真的在跑的時候宣告 —— 暫停中的 gate 宣告母體會變成
     「宣告了卻沒跑」（MG1③ 會咬），那正是我們要它咬的東西。暫停期間 G26 走 NOPOP。 */
  if (!ICON_SUSPEND) {
    const rows26 = Object.keys(Icon.APPEARANCE).flatMap((look) => Icon.SIZES.flatMap(([px]) => Icon.SCALES.map((sc) => `${look}|${px}|${sc}`)));
    pop('G26', { look: Object.keys(Icon.APPEARANCE), size: Icon.SIZES.map(([px]) => px), scale: Icon.SCALES },
      rows26.filter((r) => {
        const [look, px, sc] = r.split('|');
        const m2 = Icon.measureAt(+px, +sc, { fg: Icon.APPEARANCE[look].fg || T.light.ink, bg: Icon.TINT_BASE });
        return !!m2;
      }), '三種外觀 × 四個實際尺寸 × 兩個倍率：24 格全部要量，缺一格就是「那個尺寸沒有被驗過」');
  }
  pop('G27', { kind: ['joined', 'torn'], scale: ['base', 'ax'] },
    (M.perf || []).map((r) => `${r.kind.replace(/-[bt]$/, '')}|${Math.round(r.pitch / PERF_TILE) === PERF.pitch ? 'base' : 'ax'}`),
    '兩種切法（還沒撕／撕下來的）在一般字級與 AX 都要有樣本 —— 齒距綁 ax() 只有在 AX 板上才驗得到');
  pop('G29', { mode: ['light', 'dark'], uses: STUB_USES },
    (M.scale || []).filter((r) => r.uses !== 'blank').map((r) => `${r.dark ? 'dark' : 'light'}|${r.uses}`),
    '四個狀態在兩個模式下都要畫出來，否則「相鄰態讀得出來」在缺樣本的那一邊等於沒有驗');
  pop('G31', { mode: ['day', 'night'] }, (M.photoPix || []).map((r) => r.mode),
    '照片的光：白天與夜裡各要有一張，只有一張就沒有「比」這回事');
  /* 第 6 輪 D5-01：母體從「兩個品牌」改成**登入鍵組的每一顆**。
     母體宣告寫成「品牌鍵」的那一輪，第三顆就活在檢查之外 —— 它在 AX5 掉成「登入」，
     G32①②③ 一條都不會叫，因為它們數的是一個不含它的集合。 */
  pop('G32', { who: ['apple', 'google', 'email'], title: ['full', 'brand', 'short'] },
    (M.brandLab || []).map((b) => `${b.brand}|${b.title}`),
    '登入鍵組的每一顆 × 三階標籤：三顆都要在母體裡（第 5 輪母體只有兩顆品牌鍵，我們自己那顆因此沒有任何一條 gate 在看）');
  pop('G30', { mode: ['light', 'dark'] }, (M.glass || []).map((g) => g.mode),
    '玻璃交界：兩個模式各一支手機（深色的玻璃高光不跟著我們的 dir 翻，那正是要驗的事）');
  pop('G28', { rank: ['bleed', 'note'] }, (M.ranks || []).map((r) => r.rank),
    '版式的三階：出血與旁註各要真的用到（欄寬是預設，不掛牌）');

  /* MG1 的三條斷言排在**所有 gate 之後**才跑（見檔尾的 mg1()）——
     它要數「哪些 gate 真的跑過」，自己插隊就會把 MG2／MG3 數成沒跑過。 */
}

const mg1 = () => {
  const missing = POPS.map((P) => ({ P, miss: cells(P.dims).filter((c) => !P.seen.has(c)) })).filter((x) => x.miss.length);
  ok(missing.length === 0,
    `MG1① 母體宣告：${POPS.length} 條有笛卡兒積的 gate，共 ${POPS.reduce((a, P) => a + cells(P.dims).length, 0)} 格，每一格都有樣本`,
    missing.map((x) => `${x.P.gate} 缺 ${x.miss.join('、')}`).join(' · '));

  const declared = new Set([...POPS.map((P) => P.gate), ...Object.keys(NOPOP)]);
  const undeclared = [...RAN.keys()].filter((g) => !declared.has(g));
  ok(undeclared.length === 0,
    `MG1② 每一條跑過的 gate 都宣告了母體：${RAN.size} 個 gate 家族，${POPS.length} 個宣告笛卡兒積、${Object.keys(NOPOP).length} 個具名登記「母體是全集」的理由`,
    undeclared.length ? `${undeclared.join(' ')} 沒有宣告母體 —— 新增 gate 時要一起宣告，不然它可以永遠對著空集合印 PASS` : '');

  const deadPop = POPS.filter((P) => !RAN.has(P.gate)).map((P) => P.gate);
  const deadNo = Object.keys(NOPOP).filter((g) => !RAN.has(g));
  ok(deadPop.length === 0 && deadNo.length === 0,
    `MG1③ 沒有死掉的宣告：${declared.size} 條宣告全部對應到真的跑過的 gate（宣告了卻沒跑的 gate 是最舒服的假綠燈）`,
    [...deadPop, ...deadNo].join(' '));
};

/* ── 豁免登記：豁免集合**等於**具名清單（不是包含）── */
{
  const seen = new Set((M.exemptSeen || []).map((e) => `${e.marker}|${e.role}|${e.file}`));
  const want = new Set(EXEMPT.flatMap((e) => e.files.map((f) => `${e.marker}|${e.role}|${f}`)));
  const extra = [...seen].filter((x) => !want.has(x));
  const unused = [...want].filter((x) => !seen.has(x));
  ok(extra.length === 0 && unused.length === 0,
    `MG2① 豁免集合＝具名清單：登記簿 ${EXEMPT.length} 筆展開成 ${want.size} 個具名使用點（檔案＋角色＋理由），畫面上量到 ${seen.size} 個，兩邊是同一個集合`,
    [...extra.map((x) => `畫面上多了 ${x}（沒登記）`), ...unused.map((x) => `登記了卻沒用到 ${x}`)].join(' · '));
  ok((M.exemptBad || []).length === 0,
    `MG2② 不在清單上的豁免不生效：probe 只認登記簿上的 marker+role+板名，攔下 ${(M.exemptBad || []).length} 個未登記的豁免嘗試（第 4 輪 data-light 加任何值都能整個豁免 G24）`,
    (M.exemptBad || []).slice(0, 4).join(' · '));
  const thin = EXEMPT.filter((e) => !e.why || e.why.length < 30 || !e.gate);
  ok(thin.length === 0,
    `MG2③ 每一筆豁免都寫得出理由與它豁免的是哪一條 gate（${EXEMPT.map((e) => `${e.marker}=${e.role}→${e.gate}`).join('、')}）`,
    thin.map((e) => `${e.marker}=${e.role} 理由太短或沒寫豁免哪一條`).join(' '));
  /* probe 端真的照清單走（拿掉那段程式，上面三條就都變成自報）*/
  const probe = readFileSync(at('_probe.html'), 'utf8');
  ok(/EX\.some\(\(e\) => e\.marker === marker && e\.role === role && e\.files\.includes\(file\)\)/.test(probe)
    && /exemptOK\(n, 'data-sys', name\)/.test(probe),
    'MG2④ 登記簿真的接在量測上：_probe.html 的豁免判斷是「marker+role+板名都在 _exempt.json 上」，不是「有沒有這個屬性」');
  const markers = [...new Set(EXEMPT.map((e) => e.marker))];
  const inCode = [...new Set([...probe.matchAll(/exemptOK\(n, '([a-z-]+)'/g)].map((m2) => m2[1]))];
  /* 有兩種 marker 不走 probe 的 exemptOK —— 它們豁免的那條 gate 在原始碼端執行。
     「不走 probe」本身要具名，否則這一條會退化成「凡是我沒接上的就算例外」。 */
  const PROBE_FREE = {
    'data-cancel': 'G4 在原始碼端把銷記的 svg 剝掉再數朱 —— 那條 gate 讀的是 HTML 原文，不是 computed style',
    'data-veto': 'G26 族整族在 verify 端暫停（使用者否決字形 icon 概念）—— 豁免的對象是「這族 gate 跑不跑」，不是畫面上某個元素的某個屬性',
  };
  const orphan = markers.filter((m2) => !inCode.includes(m2) && !PROBE_FREE[m2]);
  ok(orphan.length === 0,
    `MG2⑤ 登記簿上的每一種 marker 都真的在豁免什麼：${inCode.join('／')} 由 probe 認；${Object.keys(PROBE_FREE).join('／')} 具名登記為「不走 probe」並寫出在哪裡生效`,
    `無主的 marker ${orphan.join('/')}（既沒接上 probe，也沒登記它在哪裡生效）`);

  /* ⑥ 凍結的反向鎖（第 8 輪 D7-03）。「這張板凍結在被否決的那一版」是這一筆豁免
     整整三族 gate 的理由 —— 而第 6 輪那句話沒有任何東西在守：板改了，豁免照樣生效。
     現在被否決版的內容雜湊釘在登記簿上，板一動這一條就紅。
     排除 ls-measured 戳記（那是量測版本章，不是這張板的內容）—— 不排除的話
     任何一次重新量測都會讓這一條紅，那不是「板改了」。 */
  const FROZEN = EXEMPT.filter((e) => e.frozen);
  const froBad = [], froSeen = [];
  for (const e of FROZEN) {
    const f = `${e.frozen.file}.dc.html`;
    if (!files.includes(f)) { froBad.push(`${e.frozen.file} 這張板不存在`); continue; }
    const now = createHash('sha256').update(read(f).replace(/<!-- ls-measured:[a-z0-9-]+ -->/g, '')).digest('hex');
    froSeen.push(`${e.frozen.file}#${now.slice(0, 12)}`);
    if (now !== e.frozen.sha256) froBad.push(`${e.frozen.file} 現在是 #${now.slice(0, 12)}、登記的被否決版是 #${String(e.frozen.sha256).slice(0, 12)} —— 板動了，這一筆豁免（${e.marker}="${e.role}"→${e.gate}）失效`);
  }
  ok(FROZEN.length > 0 && froBad.length === 0,
    `MG2⑥ 凍結的板釘著被否決版的內容雜湊：${FROZEN.length} 筆「整張板凍結」的豁免逐筆比對（${froSeen.join('、')}）—— 板一改，豁免當場失效。沒有這一條，「凍結在被否決的那一版」只是一句話，而它豁免掉的是 G26／G26b／G26c 整整三族`,
    froBad.join(' · '));
}

/* ══ G35  過期的句子要劃掉、不要刪掉（第 8 輪 D7-03）════════════════
   AppIcon 板頂有一條否決橫幅，第 6 輪它已經誠實地寫著「底下凡是寫著『與字標同一支筆』
   的段落，字面已經不成立」。第 7 輪 reviewer 的裁定：**那還是三句假話配一句免責聲明**。
   看板的人（ios-dev）讀到第 1742 行那句「App icon ＝ 同一支筆的芽」時，
   不會記得板頂三百字之前有一段但書。

   刪掉也不對 —— 刪掉的假話沒有人會記得它曾經被否決過（與 M2b 那一發樣本同一個道理）。
   所以：**逐句劃掉**（<s>），劃掉的理由寫在 data-expired 上，橫幅自己標成 note。
   這一條守的是「那個字串只准出現在過期標記裡」：
     ① 每一處「同一支筆」都落在 <s data-expired> 或 data-expired-note 之內
     ② 每一個 data-expired 都寫得出為什麼過期
     ③ 這個字串只出現在那張凍結的板上（別的板不准開始講同一句話） */
{
  const PHRASE = '同一支筆';
  /* 找出帶某個屬性的元素的範圍（同名標籤計數，所以巢狀也算得對）。 */
  const ranges = (html, tag, attr) => {
    const out = [];
    const open = new RegExp(`<${tag}(\\s[^>]*)?>`, 'g');
    for (const m of html.matchAll(open)) {
      if (!new RegExp(`\\b${attr}=`).test(m[0])) continue;
      let i = m.index + m[0].length, depth = 1;
      const step = new RegExp(`<${tag}(\\s[^>]*)?>|</${tag}>`, 'g');
      step.lastIndex = i;
      let t;
      while ((t = step.exec(html))) { depth += t[0][1] === '/' ? -1 : 1; if (!depth) break; }
      const av = new RegExp(`${attr}="([^"]*)"`).exec(m[0]);
      out.push([m.index, t ? t.index + t[0].length : html.length, av ? av[1] : '']);
    }
    return out;
  };
  const frozenFiles = EXEMPT.filter((e) => e.frozen).map((e) => `${e.frozen.file}.dc.html`);
  const stray = files.filter((f) => !frozenFiles.includes(f) && read(f).includes(PHRASE));
  const out = [], thinWhy = [];
  let struck = 0, notes = 0;
  for (const f of frozenFiles) {
    const html = read(f);
    const sTags = ranges(html, 's', 'data-expired');
    const nTags = ranges(html, 'span', 'data-expired-note');
    struck += sTags.length; notes += nTags.length;
    for (const [, , why] of [...sTags, ...nTags]) if (String(why).length < 20) thinWhy.push(`${f} 的過期標記沒寫出為什麼`);
    for (const m of html.matchAll(new RegExp(PHRASE, 'g'))) {
      const inside = [...sTags, ...nTags].some(([a, b]) => m.index > a && m.index < b);
      if (!inside) out.push(`${f}@${m.index} 的「${PHRASE}」不在過期標記裡`);
    }
  }
  /* ── 規線本身不准銷毀要保存的內容（第 10 輪 D9-02，G35 追加）─────────
     第 9 輪抓到：<s> 用瀏覽器內建 line-through 劃掉，它的預設位置落在 CJK 橫畫帶，
     把「同一支筆」裡三個「一」的那一橫吃掉，讀成「同⎯支筆」——規線把要保存的
     內容銷毀了。改成 build.mjs 的 helmet() 用 ::after 疊一條線在文字上面
     （s[data-expired] 關掉內建 line-through、s[data-expired]::after 畫規線），
     這裡驗四件事：
       ① s[data-expired] 自己有 text-decoration:none（真的關掉內建 line-through），
          而且**沒有 background**——規線不准畫在文字自己的背景上（那會被 probe
          的祖先鏈誤判成漸層使用點，對比也會被量成規線色而不是紙色，第 10 輪
          初版就是這樣把 AAA 從 7.12 量成 2.68）
       ② ::after 的規線粗細／垂直位置都出自具名 token（var(--ls-expired-rule-w/-y)），
          不是瀏覽器決定、也不是隨手寫的裸數字；且 y 落在 58–62% 的安全帶；
          而且不准用 linear-gradient()（即使兩端同色，這個字串本身就會被
          probe 當成漸層使用點）
       ③ 規線色與被劃文字色的 ΔE ≥ 登記簿現成的 JND（HUE_DE_MIN）——
          太接近會讀不出規線在哪，跟原本「讀不出字」是同一個可讀性家族 */
  const ruleBad = [];
  for (const f of frozenFiles) {
    const html = read(f);
    const ruleM = /s\[data-expired\]\{([^}]*)\}/.exec(html);
    const afterM = /s\[data-expired\]::after\{([^}]*)\}/.exec(html);
    if (!ruleM) { ruleBad.push(`${f} 找不到 s[data-expired] 的樣式`); continue; }
    if (!afterM) { ruleBad.push(`${f} 找不到 s[data-expired]::after 的規線疊圖`); continue; }
    const ruleCss = ruleM[1], afterCss = afterM[1];
    if (!/text-decoration:\s*none/.test(ruleCss)) ruleBad.push(`${f} 的規線樣式沒有關掉瀏覽器內建的 line-through（缺 text-decoration:none）`);
    if (!/var\(--ls-expired-rule-w\)/.test(afterCss)) ruleBad.push(`${f} 的規線粗細不是出自具名 token（缺 var(--ls-expired-rule-w)）`);
    if (!/var\(--ls-expired-rule-y\)/.test(afterCss)) ruleBad.push(`${f} 的規線垂直位置不是出自具名 token（缺 var(--ls-expired-rule-y)）`);
    /* 規線不能畫在 <s> 自己的 background 上：_probe.html 的 bgAt()／onGrad() 是
       逐元素走 backgroundColor／backgroundImage 的祖先鏈算文字對比與漸層清冊，
       畫在自己背景上會被誤判成「這段文字站在一支沒登記的漸層上」，而且背景
       疊在字底下會把對比直接量成規線色 vs 字色（不是紙色 vs 字色）。 */
    if (/background(-image)?:/.test(ruleCss)) ruleBad.push(`${f} 的 s[data-expired] 自己的樣式裡有 background——規線必須畫在 ::after 疊圖上，不能是這個元素自己的背景（會被 probe 的祖先鏈誤判成文字站在一支沒登記的漸層上，對比也會被量成規線色而不是紙色）`);
    if (/linear-gradient\(/.test(afterCss)) ruleBad.push(`${f} 的規線疊圖用了 linear-gradient()——即使兩端同色，這個字串本身就會被 probe 當成漸層使用點，改用純色 background`);
    const rootM = /:root\{([^}]*)\}/.exec(html);
    const yDecl = rootM ? /--ls-expired-rule-y:\s*([\d.]+)%/.exec(rootM[1]) : null;
    if (!yDecl) ruleBad.push(`${f} 的 :root 沒有宣告 --ls-expired-rule-y`);
    else { const y = +yDecl[1]; if (!(y >= 58 && y <= 62)) ruleBad.push(`${f} 的 --ls-expired-rule-y＝${y}%，沒有落在 CJK 橫畫帶的安全帶（58–62%）`); }
    const ruleColorM = /(?:^|;)\s*background:\s*(#[0-9A-Fa-f]{6})/.exec(afterCss);
    const textColorM = /(?:^|;)\s*color:\s*(#[0-9A-Fa-f]{6})/.exec(ruleCss);
    if (!ruleColorM || !textColorM) ruleBad.push(`${f} 的規線色或被劃文字色沒有寫成可讀的 hex（量不了 ΔE）`);
    else {
      const delta = dE(ruleColorM[1], textColorM[1]);
      if (!(delta >= HUE_DE_MIN)) ruleBad.push(`${f} 規線色 ${ruleColorM[1]} 與被劃文字色 ${textColorM[1]} 的 ΔE＝${delta.toFixed(2)}，沒有到 JND（${HUE_DE_MIN}）`);
    }
  }
  ok(struck >= 3 && notes >= 1 && out.length === 0 && thinWhy.length === 0 && stray.length === 0 && ruleBad.length === 0,
    `G35 過期的句子劃掉不刪掉：凍結板上 ${struck} 句「${PHRASE}」逐句 <s> 劃掉（每一句寫得出為什麼過期），另外 ${notes} 段是宣告它們過期的橫幅本身（標成 note，不劃）；這個字串在其他 ${files.length - frozenFiles.length} 張板上一次都沒有出現 —— 刪掉的假話沒有人會記得它曾經被否決過，所以留著，但留成劃掉的樣子。規線本身不用瀏覽器內建 line-through：粗細／位置出自具名 token，且與被劃文字的 ΔE 過 JND —— 規線不會反過來把要保存的內容吃掉`,
    [...out, ...thinWhy, ...stray.map((f) => `${f} 也開始講「${PHRASE}」了`), ...ruleBad].join(' · '));

  /* ── ④ 過期標記不准換行（第 12 輪 D11-02）─────────────────────────────
     ①②③的規線（::after 疊圖）是畫在文字上面的一條水平線，位置是相對整個
     <s> 元素算的（--ls-expired-rule-y）——這個假設只在文字**排成一行**的時候
     成立。真的排出兩行，規線只會疊在其中一行的高度上，另一行沒有規線，或
     規線飄到兩行的行間，看起來像浮在字外面的一條線，不再讀得出「這行字被
     劃掉了」。getClientRects() 在真瀏覽器的版面裡量：一行＝1 個矩形。 */
  if (M.expiredRects) {
    const wrapped = M.expiredRects.filter((r) => r.n !== 1);
    ok(M.expiredRects.length > 0 && wrapped.length === 0,
      `G35④ 過期標記不准換行：${M.expiredRects.length} 個 s[data-expired] 全部量到 1 個 getClientRects()（真排版的行框數）—— 換行會讓規線飄到行間，「劃掉」這件事本身就讀不出來了`,
      wrapped.map((r) => `${r.file} 的「${r.text}」排成 ${r.n} 行`).join(' · '));
  } else need('expiredRects', 'G35④ 過期標記換行鎖');
}

/* ══ MG4  門檻登記簿（第 6 輪 D5-02）═══════════════════════════════
   第 5 輪 reviewer 的判決寫得很乾淨：**門檻可以洗白**。把 CONTRAST.aaa 從 7 改成 4.5，
   一行改動，144 項 gate 全綠、selftest 14 發也全部照常轉紅 —— 因為負面對照咬的是
   「證據被弄壞」，沒有任何一發在問「這條線本來該畫在哪裡」。
   而且那 14 發是**點測試**：ΔE 從 8 掉到 0、對比從 12 掉到 1.1 —— 荒謬的值。
   一條門檻可以一路放寬到剛好放行現況，那些點測試一發都不會醒。

   三條，各對應一種「門檻沒有出處」的樣子：
     ① 有外部出處的 → 斷言到出處。門檻的值不只寫在 tokens.mjs，也寫在這張登記簿上，
        而且登記簿記著它出自哪一份標準。**兩邊不一致就 FAIL** —— 洗白因此不再是一行改動，
        而是「改兩個地方，並且親手刪掉一句引用 WCAG 的話」。
     ② 沒有外部出處的 → 配一發**落在門檻帶內**的負面樣本（≤1.3×）。
        把 MG3 從點測試升級成邊界測試：樣本的值就貼在門檻旁邊，不是荒謬值。

        ── 第 10 輪 D9-01 誠實化：上面這段原本接著寫「所以只要有人把門檻放寬
        一點點，那一發就會轉綠」—— 第 9 輪 reviewer 指出這句話對 ours 11 條
        結構上不成立：樣本與門檻同一個人在同一次改動裡一起寫，兩者一起下移，
        比值永遠貼著線，沒有一發會轉綠（甲／乙兩發完整重放都證實了這件事，
        見 thresholds.lock.json 的說明與 handoff 的攻擊重放表）。
        ②a 現在誠實地只驗兩件事——都不是「擋得住門檻被移動」：
          (a) 樣本真的貼著**現行**門檻（≤1.3×），不是舊值遺留下來的荒謬點測試；
          (b) 樣本真的會轉紅（MG3③ 驗），所以比較運算式本身（≤ 還是 <、
              方向對不對）沒有被悄悄改壞。
        「門檻的 value 本身被移動了沒有」現在由 ⑦／⑧ 兩條獨立的檢查頂
        （thresholds.lock.json 釘住首次登記的 value 與 wide 有無，不受同一次
        改動牽動）——兩層檢查各管各的，讀者不必再相信一句對 ours 不成立的話。
     ③ 可以推導的 → 寫成推導（G31③ 的 0.73 ＝ 0.5^(1/2.2) 是這一類的樣板）。
        推導式的門檻不需要出處也不需要邊界樣本：它沒有可以被調的自由度。

   ── 第 8 輪 D7-01：reviewer 把第 6 輪這三條逐條打穿，補牙五處 ──────────
     ① **讀值改用 import**。第 6 輪讀的是原始碼文字（正則），而正則看不穿註解：
        把真的那一行洗成 4.5，前面補一行 `// export const CONTRAST = { aaa: 7, ... };`，
        第一個 match 落在誘餌上 —— 154 項全綠，而 MG4① 正印著一句關於自己的假話。
        import 讀的是**真的被 export 的值**，而且對照複本也讀得到（LS_ROOT 指到哪就讀哪）。
     ② MG4① 的引文必須**含登記值**：一句「出自 WCAG」而不寫數字的引文，
        改門檻的時候不必動它。含了值，洗白就得親手把那個數從引文裡改掉。
     ⑤ **餘裕比從「門檻 vs 樣本」改成「門檻 vs 實測」**。第 6 輪那個比值是自我指涉的：
        門檻與樣本兩個數都在洗白者手上，一起往下移就永遠貼著。實測不在他手上
        （它是瀏覽器量回來的、或是整份色票算出來的），所以 6→4.5 之後
        實測 6.27 對門檻 4.5 ＝ 1.39 倍，登記的 1.05 當場對不上。
     ⑥ **文字↔值對帳推廣到全部 20 條**（G20 早就有這個機制，只是母體只有十分之一）：
        每一條登記的散文裡都要出現它的門檻值與它的實測值，兩個數都回頭比對。
        本輪它當場抓到兩句假話：跨距寫「15.4°」（實為 14.02）、顆粒寫「6.29」（實為 6.27）。
     ②b **六條「做不到邊界樣本」的缺口關掉了**。理由本來是「複本換不掉 gate import 進來的
        色票」—— 那是第 6 輪讀值方式的後果，不是事實。①之後整份色票也從複本 import，
        於是那六條也量得到實測、也做得出邊界樣本（bands.mjs 後半段那六發）。 */
/* 讀值：從**產物根目錄**動態 import。平常跑的時候它就是 gate 自己那一份；
   負面對照跑的時候它是被動過手腳的複本 —— 兩者都讀得到，而且讀到的是值不是文字。 */
const TK = await import(at('tokens.mjs').href);
const BD = (await import(at('bands.mjs').href)).BANDS;
const impNum = (path) => {
  const [name, key] = path.split('.');
  const v = key ? (TK[name] || {})[key] : TK[name];
  return typeof v === 'number' ? v : null;
};
/* 「寫成推導式了沒有」只能看文字（值一樣，形狀不一樣）。所以這一份文字**先把註解拿掉**
   —— 註解裡的宣告不是宣告，第 7 輪的誘餌就是靠這一點活的。 */
const noComment = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/[^\n]*/g, '$1');
const THRESH_SRC = { 'tokens.mjs': noComment(readFileSync(at('tokens.mjs'), 'utf8')), 'icon.mjs': noComment(readFileSync(at('icon.mjs'), 'utf8')) };
/* path 支援 `NAME` 與 `NAME.key` 兩種寫法，回傳原始碼裡那個宣告的原始文字
   （第 10 輪 D9-06：不再只判「是不是字面值」。第 9 輪的 A4b 打穿了舊版：
   `{ adj: 1 + 2, ... }` 不是純數字字面值，舊版就判它「是推導式」放行 ——
   可是 `1+2` 根本不是登記的那個推導（`3 * HUE_DE_MIN`），只是換了一張皮的
   任意字面值，攻擊者一樣有自由度可以調。現在直接回原始文字，由 ③ 去比對
   它是不是登記簿上 `expr` 那個具名形狀，不是「看起來像不像算式」。 */
const srcExpr = (file, path) => {
  const [name, key] = path.split('.');
  const decl = new RegExp(`export const ${name}\\s*=\\s*([^;]+);`).exec(THRESH_SRC[file]);
  if (!decl) return null;
  if (!key) return decl[1].trim();
  const m = new RegExp(`\\b${key}:\\s*([^,}]+)`).exec(decl[1]);
  return m ? m[1].trim() : null;
};
const normExpr = (s) => String(s || '').replace(/\s+/g, ' ').trim();
/* 散文裡的數字（⑥ 用）。比的是**數值**不是字串，所以引文寫 7.0:1 也對得上門檻 7。 */
const proseNums = (s) => [...String(s).matchAll(/\d+(?:\.\d+)?/g)].map((m) => +m[0]);
const says = (s, v) => proseNums(s).includes(v);
/* 實測證據（⑤⑥ 用）。色票那幾條走 TK（＝複本的色票），measured 那幾條走 M。 */
const gmOf = (th, k) => { const s = th.grad[k].filter(([c]) => /^#/.test(c)); const a = TK.lch(s[0][0]), b = TK.lch(s.at(-1)[0]); return a.h + TK.dHue(b.h, a.h) / 2; };
const dhOf = (th, k) => Math.abs(TK.dHue(TK.lch(th.grad[k].at(0)[0]).h, TK.lch(th.grad[k].at(-1)[0]).h));
const MODES = () => [TK.T.light, TK.T.dark];
const tempDev = () => Math.max(...MODES().flatMap((th) => Object.entries(TK.TEMP)
  .map(([k, want]) => Math.abs(TK.dHue(TK.lch(th[k]).h, TK.lch(th.board).h) - want))));
const hueTri = () => MODES().map((th) => {
  const p = gmOf(th, 'paper');
  return { cool: -TK.dHue(gmOf(th, 'win'), p), warm: Math.min(TK.dHue(gmOf(th, 'win3'), p), TK.dHue(gmOf(th, 'face'), p)), span: TK.dHue(gmOf(th, 'win3'), p) - TK.dHue(gmOf(th, 'win'), p) };
});
const voidMax = () => {
  const tagged = new Set((M.pauses || []).map((p) => `${p.file}|${p.col}`));
  const v = (M.voids || []).filter((x) => inScope('G10', x.file) && !tagged.has(`${x.file}|${x.col}`));
  return v.length ? Math.max(...v.map((x) => x.interior || 0)) : 0;
};
const btnPctMax = () => {
  const tails = new Set(M.boards.filter((b) => inScope('G10', b.file) && b.trail > TK.RULE.pause).map((b) => b.file));
  const rows = M.mainBtn.filter((b) => tails.has(b.file));
  return rows.length ? Math.max(...rows.map((b) => b.pct)) : 0;
};
/* 登記簿。kind：std（外部出處）／derived（推導）／ours（我們自己開的線，要邊界樣本）。
   evid ＝ 這條門檻**實際上被量到多少**：of 是那個量的名字、v 是登記的值、dp 是小數位、
   get() 現算一次。⑤ 拿它算餘裕比（門檻 vs 實測），⑥ 回頭比對散文裡寫的那個數。
   餘裕比 >1.3 的要寫 wide（為什麼故意不貼緊，而且那句話裡要寫出比值）。 */
const THRESHOLDS = [
  { id: 'CONTRAST.aaa', file: 'tokens.mjs', value: 7, kind: 'std', gate: 'G6', dir: 'min',
    evid: { of: '全稿最低的文字節點', v: 7.12, dp: 2, get: () => M.contrastMin },
    cite: 'WCAG 2.1 SC 1.4.6 Contrast (Enhanced)：一般大小的文字 7.0:1。這個數不是我們調的，是標準寫的。實測最低的文字節點 7.12:1 —— 餘裕只有 0.12，全稿最薄的一條。' },
  { id: 'SP.tap', file: 'tokens.mjs', value: 44, kind: 'std', gate: 'G14',
    cite: 'Apple HIG（Layout／Accessibility）：可點擊目標最小 44×44pt。' },
  { id: 'KNOB_CR', file: 'tokens.mjs', value: 3, kind: 'std', gate: 'G19b',
    cite: 'WCAG 2.1 SC 1.4.11 Non-text Contrast：識別 UI 元件所必需的視覺資訊 3.0:1（把手停在哪一端正是那種資訊）。' },
  { id: 'HUE_DE_MIN', file: 'tokens.mjs', value: 1.0, kind: 'std', gate: 'G23',
    cite: 'CIE ΔE*ab 的 JND ≈ 1.0 —— 低於它，兩個顏色人眼分不出來。這一條是全稿色差門檻的根。' },
  { id: 'PHOTO_STOP', file: 'tokens.mjs', value: 0.5, kind: 'std', gate: 'G31',
    cite: '攝影的「一格光」＝曝光量減半，亮度剩 0.5。單位是攝影自己的，不是我們定的。' },
  { id: 'PHOTO_DIM', file: 'tokens.mjs', value: null, kind: 'derived', gate: 'G31',
    how: 'PHOTO_STOP^(1/2.2) 取兩位小數＝0.73 —— sRGB 的 brightness() 是通道乘法，一格光在 CSS 裡就是這個數',
    expr: '+(PHOTO_STOP ** (1 / 2.2)).toFixed(2)',
    calc: () => +(TK.PHOTO_STOP ** (1 / 2.2)).toFixed(2), get: () => TK.PHOTO_DIM },
  { id: 'SCALE_DE.band', file: 'tokens.mjs', value: null, kind: 'derived', gate: 'G29',
    how: '1 × HUE_DE_MIN＝1 —— 「刻度與號碼帶是同一支漸層」＝ 兩者的差要落在人眼分不出來之內',
    expr: '1 * HUE_DE_MIN',
    calc: () => 1 * TK.HUE_DE_MIN, get: () => TK.SCALE_DE.band },
  { id: 'SCALE_DE.adj', file: 'tokens.mjs', value: null, kind: 'derived', gate: 'G29',
    how: '3 × HUE_DE_MIN＝3 —— 相鄰兩態要「一眼讀得出不一樣」，不是「盯著比才看得出來」',
    expr: '3 * HUE_DE_MIN',
    calc: () => 3 * TK.HUE_DE_MIN, get: () => TK.SCALE_DE.adj },
  { id: 'SCALE_DE.ends', file: 'tokens.mjs', value: null, kind: 'derived', gate: 'G29',
    how: '2 × SCALE_DE.adj＝6 —— 兩端之間隔了三步，每一步都要達到 adj，兩端至少是相鄰的兩倍',
    expr: '6 * HUE_DE_MIN',   // 概念上是 2×SCALE_DE.adj，但 tokens.mjs 實際寫的是化簡後的 6 * HUE_DE_MIN —— expr 比的是原始碼真正的樣子，不是 how 的敘事
    calc: () => 2 * TK.SCALE_DE.adj, get: () => TK.SCALE_DE.ends },
  { id: 'CONTRAST.grain', file: 'tokens.mjs', value: 6, kind: 'ours', gate: 'G22', dir: 'min',
    evid: { of: '顆粒層最暗的那一格', v: 6.27, dp: 2, get: () => M.grainMin },
    why: '顆粒層把底乘暗之後的下限 6。顆粒是每畫素的雜訊，最暗的那一格是極端值 —— 拿它當 AAA 門檻會逼整套色階失真，但它必須留在 AA（4.5）以上很多。實測最低 6.27。' },
  { id: 'PHOTO_STOP_TOL', file: 'tokens.mjs', value: 0.04, kind: 'ours', gate: 'G31', dir: 'max',
    evid: { of: '亮度比偏離「一格光」最遠的一個量（mean 與 p99 取大）', v: 0.01, dp: 3, get: () => Math.max(Math.abs(M.photo.meanRatio - TK.PHOTO_STOP), Math.abs(M.photo.p99Ratio - TK.PHOTO_STOP)) },
    why: '「少一格光」的容差 0.04。brightness() 是通道乘法而照片是實際像素，逐像素平均不會剛好落在 0.5；這是「看得出來是一格、而不是半格或兩格」的寬度。實測偏最遠的一個量是 0.010（mean 0.497／p99 0.490）。',
    wide: '餘裕比 4 倍 —— 這一條**刻意留寬**：容差守的是「照片有沒有真的暗一格」，而偏差的大小取決於那張照片的直方圖，不是取決於我們的設計。把門檻收到 0.013 只會讓「換一張照片」變成 gate 失敗，而換照片本來就該換。真正在守的是符號（是不是一格），不是精度。' },
  { id: 'RULE.pause', file: 'tokens.mjs', value: 120, kind: 'ours', gate: 'G10', dir: 'max',
    evid: { of: '流程板上最長的一段沒掛牌的連續空白', v: 104, dp: 0, get: () => voidMax() },
    why: '內容之間的連續空白上限 120px（手機 iPad 同一條）。超過的必須掛牌說理由 —— 這是意圖 gate 不是版面美學：大約是一個主按鈕加一段間距，再大就會讓長輩以為畫面到此為止。實測最長的一段沒掛牌的空白是 104px。' },
  { id: 'RULE.btnPct', file: 'tokens.mjs', value: 70, kind: 'ours', gate: 'G10', dir: 'max',
    evid: { of: '有尾段的流程板上，主按鈕中心最低的一個位置', v: 67.2, dp: 1, get: () => btnPctMax() },
    why: '主按鈕中心必須落在畫面高度的 70% 以內。出處是拇指可及範圍的常識值（單手持握 6.1 吋機身），不是量出來的 —— 所以它需要邊界樣本。實測最低的一顆在 67.2%。' },
  { id: 'SP.l', file: 'tokens.mjs', value: 16, kind: 'ours', gate: 'G30', dir: 'min',
    why: '玻璃與紙的交界 16pt 之內不得出現我們的浮起面（否則兩套光會疊在一起）。它取自間距階的 l，不是為這條 gate 挑的一個數 —— 但「為什麼是 l 不是 m」沒有外部出處，所以照樣要邊界樣本。',
    noEvid: '**沒有實測值可以量，而且那正是它通過的方式**：交界附近一個我們的浮起面都沒有（M.glass 兩列的 nearRaise 都是 null），所以沒有「最近的一個離多遠」這個數。這一條守的是「不要出現」，零使用點時餘裕比無定義 —— 它的牙全押在邊界樣本上（bands 那一發把 nearRaise 放到 13pt）。哪一天交界旁邊真的出現浮起面，這一欄就會有數，⑤ 會自動開始要求餘裕比。' },
  /* ── 判「規格本身」的那六條（第 8 輪 D7-01①：缺口關掉了）──────────────
     第 6 輪這六條登記成「做不到邊界樣本」，理由是「對照複本換不掉 gate import 進來的色票」。
     第 7 輪 reviewer 裁那個理由**不成立**：換不掉是因為第 6 輪用正則讀原始碼文字，
     而不是因為換不掉。①改成從產物根目錄 import 整份色票之後，這六條的實測值
     就跟其他條一樣是「從複本算出來的證據」—— 餘裕比量得到（⑤）、邊界樣本做得出來
     （bands.mjs 後半段那六發：把色票轉一個角度，讓算出來的值剛好落到門檻另一邊）。 */
  { id: 'TEMP_TOL', file: 'tokens.mjs', value: 3, kind: 'ours', gate: 'G23', dir: 'max',
    evid: { of: '四階台紙與宣告的 TEMP 差最遠的一階', v: 1.92, dp: 2, get: () => tempDev() },
    why: '四階台紙溫度（色相角）的容差 ±3°。sRGB 是 8 bit 的網格，宣告的角度找不到剛好可表示的點；這是「還讀得出同一階」的寬度。實測差最遠的一階是 1.92°（深色的 cta）。',
    wide: '餘裕比 1.56 —— 容差不是目標值，是「網格上找得到多近的點」的寬度。把它收到 1.92° 就等於宣稱「8 bit 網格保證能落在 1.92° 之內」，那不是我們能保證的事（換一個 L*／C* 就不成立）。留寬是對的，而寬多少現在寫在這裡，不再是「遠小於門檻」這種沒有數的話。' },
  { id: 'HUE_MIN.cool', file: 'tokens.mjs', value: 6, kind: 'ours', gate: 'G22', dir: 'min',
    evid: { of: '兩個模式裡「凹比台紙冷」最少的那一個', v: 9.31, dp: 2, get: () => Math.min(...hueTri().map((t) => t.cool)) },
    why: '開窗底（凹）比台紙冷的下限 6°。取在實測下方留餘裕，但遠高於「一個色相四個明度」會有的 0–5°。實測最少的一個模式是 9.31°（淺色；深色 10.80°）。',
    wide: '餘裕比 1.55 —— 門檻是「冷到什麼程度才算冷」的設計判斷，不是量出來的。把它往實測收，等於宣稱「凹一定要冷 9° 以上」，那會把未來所有配色都綁死在這一版的色票上。三條 HUE_MIN 統一用**比值尺**排序：span 1.17 < cool 1.55 < warm 1.57 —— 貼得最緊的是 span，不是 warm。' },
  { id: 'HUE_MIN.warm', file: 'tokens.mjs', value: 3, kind: 'ours', gate: 'G22', dir: 'min',
    evid: { of: '兩個模式裡「次要面比台紙暖」最少的那一個', v: 4.71, dp: 2, get: () => Math.min(...hueTri().map((t) => t.warm)) },
    why: '同上，暖的那一端，下限 3°。實測最少的一個是 4.71°（淺色；深色 4.81°）。暖端的絕對餘裕本來就比冷端薄 —— 這件事登記在這裡，不藏在註解裡。',
    wide: '餘裕比 1.57 —— 三條 HUE_MIN 之中**比值最鬆**的一條。第 6 輪這裡寫著「它與門檻最近，要補先補這一條」：那句話用的是絕對差（4.71−3＝1.71° 比 14.02−12＝2.02° 小），與同一段裡 span 用的比值尺**互相矛盾**，兩把尺混在一份登記簿裡給出了相反的指令。第 8 輪統一成比值尺（門檻之間的絕對度數本來就不可比：3° 的 1.71 與 12° 的 2.02 不是同一件事），排序見 cool 那一條。' },
  { id: 'HUE_MIN.span', file: 'tokens.mjs', value: 12, kind: 'ours', gate: 'G22', dir: 'min',
    evid: { of: '兩個模式裡「凹到次要面」的總跨距最小的那一個', v: 14.02, dp: 2, get: () => Math.min(...hueTri().map((t) => t.span)) },
    why: '冷端到暖端的總跨距，下限 12°。它不是 cool+warm 的和 —— 兩端各自對台紙量，跨距是兩端互相量。實測最小的一個模式是 14.02°（淺色；深色 15.61°）。第 6 輪這裡寫的是「15.4°／15.6°」——**那個 15.4 是假的**，淺色從來沒有到過 15.4；⑥ 的文字↔值對帳就是為了這種句子而寫的。' },
  { id: 'LIGHT_DH', file: 'tokens.mjs', value: 7, kind: 'ours', gate: 'G22', dir: 'max',
    evid: { of: '五支「光」的漸層裡，兩端色相差最大的一支', v: 6.53, dp: 2, get: () => Math.max(...MODES().flatMap((th) => TK.LIGHT_KEYS.map((k) => dhOf(th, k)))) },
    why: '「光」的漸層兩端色相差上限 7°。光只改明度不改色相；這是同一支光在 8 bit 網格上量得到的抖動上限。實測最大的一支是 6.53°（淺色 win）—— 餘裕比 1.07，全部門檻裡貼得最緊的一條。' },
  { id: 'TIME_DH', file: 'tokens.mjs', value: 15, kind: 'ours', gate: 'G22', dir: 'min',
    evid: { of: '兩支「時間」的漸層裡，兩端色相差最小的一支', v: 38.33, dp: 2, get: () => Math.min(...MODES().flatMap((th) => ['paper', 'stub3'].map((k) => dhOf(th, k)))) },
    why: '「時間」的漸層兩端色相差下限 15°。褪色會把染料抽走、露出泛黃的紙，所以它必須明顯改色相 —— 與 LIGHT_DH 的 7° 之間留一段不重疊的帶，兩族因此永遠分得開。實測最小的一支是 38.33°。',
    wide: '餘裕比 2.56 —— 這一條與 LIGHT_DH 是一對，門檻畫在哪裡是由**兩族不重疊**決定的（7 與 15 中間留 8° 的帶），不是由實測決定的。把它往 38.33° 收，帶就變成 7–38，那不是「分得開」而是「只准這一種褪色」。真正被守的那一句由 ②b 的附帶斷言直接驗。' },
];
{
  /* 邊界樣本讀的是**宣告**（bands.mjs），不是結果（selftest.json）。
     兩件事分開的理由是雞生蛋：baseline 要綠才跑得了對照，而對照的結果才讓 baseline 綠。
     「那一發真的轉紅了嗎」由 MG3③ 守（它本來就要求每一發都轉紅），這裡不重複。 */
  const bands = new Map();
  for (const b of BD) bands.set(b.of, b);
  const bad1 = [], bad2 = [], bad3 = [], dead = [];
  /* 死門檻判定（④）：搜尋前先把 THRESHOLDS 這個陣列字面值自己的原始碼區塊切掉
     （第 10 輪 D9-06）。舊版直接搜整份 verify.mjs，而 THRESHOLDS 的宣告本身就寫著
     `id: 'CONTRAST.aaa'` —— 搜尋永遠命中自己，判定因此恆真：一條門檻可以完全
     沒有任何 gate 邏輯在用它，這條檢查照樣印 PASS。切掉這個區塊之後，match
     只能來自**真正在用它**的 gate 邏輯（例如 G6 用 CONTRAST.aaa、G10 用
     RULE.btnPct…），不是登記簿對自己宣告的自我引用。 */
  const verifySrcNoReg = readFileSync(at('verify.mjs'), 'utf8').replace(/const THRESHOLDS = \[[\s\S]*?\n\];/, '');
  for (const th of THRESHOLDS) {
    if (!new RegExp(`\\b${th.id.split('.')[0]}\\b`).test(verifySrcNoReg)) dead.push(th.id);
    if (th.kind === 'derived') {
      const want = th.calc(), got = th.get();
      if (Math.abs(want - got) > 1e-9) bad3.push(`${th.id} 推導出 ${want}、實際是 ${got}`);
      /* ③：形狀比對（第 10 輪 D9-06）。舊版只判「原始碼裡是不是純數字字面值」——
         第 9 輪的 A4b 打穿它：`{ adj: 1 + 2, ... }` 不是純字面值，舊版就判它
         「是推導式」放行，但 1+2 根本不是登記的 `3 * HUE_DE_MIN`，只是換了張皮
         的任意字面值，攻擊者一樣有自由度可以調。現在直接比對原始碼文字是不是
         逐字元等於（忽略空白）登記簿上 `expr` 那個具名形狀。 */
      const raw = srcExpr(th.file, th.id);
      if (raw === null) bad3.push(`${th.id} 在 ${th.file} 裡找不到宣告`);
      else if (normExpr(raw) !== normExpr(th.expr)) bad3.push(`${th.id} 原始碼裡寫的是「${raw}」，登記簿的推導式形狀是「${th.expr}」—— 形狀對不上（換一個看起來像算式、實際上是任意字面值的假推導式，例如 1+2，就會被這裡咬）`);
      continue;
    }
    /* 值從 **import** 讀（第 8 輪 D7-01①）。第 6 輪讀的是原始碼文字，
       所以一行誘餌註解就能讓這裡讀到「原來那個值」而放行被洗白的真值。 */
    const now = impNum(th.id);
    if (now === null) { (th.kind === 'std' ? bad1 : bad2).push(`${th.id} 在 ${th.file} 裡 import 不到數值`); continue; }
    if (now !== th.value) {
      (th.kind === 'std' ? bad1 : bad2).push(`${th.id}：${th.file} export 的是 ${now}、登記簿寫 ${th.value}${th.kind === 'std' ? `（出處：${th.cite}）` : ''}`);
      continue;
    }
    if (th.kind === 'ours') {
      const smp = bands.get(th.id);
      if (!smp) { bad2.push(`${th.id} 沒有邊界樣本 —— 無外部出處的門檻必須有一發落在門檻帶內的負面對照`); continue; }
      const r = th.dir === 'min' ? th.value / smp.v : smp.v / th.value;
      if (!(r > 1 && r <= 1.3)) bad2.push(`${th.id} 的樣本值 ${smp.v} 離門檻 ${th.value} 太遠（比值 ${r.toFixed(2)}，要在 1–1.3 之間）—— 那是點測試不是邊界測試`);
    }
  }
  const std = THRESHOLDS.filter((t2) => t2.kind === 'std'), der = THRESHOLDS.filter((t2) => t2.kind === 'derived');
  const ours = THRESHOLDS.filter((t2) => t2.kind === 'ours');
  /* ①＋②（第 8 輪 D7-01②）：引文不只要存在，**還要寫得出那個數**。
     「出自 WCAG」而不寫值的引文，改門檻的時候一個字都不必動 —— 那不是出處，是背書。 */
  const citeBad = std.filter((t2) => !t2.cite || t2.cite.length < 20 || !says(t2.cite, t2.value));
  ok(bad1.length === 0 && citeBad.length === 0,
    `MG4① 有外部出處的 ${std.length} 條門檻，值與出處都對得上，而且**每一句引文裡都寫著那個值**：${std.map((t2) => `${t2.id}=${t2.value}`).join('、')}（把 tokens.mjs 裡任何一個改掉，這一條當場紅 —— 洗白得同時改掉引文裡的數字）`,
    [...bad1, ...citeBad.map((t2) => `${t2.id} 的引文裡找不到 ${t2.value} 這個數`)].join(' · '));
  ok(bad2.length === 0,
    `MG4②a 我們自己開的 ${ours.length} 條門檻，每一條都有一發**落在門檻帶內**（≤1.3×）而且真的轉紅的負面樣本：${ours.map((t2) => { const s3 = bands.get(t2.id); return `${t2.id}=${t2.value}→樣本 ${s3 ? s3.v : '無'}`; }).join('、')}`,
    bad2.join(' · '));
  /* ②b：第 6 輪這裡是一份「做不到邊界樣本」的缺口清單（六條色票門檻）。
     第 8 輪那六條補上了（①讓複本的色票也讀得到），所以這一條現在守的是
     **清單必須是空的**：想再往裡面放東西，就得先寫出為什麼做不到。
     附帶仍然驗那件真正被守著的事：光與時間兩族的門檻不重疊。 */
  const gapList = THRESHOLDS.filter((t2) => t2.kind === 'ours' && !t2.evid);
  const gapBad = gapList.filter((t2) => !t2.noEvid || t2.noEvid.length < 60);
  ok(gapBad.length === 0 && TK.LIGHT_DH < TK.TIME_DH,
    `MG4②b 量不到實測值的門檻只剩 ${gapList.length} 條（${gapList.map((t2) => t2.id).join('、') || '一條都沒有'}），而且它具名寫出為什麼量不到 —— 第 6 輪這裡有六條色票門檻登記著「做不到邊界樣本」，第 7 輪 reviewer 裁那個理由不成立（是讀值方式的後果，不是事實），第 8 輪六條全部補上。附帶斷言：光（≤${TK.LIGHT_DH}°）與時間（≥${TK.TIME_DH}°）兩族的門檻不重疊，中間留著 ${TK.TIME_DH - TK.LIGHT_DH}° 的帶`,
    [...gapBad.map((t2) => `${t2.id} 沒寫出量不到的理由`), TK.LIGHT_DH < TK.TIME_DH ? '' : `LIGHT_DH ${TK.LIGHT_DH} 與 TIME_DH ${TK.TIME_DH} 重疊了`].filter(Boolean).join(' · '));
  ok(bad3.length === 0,
    `MG4③ 可以推導的 ${der.length} 條門檻寫成推導式，沒有自由度可以被調：${der.map((t2) => `${t2.id}＝${t2.how.split(' —— ')[0]}`).join('；')}`,
    bad3.join(' · '));
  const thin = THRESHOLDS.filter((t2) => t2.kind === 'ours' && (!t2.why || t2.why.length < 40));
  ok(dead.length === 0 && thin.length === 0,
    `MG4④ 登記簿上沒有死掉的門檻：${THRESHOLDS.length} 條全部真的被 gate 用著（${std.length} 條有外部出處、${der.length} 條是推導、${ours.length} 條是我們自己開的線），而且每一條自己開的線都寫得出它為什麼畫在那裡`,
    [...dead.map((d) => `${d} 登記了卻沒有 gate 在用`), ...thin.map((t2) => `${t2.id} 沒寫理由`)].join(' · '));

  /* ── ⑤ 餘裕比：門檻 vs **實測**（第 8 輪 D7-01③）───────────────────
     第 6 輪的餘裕比是「門檻 vs 邊界樣本」—— 兩個數都在洗白者手上，一起往下移
     就永遠貼著（reviewer 的 N3c）。實測不在他手上：它是瀏覽器量回來的，
     或是整份色票算出來的。所以這裡改成：
       ① 實測值必須真的落在門檻的合格側（門檻 < 實測，或反向）
       ② 登記的實測值 ＝ 現算的實測值（登記簿不准對實測說謊）
       ③ 餘裕比 ≤1.3；超過的要具名寫 wide，而且**那句話裡要寫出比值** ——
          所以放寬門檻會讓比值變大、與 wide 裡寫的數對不上，當場紅。 */
  const withEvid = THRESHOLDS.filter((t2) => t2.evid);
  const mBad = [], shown = [];
  for (const th of withEvid) {
    const raw = th.evid.get(), v = +raw.toFixed(th.evid.dp);
    if (!Number.isFinite(raw)) { mBad.push(`${th.id} 的實測值算不出來`); continue; }
    if (v !== th.evid.v) { mBad.push(`${th.id} 登記的實測值 ${th.evid.v}、現算是 ${v}（${th.evid.of}）`); continue; }
    const r = th.dir === 'min' ? raw / th.value : th.value / raw;
    const rr = +r.toFixed(2);
    shown.push(`${th.id} ${th.value}／實測 ${v}＝×${rr.toFixed(2)}`);
    if (!(r > 1)) { mBad.push(`${th.id} 實測 ${v} 沒有落在門檻 ${th.value} 的合格側`); continue; }
    if (r > 1.3 && (!th.wide || th.wide.length < 60)) mBad.push(`${th.id} 餘裕比 ×${rr}（>1.3），要具名寫出為什麼故意不貼緊`);
    else if (r > 1.3 && !says(th.wide, rr)) mBad.push(`${th.id} 的 wide 裡沒有寫出比值 ${rr}`);
  }
  ok(mBad.length === 0,
    `MG4⑤ 餘裕比量的是「門檻 vs 實測」不是「門檻 vs 樣本」：${withEvid.length} 條門檻逐條現算實測、與登記簿對帳，全部落在合格側；${withEvid.filter((t2) => !t2.wide).length} 條貼著線（≤1.3×）、${withEvid.filter((t2) => t2.wide).length} 條具名登記為刻意留寬並寫出比值 —— ${shown.join('、')}`,
    mBad.join(' · '));

  /* ── ⑥ 文字↔值對帳，母體＝全部 20 條（第 8 輪 D7-01⑤）──────────────
     G20 早就有這個機制（註記裡的數字回頭比對出處），只是母體只有 canvas.json 的註記。
     推廣到登記簿：每一條的散文裡都要出現它的門檻值；有實測的還要出現實測值。
     本輪它當場抓到兩句假話 —— 跨距寫「15.4°」（實為 14.02）、顆粒寫「6.29」（實為 6.27）。
     比的是**數值**不是字串，所以引文寫 7.0:1 也對得上門檻 7。 */
  const pBad = [];
  for (const th of THRESHOLDS) {
    const prose = [th.cite, th.why, th.how, th.wide, th.noEvid].filter(Boolean).join(' ');
    const want = th.kind === 'derived' ? th.calc() : th.value;
    if (!says(prose, want)) pBad.push(`${th.id} 的說明裡沒有出現它的值 ${want}`);
    if (th.evid && !says(prose, th.evid.v)) pBad.push(`${th.id} 的說明裡沒有出現實測值 ${th.evid.v}（${th.evid.of}）`);
  }
  ok(pBad.length === 0,
    `MG4⑥ 文字↔值對帳，母體是全部 ${THRESHOLDS.length} 條（不是十分之一）：每一條的說明裡都寫得出它的門檻值，有實測的 ${withEvid.length} 條連實測值一起寫出來，兩種數都回頭比對 —— 散文裡的數字從此也是被驗的東西`,
    pBad.join(' · '));

  /* ── ⑦ 門檻凍結：value 的唯一權威不能是登記簿自己（第 10 輪 D9-01 甲／乙，P1a）──
     第 9 輪 reviewer 打穿的洞：登記簿的 value 與 tokens.mjs 互相對帳，但兩邊
     可以在同一次改動裡一起下移（甲：CONTRAST.grain 6→4.5 同時改 tokens.mjs 與
     這裡的 value；乙：RULE.btnPct 70→85）——改完兩邊仍然互相對得上，MG4①／②a
     看不出任何破綻。門檻的 value「有沒有被人動過」，唯一權威只有登記簿自己，
     這件事本身就是漏洞。
     thresholds.lock.json 釘住每一條門檻**第一次登記**的 value 與那次 commit 的
     sha。它擋不住「有 commit 權限的人什麼都能改」——這裡不假裝擋得住。它逼的是
     另一件事：不寫 moved 就是紅；寫了 moved 就必須交代 from／to 兩個數、哪一輪、
     哪個 reviewer、還有 ≥120 字寫清楚為什麼。洗白仍然做得到，但會在 diff 上
     長成一筆看得見的具名動議，不再是一行悄悄的數字替換 —— 與豁免簿、劃掉句
     同一套規矩：不禁止改變，禁止改變不留痕。 */
  const LOCK = JSON.parse(readFileSync(at('thresholds.lock.json'), 'utf8'));
  const lockBad = [];
  for (const th of THRESHOLDS) {
    const locked = LOCK[th.id];
    if (!locked) { lockBad.push(`${th.id} 沒有登記在 thresholds.lock.json 上`); continue; }
    if (th.value === locked.value) {
      if (th.moved) lockBad.push(`${th.id} 的 value 沒有真的變（還是 ${th.value}，跟 lock 一樣）卻掛著 moved 動議 —— 動議要對應真的發生的事`);
      continue;
    }
    const mv = th.moved;
    if (!mv) { lockBad.push(`${th.id}：登記簿 value＝${th.value}，lock 釘的是首次登記的 ${locked.value}，沒有 moved 動議 —— 門檻被移動了但沒有留下具名紀錄`); continue; }
    if (mv.from !== locked.value) lockBad.push(`${th.id} 的 moved.from＝${mv.from} 對不上 lock 釘的 ${locked.value}`);
    if (mv.to !== th.value) lockBad.push(`${th.id} 的 moved.to＝${mv.to} 對不上登記簿現在的 value ${th.value}`);
    if (!mv.round) lockBad.push(`${th.id} 的 moved 沒有寫哪一輪`);
    if (!mv.reviewer) lockBad.push(`${th.id} 的 moved 沒有具名 reviewer`);
    if (!mv.why || mv.why.length < 120) lockBad.push(`${th.id} 的 moved.why 少於 120 字（現在 ${mv.why ? mv.why.length : 0} 字）`);
    else if (!says(mv.why, mv.from) || !says(mv.why, mv.to)) lockBad.push(`${th.id} 的 moved.why 沒有把 from（${mv.from}）與 to（${mv.to}）兩個數都寫進理由裡`);
  }
  const movedCount = THRESHOLDS.filter((t2) => t2.moved).length;
  ok(lockBad.length === 0,
    `MG4⑦ 門檻凍結：${THRESHOLDS.length} 條全部對過 thresholds.lock.json，value 與首次登記時一致（掛著具名 moved 動議的有 ${movedCount} 條）—— 想放寬門檻，diff 上必須長出一筆具名動議（from／to／round／reviewer／≥120 字理由，兩個數都要寫進理由裡），不能是一行悄悄的數字替換`,
    lockBad.join(' · '));

  /* ── ⑧ wide 凍結：原本沒有 wide 的門檻不准長出 wide（第 10 輪 D9-01 甲，P1c）──
     單靠 ⑦ 還留一條路：把門檻與登記簿一起下移、掛一筆看起來合理的 moved 動議，
     再幫餘裕比補一句含比值的 wide——⑦ 會綠（動議寫得出來），⑤ 也會綠（wide 裡
     寫了比值）。這正是第 9 輪甲那條路：CONTRAST.grain 6→4.5 之後餘裕比變成
     ×1.39（>1.3），只要肯掰一句合理的 wide，⑤ 就不再攔它。
     這裡把那條路也堵掉：lock 釘著每一條門檻**當初有沒有 wide**，沒有的以後也
     不准長出來。代價是誠實的：某天真的需要幫一條原本沒有 wide 的門檻補上 wide，
     那不是改這裡放行——是先去改 lock，讓「這條門檻本來沒有 wide」這件事本身
     也變成一筆看得見的動議，而不是悄悄地多一句藉口。 */
  const wideBad = THRESHOLDS.filter((th) => LOCK[th.id] && !LOCK[th.id].wide && !!th.wide)
    .map((th) => `${th.id} 在 lock 上原本沒有 wide，現在長出一句「${th.wide.slice(0, 24)}…」—— 餘裕比放寬常走「補 wide」這條路，這裡先堵住`);
  const noWideLocked = THRESHOLDS.filter((t2) => LOCK[t2.id] && !LOCK[t2.id].wide).length;
  ok(wideBad.length === 0,
    `MG4⑧ wide 凍結：lock 上原本沒有 wide 的 ${noWideLocked} 條，現在也都還是沒有`,
    wideBad.join(' · '));

  /* ── ⑨ probe 原始碼裡的字面門檻要對得上登記簿（第 10 輪 D9-04）──────────
     _probe.html 在瀏覽器裡跑，量對比與顆粒時各自寫死一個數（`if (v < 7)`、
     `if (gv < 6)`）——「單一 token 來源」在這兩條上其實是假的：改 tokens.mjs
     的 CONTRAST.aaa／grain 不會讓 probe 的判斷跟著變，兩邊可以各自漂移而全部
     gate 照樣綠（因為 gate 讀的是 probe 吐出來的 fails 陣列，不是重新算一次）。
     probe 是純瀏覽器腳本、沒有打包，不能直接 import tokens.mjs，所以這裡改成
     **驗原始碼文字**：那兩個字面值必須逐字元等於 CONTRAST.aaa／CONTRAST.grain。 */
  const probeSrc = readFileSync(at('_probe.html'), 'utf8');
  const probeAaa = /if\s*\(v\s*<\s*([\d.]+)\)/.exec(probeSrc);
  const probeGrain = /if\s*\(gv\s*<\s*([\d.]+)\)/.exec(probeSrc);
  const probeBad = [];
  if (!probeAaa) probeBad.push('_probe.html 找不到對比判斷 if (v < …)');
  else if (+probeAaa[1] !== CONTRAST.aaa) probeBad.push(`_probe.html 的對比判斷寫死 ${probeAaa[1]}，CONTRAST.aaa 登記的是 ${CONTRAST.aaa}`);
  if (!probeGrain) probeBad.push('_probe.html 找不到顆粒判斷 if (gv < …)');
  else if (+probeGrain[1] !== CONTRAST.grain) probeBad.push(`_probe.html 的顆粒判斷寫死 ${probeGrain[1]}，CONTRAST.grain 登記的是 ${CONTRAST.grain}`);
  ok(probeBad.length === 0,
    `MG4⑨ probe 原始碼裡的字面門檻對得上登記簿：if (v < ${probeAaa ? probeAaa[1] : '?'}) ＝ CONTRAST.aaa（${CONTRAST.aaa}）、if (gv < ${probeGrain ? probeGrain[1] : '?'}) ＝ CONTRAST.grain（${CONTRAST.grain}）—— 「單一 token 來源」現在在這兩條上也是真的`,
    probeBad.join(' · '));

  /* ── ⑩ lock 對 git 歷史錨定（第 12 輪 D11-01）─────────────────────────
     ⑦⑧ 的洞：thresholds.lock.json 是一本**沒有錨的新登記簿**。P4 不寫 moved，
     直接把 tokens.mjs／verify.mjs 的 value 與 thresholds.lock.json 的 value
     一起洗到同一個新數字——`th.value === locked.value` 從此恆真，⑦「沒有
     moved 就是紅」那一支（line 1987 附近 `if (th.value === locked.value) {…
     continue }`）直接被繞過去。P5 連 wide 一起洗（lock 的 wide: false→true），
     ⑧「沒有 wide 的不准長出來」也跟著失效。兩發共同的破綻：lock.json 與
     THRESHOLDS 同時被同一個人改，互相對帳當然對得上——**登記簿的權威來源
     是它自己**，這件事本身就是漏洞。
     「首次登記時是多少」唯一不在洗白者手上的權威是 git 自己的歷史：
     lock[id].sha 記著那次登記的 commit，這裡回頭去問 git，不再只信 lock
     自己寫的 value／sha。
       ① git show <sha>:./verify.mjs 抽出那次 commit 裡這條門檻的 value，
          必須與 lock[id].value 一致（P4：lock 被改的那個數，在 git 歷史裡
          找不到——974fd99 那次寫的仍然是舊值）
       ② merge-base --is-ancestor <sha> HEAD 必須成立——sha 必須真的是這個
          分支的祖先（擋「物件存在但不在歷史上」的偽造 commit）
       ③ sha 的每個 parent 都不能已經有這個 id——sha 必須真的是**第一次**
          登記（擋「補一個新 commit 造假 value，再把 lock 的 sha 指過去」；
          974fd99 的 parent a8efcc1 整份 verify.mjs 連 THRESHOLDS 這個陣列
          都還不存在，20 條全部在這裡通過）
     它擋不住「有 commit 權限的人什麼都能改」（連 git 歷史一起重寫）——跟 MG4⑦
     同一個立場，這裡不假裝擋得住。
     derived 四條（value=null）只驗 id 有沒有登記在 lock 上——那件事⑦已經驗過
     （`if (!locked)`），這裡不重複；它們的形狀已經由 MG4③ 釘死，沒有 value
     可以被洗。
     wide 沒有①②③這條路可走：974fd99（round 6，20 條全部首次登記的那次
     commit）那時候 `wide` 這個欄位**根本還不存在**（round 8 f9a721d 才加，
     見 D7-01③ 的說明）——「首次登記版有沒有 wide」這個問題本身沒有答案，
     機械抽不出來，如實回報。
     替代錨定：改錨在 thresholds.lock.json **自己第一次出現**的那次 commit
     （`git log -- thresholds.lock.json` 最早一筆，不信任 lock 檔案裡任何
     欄位——只信 git 對這個路徑的提交歷史，P5 改得動檔案內容，改不動已經
     提交過的歷史）。lock.json 自己的說明也是這樣寫的：wide 記的是「這次
     凍結…當下那條門檻有沒有掛著 wide」，凍結的當下就是那次 commit。回那
     次 commit 的 verify.mjs 讀「這個 id 的宣告裡有沒有 wide: 欄位」，必須
     與 lock[id].wide 一致——P5 把 lock.wide 改成 true，但改不動已經提交過
     的那次 commit，這裡當場對不上。
     （這條錨定上路後，順手挖到一個既有的資料錯誤：HUE_MIN.span 在凍結那次
     commit〔4dbe881〕從來沒有掛過 wide——它的比值 1.17 是三條 HUE_MIN 裡
     最貼線的一條，⑤的 wide 敘述原文也只提「span 1.17 < cool 1.55 < warm
     1.57」，從沒把 span 算進「留寬」那一類；thresholds.lock.json 卻把它的
     wide 登記成 true，八成是複製隔壁 cool／warm 兩條時漏改的殘留。這是這
     條新檢查第一次讓它有辦法被機器抓到，不是這一輪造成的——順手在下面把
     它改回 false，讓凍結快照回頭對得上歷史真的長什麼樣子；改的是 lock 的
     `wide` 記錄，不是 verify.mjs 裡 HUE_MIN.span 這條門檻本身，所以不算
     「門檻被移動」，不需要 moved 動議。）
     非 git work tree（selftest／atk 重放的 /tmp 複本，見檔頭 HERE 的說明：
     它們的複製方式本來就不含 .git）：印具名 SKIP，不計入 fail——baseline
     與現有 38 發 selftest 樣本都跑在這種複本裡，硬計 fail 會讓它們全部變
     紅，而它們沒有一發是在測這一條。真的要測 MG4⑩，複本必須是真的 git
     work tree（selftest.mjs 的 stageGitWT／atk 重放的 git worktree add）。
     repo 內跑（`node run.mjs`／`node verify.mjs` 沒有 LS_ROOT，或 LS_ROOT
     指到一個真的 work tree）：沒有 git 就硬失敗——那是逃避這條檢查的路，
     不是它的例外。 */
  {
    const gitCwd = HERE.pathname;
    const gitOK = (() => {
      try { execFileSync('git', ['rev-parse', '--is-inside-work-tree'], { cwd: gitCwd, stdio: ['ignore', 'pipe', 'pipe'] }); return true; }
      catch { return false; }
    })();
    if (!gitOK) {
      if (process.env.LS_SELFTEST) {
        console.log('SKIP  MG4⑩ lock 對 git 歷史錨定 —— 這份產物不在 git work tree 裡（見上：selftest／atk 重放的 /tmp 複本本來就沒有 .git），不計入 fail；真的要驗這一條需要真的 git work tree');
      } else {
        ok(false, 'MG4⑩ lock 對 git 歷史錨定', `${gitCwd} 不是 git work tree —— repo 內跑理應永遠是（LS_SELFTEST 之外沒有例外），這裡硬失敗，不當作可以跳過的情況`);
      }
    } else {
      /* 逐行抽出某個 commit 的 verify.mjs 裡，THRESHOLDS 陣列各條門檻的 value
         與有沒有 wide 欄位——走文字，不 import：那個年代的 verify.mjs 未必在
         現在的環境裡跑得起來（它 import 的 tokens.mjs／bands.mjs 可能是那個
         年代的形狀），而且要驗的正是「原始碼寫的是什麼」，不是「跑出來的值
         是什麼」。從第 6 輪起，每一條門檻的宣告固定開頭在自己一行
         `  { id: '...', file: '...', value: <字面值>, kind: ...`——id 與 value
         同一行；wide 不一定同一行，所以在整條宣告的範圍內找。 */
      const parseHistThresholds = (src) => {
        const m2 = /const THRESHOLDS = \[([\s\S]*?)\n\];/.exec(src || '');
        if (!m2) return null;
        const chunks = m2[1].split(/\n(?=  \{ id: )/).filter((c) => /id:\s*'/.test(c));
        const out2 = new Map();
        for (const c of chunks) {
          const idm = /id:\s*'([^']+)'/.exec(c);
          if (!idm) continue;
          const vm = /value:\s*(null|-?\d+(?:\.\d+)?)/.exec(c.split('\n')[0]);
          out2.set(idm[1], { value: vm ? (vm[1] === 'null' ? null : +vm[1]) : undefined, hasWide: /\bwide:/.test(c) });
        }
        return out2;
      };
      const showCache = new Map();
      const gitShow = (sha, path) => {
        const key = `${sha}:${path}`;
        if (showCache.has(key)) return showCache.get(key);
        let v;
        try { v = execFileSync('git', ['show', `${sha}:${path}`], { cwd: gitCwd, encoding: 'utf8', maxBuffer: 1 << 26 }); }
        catch { v = null; }
        showCache.set(key, v);
        return v;
      };
      const ancCache = new Map();
      const isAncestor = (sha) => {
        if (ancCache.has(sha)) return ancCache.get(sha);
        let v;
        try { execFileSync('git', ['merge-base', '--is-ancestor', sha, 'HEAD'], { cwd: gitCwd, stdio: 'ignore' }); v = true; }
        catch { v = false; }
        ancCache.set(sha, v);
        return v;
      };
      const parCache = new Map();
      const parents = (sha) => {
        if (parCache.has(sha)) return parCache.get(sha);
        let v;
        try { v = execFileSync('git', ['log', '--format=%P', '-n', '1', sha], { cwd: gitCwd, encoding: 'utf8' }).trim().split(/\s+/).filter(Boolean); }
        catch { v = null; }
        parCache.set(sha, v);
        return v;
      };
      /* wide 的替代錨：thresholds.lock.json 自己第一次出現的 commit（見上面
         的說明）—— git log 本身就是外部權威，不讀 lock 檔案裡任何欄位。 */
      let wideAnchorSha = null, wideAnchorErr = '';
      try {
        const log = execFileSync('git', ['log', '--format=%H', '--', 'thresholds.lock.json'], { cwd: gitCwd, encoding: 'utf8' }).trim().split('\n').filter(Boolean);
        wideAnchorSha = log.length ? log[log.length - 1] : null;
        if (!wideAnchorSha) wideAnchorErr = 'git log 對 thresholds.lock.json 找不到任何一次提交';
      } catch (e) { wideAnchorErr = String(e.message || e).split('\n')[0]; }
      const wideAnchorMap = wideAnchorSha ? parseHistThresholds(gitShow(wideAnchorSha, './verify.mjs')) : null;

      const lockBad10 = [];
      let checked10 = 0;
      for (const th of THRESHOLDS) {
        if (th.kind === 'derived') continue;   // ④：只驗 id 存在，⑦已經驗過（`if (!locked)` 那一支）
        const locked = LOCK[th.id];
        if (!locked) continue;                 // 「沒有登記在 lock 上」⑦已經標出來了，這裡不重複
        checked10++;
        const sha = locked.sha;
        if (!/^[0-9a-f]{40}$/.test(String(sha || ''))) { lockBad10.push(`${th.id} 的 lock.sha「${sha}」不是合法的 40 字元 commit sha`); continue; }
        if (!isAncestor(sha)) { lockBad10.push(`${th.id} 的 lock.sha ${sha.slice(0, 12)} 不是 HEAD 的祖先 —— 不是這個分支真的提交過的東西`); continue; }
        const histSrc = gitShow(sha, './verify.mjs');
        if (histSrc === null) { lockBad10.push(`${th.id}：git show ${sha.slice(0, 12)}:./verify.mjs 讀不到（那個 commit 底下沒有這個檔案，或路徑對不上）`); continue; }
        const hist = parseHistThresholds(histSrc)?.get(th.id);
        if (!hist || hist.value === undefined) { lockBad10.push(`${th.id} 在 ${sha.slice(0, 12)} 的 verify.mjs 裡抽不到這條門檻的 value —— lock.sha 指錯地方了`); continue; }
        if (hist.value !== locked.value) lockBad10.push(`${th.id}：lock 記的 value 是 ${locked.value}，但 ${sha.slice(0, 12)}（lock 自己指的那次登記）裡寫的是 ${hist.value} —— lock 被改過，不是那次 commit 寫的東西`);
        const ps = parents(sha);
        if (ps === null) { lockBad10.push(`${th.id}：讀不到 ${sha.slice(0, 12)} 的 parent`); continue; }
        for (const p of ps) {
          const pMap = parseHistThresholds(gitShow(p, './verify.mjs'));
          if (pMap && pMap.has(th.id)) { lockBad10.push(`${th.id}：${sha.slice(0, 12)} 的 parent ${p.slice(0, 12)} 裡已經有這條門檻了 —— lock.sha 指的不是「第一次登記」，是後來隨便一次提交`); break; }
        }
        if (wideAnchorMap) {
          const wa = wideAnchorMap.get(th.id);
          const anchoredWide = !!(wa && wa.hasWide);
          if (anchoredWide !== !!locked.wide) lockBad10.push(`${th.id}：lock 記的 wide＝${!!locked.wide}，但凍結那次 commit（${wideAnchorSha.slice(0, 12)}，thresholds.lock.json 第一次出現的那次）verify.mjs 裡「有沒有 wide 欄位」＝${anchoredWide} —— 對不上`);
        } else {
          lockBad10.push(`${th.id}：wide 的凍結錨（thresholds.lock.json 第一次出現的 commit）讀不到 —— ${wideAnchorErr || '原因不明'}`);
        }
      }
      ok(lockBad10.length === 0 && checked10 > 0,
        `MG4⑩ lock 對 git 歷史錨定：${checked10} 條門檻的 value 逐條回 lock.sha 那次 commit 核對（sha 是 HEAD 的祖先、parent 裡還沒有這條，兩層都成立才算真的是第一次登記）；wide 另外錨定在 thresholds.lock.json 自己第一次出現的 commit（${wideAnchorSha ? wideAnchorSha.slice(0, 12) : '?'}——974fd99 那次 wide 這個欄位還不存在，機械抽不出「首次登記版有沒有 wide」，改用「凍結那次 commit」，見上面的說明）`,
        lockBad10.join(' · '));
    }
  }
}

/* ══ G33  字樣的出處（第 6 輪換蠟筆；第 8 輪 D7-02 把閉環打開）════════
   第 1–5 輪的字標是這一份程式自己畫的（brush.mjs 的貝茲筆跡），所以「板上畫的
   是不是我們宣稱的那一份幾何」可以直接比 —— 兩邊都在同一個檔案裡。
   換成**外部素材描摹**之後多了一段以前沒有的距離：ink.mjs 裡那串 37KB 的 path
   要怎麼證明它真的出自那張蠟筆，而不是誰手改過一筆、或換了一張圖？

   第 7 輪 reviewer 把第 6 輪的三條打穿了：**它是一個閉環**。①比的是「宣告的雜湊」
   對「磁碟上那張圖的雜湊」，兩個數都在同一隻手上 —— 換一張家庭照進來、順手把 ink.mjs
   宣告的 sha256 也改成新的，①②③ 全綠，而那 37KB 的 path 與畫面上的字，
   跟那張新圖一點關係也沒有。**出處是宣告，不是重現。**

   五條（④⑤是第 8 輪補的牙）：
     ① ink.mjs 記著來源檔的 SHA-256，這裡回頭雜湊磁碟上那張 PNG 比對
        （換了圖不改宣告 → 紅；改了宣告不換圖 → 紅）
     ② 描摹的每一個參數都記著（二值化門檻、碎屑、補洞、DP 容差）——
        「顆粒留多少」是設計決定，不是描摹器的預設值
     ③ 板上畫的字標與 ink.mjs 的 path 逐字元相同（與 G26「板上畫的就是被量的那一份」同一招）
     ④ **拿 ② 宣告的那組參數，對 ① 那張圖當場重跑一次 trace.py**（--check 不寫檔），
        輸出的 d 必須逐字元等於 LOCKUP.d。換圖＋同步改宣告雜湊在這裡當場紅：
        新圖描出來的不是這 40 條輪廓。出處從「一句宣告」升級成「一次重現」。
     ⑤ 「字間的白比字內最大的白還窄，所以讀成一個詞」——第 6 輪這是一句**目測**。
        現在從 LOCKUP.d 自己算：even-odd 光柵化，量兩字之間那條全空直欄的寬度，
        與左右兩字各自最大的反白（counter）比。宣稱因此綁在幾何上，換字就會重算。

   ink.mjs 是**產物**（trace.py 產生的），不是 gate 程式 —— 所以這裡從產物根目錄讀它，
   不用 import 進來的那一份。負面對照才有辦法把「被動過手腳的宣告」餵進來。 */
const Ink2 = await import(at('ink.mjs').href);
{
  const png = at(Ink2.SRC.file);
  const sha = existsSync(png) ? createHash('sha256').update(readFileSync(png)).digest('hex') : null;
  ok(sha === Ink2.SRC.sha256,
    `G33① 字樣出自那張蠟筆：ink.mjs 記著來源 ${Ink2.SRC.file}（${Ink2.SRC.w}×${Ink2.SRC.h}）的 SHA-256 #${Ink2.SRC.sha256.slice(0, 12)}，磁碟上那張圖重算是 #${(sha || '（檔案不見了）').slice(0, 12)}`,
    sha === Ink2.SRC.sha256 ? '' : '兩者不同 —— 換了圖就要重跑 python3 trace.py，手改 path 再宣稱它出自那張圖會停在這裡');
  const T3 = Ink2.TRACE;
  ok([T3.alphaT, T3.speck, T3.hole, T3.eps, T3.unit].every((v) => typeof v === 'number') && T3.eps > 0 && T3.eps <= 2,
    `G33② 描摹的參數是設計決定的，逐個記著：二值化門檻 ${T3.alphaT}、碎屑下限 ${T3.speck}px²、補洞上限 ${T3.hole}px²、DP 容差 ${T3.eps} 原圖像素（顆粒的存廢就在這個數上：抬到 2.2 以上邊緣就開始像麥克筆）、字身單位 ${T3.unit}`,
    `eps=${T3.eps}`);
  const inked = files.filter((f) => read(f).includes('data-lockup="1"'));
  const off = inked.filter((f) => !read(f).includes(Ink2.LOCKUP.d));
  ok(inked.length > 0 && off.length === 0,
    `G33③ 板上畫的就是 ink.mjs 那一份：${inked.length} 張帶字標的板，path 資料（${Ink2.LOCKUP.n} 條輪廓、${(Ink2.LOCKUP.d.length / 1024).toFixed(1)}KB）逐字元相同，viewBox ${Ink2.LOCKUP.vb.w}:${Ink2.LOCKUP.vb.h}，fill-rule ${Ink2.FILL_RULE}（外框與洞在同一個 d 裡，靠 even-odd 分）`,
    off.join(' '));

  /* ④ 重現。環境變數餵的是 ink.mjs **自己宣告的**那一組參數 —— 所以「參數宣告」
     與「來源圖」一起被驗：任何一邊被動過，重跑出來的 d 就對不上。 */
  {
    let out = null, err = '';
    try {
      out = JSON.parse(execFileSync('python3', [at('trace.py').pathname, '--check'], {
        encoding: 'utf8',
        maxBuffer: 1 << 26,
        env: {
          ...process.env,
          LS_TRACE_SRC: at(Ink2.SRC.file).pathname,
          LS_TRACE_ALPHA_T: String(T3.alphaT), LS_TRACE_SPECK: String(T3.speck), LS_TRACE_HOLE: String(T3.hole),
          LS_TRACE_EPS: String(T3.eps), LS_TRACE_UNIT: String(T3.unit), LS_TRACE_DEC: String(T3.dec),
        },
      }));
    } catch (e) { err = String(e.stderr || e.message).split('\n').slice(-3).join(' '); }
    const same = !!out && out.d === Ink2.LOCKUP.d && out.n === Ink2.LOCKUP.n
      && out.vb.w === Ink2.LOCKUP.vb.w && out.vb.h === Ink2.LOCKUP.vb.h;
    ok(same,
      `G33④ 出處是**重現**不是宣告：拿 ② 那組參數對 ① 那張圖重跑一次 trace.py --check（不寫檔），輸出 ${out ? out.n : '?'} 條輪廓、viewBox ${out ? `${out.vb.w}:${out.vb.h}` : '?'}、d 共 ${out ? out.d.length : '?'} 字元，與 ink.mjs 的 LOCKUP.d **逐字元相同** —— 換一張圖再把宣告的雜湊同步改掉（①②③ 全綠的那一手）會停在這裡`,
      err ? `重跑不起來：${err}（需要 python3 ＋ numpy／opencv-python／Pillow）`
        : (out ? `重跑得到 ${out.n} 條輪廓、d ${out.d.length} 字元，與宣告的 ${Ink2.LOCKUP.n} 條／${Ink2.LOCKUP.d.length} 字元不同` : ''));
  }

  /* ⑤ 字距。even-odd 光柵化之後：
       字間白 ＝ 兩字之間那一段**整條直欄都沒有墨**的最寬處
       字內白 ＝ 不與外界連通的白（counter），左右兩字各取最寬的一個
     單位是字身單位（LOCKUP 的座標系，總寬 ${vb.w}），所以它不隨畫面上畫多大而變。 */
  {
    const s5 = Icon.counterStats({ d: Ink2.LOCKUP.d, vb: Ink2.LOCKUP.vb });
    ok(s5.n >= 2 && s5.gap > 0 && s5.gap < Math.min(s5.left, s5.right),
      `G33⑤ 字距不是排出來的、是量出來的：字間白 ${s5.gap.toFixed(1)} 個字身單位，比左字最大的反白 ${s5.left.toFixed(1)}、右字 ${s5.right.toFixed(1)} 都窄（窄 ${((1 - s5.gap / Math.min(s5.left, s5.right)) * 100).toFixed(1)}%）—— 所以「萌芽」讀成一個詞不是兩個字。${s5.n} 個反白全部由 LOCKUP.d 的 even-odd 光柵化算出來（板上印的就是這三個數），換字樣就會重算`,
      `字間白 ${s5.gap.toFixed(1)} vs 反白 ${s5.left.toFixed(1)}／${s5.right.toFixed(1)}（counter ${s5.n} 個）—— 字間白不再是最窄的白，那一句宣稱就不成立了`);
  }
}

/* ══ G34  板級排除登記簿（第 6 輪 D5-04）══════════════════════════
   第 5 輪：G10 的排除清單只寫在註解裡，斷言印的是「35 張板全部通過」—— 看的人
   不知道那 35 裡少了哪幾張；而且同樣的排除在 verify 與 measure 裡各寫了一份**內嵌正則**，
   四份都不一樣，其中兩處連註解都沒有。四份各自漂移的排除清單＝四個沒有人看得見的豁免。
   現在它們在 tokens.mjs 的 SCOPE 登記簿上。這一條反過來守登記簿本身：
     ① 登記的板真的存在（打錯字的排除會靜靜地變成「沒有排除」）
     ② 每一筆寫得出理由
     ③ **verify 與 measure 裡不准再出現內嵌的板名排除正則** —— 不然登記簿只是多一份文件 */
{
  const names = files.map((f) => f.replace('.dc.html', ''));
  const ghost = [], thin = [];
  for (const [g, sc] of Object.entries(SCOPE)) {
    for (const b of sc.skip) if (!names.includes(b)) ghost.push(`${g} 排除了不存在的板 ${b}`);
    if (!sc.why || sc.why.length < 40) thin.push(g);
  }
  ok(ghost.length === 0 && thin.length === 0,
    `G34① 板級排除是具名的：${Object.keys(SCOPE).length} 條 gate 各自登記排除哪幾張板與為什麼（${Object.entries(SCOPE).map(([g, sc]) => `${g}✕${sc.skip.length}`).join('、')}），排除的板名逐一存在，理由逐一寫得出來`,
    [...ghost, ...thin.map((g) => `${g} 的理由太短`)].join(' · '));
  const inline = [];
  for (const f of ['verify.mjs', 'measure.mjs']) {
    const s2 = readFileSync(at(f), 'utf8');
    for (const m of s2.matchAll(/\/[A-Za-z|]*(?:Tokens|Notes|Stress|AppIcon|GlassSeam)[A-Za-z|]*\/\s*\.test\s*\(/g)) {
      const line = s2.slice(0, m.index).split('\n').length;
      if (f === 'verify.mjs' && /const inline = \[\]/.test(s2.slice(Math.max(0, m.index - 400), m.index))) continue;  // 這一條自己
      inline.push(`${f}:${line}`);
    }
  }
  ok(inline.length === 0,
    'G34② 沒有人繞過登記簿：verify.mjs 與 measure.mjs 裡不再出現內嵌的板名排除正則（第 5 輪有四處，其中兩處沒有註解 —— 每一處都是一個看不見的豁免）',
    inline.join(' '));
}

/* ── 負面對照：對內嵌的壞樣本跑同一份 gate 程式，沒轉紅就是白驗 ── */
if (process.env.LS_SELFTEST) {
  /* 這一次 verify 是**對照實驗自己**跑的（selftest.mjs 在複本上跑同一份 gate 程式）。
     這裡不遞迴要求「對照跑過了」—— 否則第一次永遠起不來，而且每一發樣本都會
     因為同一個理由變紅、對照就失去分辨力。MG3 自己的完整性由下面那條
     codeFp（gate 程式版本）守：改了任何一支 gate 程式，上一次的對照就作廢。 */
  console.log('INFO  MG3 負面對照：本次由 selftest 自己執行，不遞迴要求（見 selftest.mjs 的說明）');
  RAN.set('MG3', 1);
} else {
  const SF = at('selftest.json');
  const st = existsSync(SF) ? JSON.parse(readFileSync(SF, 'utf8')) : null;
  /* 對照實驗綁在**gate 程式**上（不是綁在產物上）：改了任何一支 gate 程式，
     上一次的對照就作廢，必須重跑。產物改了不用重跑 —— 因為對照驗的是「gate 有沒有牙」。 */
  const codeFp = hash12(['build.mjs', 'verify.mjs', 'measure.mjs', 'tokens.mjs', 'icon.mjs', 'brush.mjs', 'ink.mjs', '_probe.html', 'selftest.mjs', 'bands.mjs']
    .map((f) => `${f}:${hash12(readFileSync(at(f), 'utf8'))}`).join('|'));
  ok(!!st, 'MG3① 負面對照跑過了（node selftest.mjs）', st ? '' : '沒有 selftest.json —— 管線的第 ⑤ 步沒跑');
  if (st) {
    ok(st.codeFp === codeFp,
      `MG3② 對照與現行的 gate 程式同版（#${codeFp}）—— 改了任何一支 gate 程式，上一次的對照就作廢`,
      st.codeFp !== codeFp ? `對照跑的是 #${st.codeFp}，現在是 #${codeFp}：重跑 node selftest.mjs` : '');
    const live = st.samples.filter((x) => !x.suspended), sus = st.samples.filter((x) => x.suspended);
    const green = live.filter((x) => !x.red);
    ok(green.length === 0 && live.length >= 8,
      `MG3③ ${live.length} 發壞樣本**全部轉紅**（每一發都指名它應該咬到的那一條）：${live.map((x) => `${x.id}→${x.gate}`).join('、')}`,
      green.map((x) => `${x.id} 沒有任何 gate 叫 —— 這就是漏洞本人`).join(' · '));
    const wrong = live.filter((x) => x.red && !x.hitExpected);
    /* 第 7 輪 reviewer：這一條的散文（「只咬指名的那一條」）與實作（inclusion）對不上。
       第 8 輪選「改字」而不是「改實作」，理由是實作本來就是對的：一發壞樣本
       同時驚動別的 gate 很常見而且**不是壞事**（改壞 measured.json 一定會連帶咬 G21
       產物同版、改壞板一定會連帶咬 G17 截圖同版）。要求「只有一條會叫」等於要求
       每一發都繞過所有連帶關係，那會把樣本寫成不真實的形狀。
       這一條真正在守的是「**不是別人代它叫的**」：指名的那一條必須在叫的名單裡。
       所以散文改成 inclusion，並且把連帶叫的那幾條印出來 —— 看得見才叫誠實。 */
    const collateral = [...new Set(live.flatMap((x) => (x.hits || []).filter((h) => h !== x.gate)))];
    ok(wrong.length === 0,
      `MG3④ 指名的那一條**在叫的名單裡**（inclusion，不是「只有它在叫」）：一發壞樣本連帶驚動別的 gate 是常態也是對的 —— 改壞 measured.json 必然連帶咬 G21、改壞板必然連帶咬 G17。本次連帶叫到的是 ${collateral.join('／') || '（沒有）'}。這一條守的是「不是別人代它叫的」`,
      wrong.map((x) => `${x.id} 期望 ${x.gate}，實際叫的是 ${x.hits.slice(0, 2).join('/')}`).join(' · '));
    /* 暫停中的樣本：它指名的那一族必須**真的在豁免登記簿上**。
       沒有這一條，「暫停」就是一個誰都可以寫的字串 —— 想關掉哪一發就關掉哪一發。 */
    const susBad = sus.filter((x) => !EXEMPT.some((e) => e.gate === x.gate.replace(/[a-z]$/, '')) || String(x.suspended).length < 30);
    ok(susBad.length === 0,
      `MG3⑤ 暫停中的 ${sus.length} 發，每一發指名的 gate 族都在具名豁免登記簿上，而且寫得出恢復條件：${sus.map((x) => `${x.id}→${x.gate}`).join('、') || '（沒有暫停中的樣本）'}`,
      susBad.map((x) => `${x.id} 說自己暫停，但 ${x.gate} 不在豁免登記簿上（或理由太短）`).join(' · '));
  }
}

/* 母體宣告的三條斷言（定義在上面）—— 排最後，因為它要數的是「誰真的跑過」。 */
mg1();

/* verify 有四個統計（gapCount／padCount／sizesUsed／axDerived）要回寫給 build 印在板上。
   第 2 輪它們直接寫進 measured.json —— 那讓 G21 變成**不冪等**的：
   verify 改了 measured.json ⇒ 它的雜湊變了 ⇒ 同一份產物再跑一次 verify，
   G21 就會說「板上印的是上一版」。跑兩次得到兩個答案的 gate 不是 gate。
   改法：這四個數寫到自己的檔（verified.json），build 一併讀，measured.json
   從 measure 寫完那一刻起到下一次 measure 之前**一個位元組都不會動**。 */
writeFileSync(new URL('verified.json', import.meta.url),
  `${JSON.stringify({ gapCount: M.gapCount, padCount: M.padCount, sizesUsed: M.sizesUsed, axDerived: M.axDerived }, null, 2)}\n`);
console.log(`\n${fail ? `${fail} 項未過` : '全部通過'}`);
process.exit(fail ? 1 : 0);
