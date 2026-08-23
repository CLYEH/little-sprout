// 自驗：設計稿上「宣稱」的每一件事，都必須在這裡跑得出來。
// 靜態項自己掃 HTML 原始碼；量測項讀 measured.json（measure.mjs 在真瀏覽器裡量的）。
// 第 2 輪被抓到三盞燈接錯線（grep helper 定義、只掃 gap、全幅量死帶），
// 所以 G1–G12 全部進管線，reviewer 拒絕管線外自證。
// Run: node measure.mjs && node verify.mjs
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import {
  T, GAPS, SIZES, FIX, AX, RULE, H1_GROUPS, H1_EXCLUDED, hash12,
  GRAD_KEYS, GRAD_WHY, NO_GRAD_WHY, CONTRAST, gradCss, SP,
  TRACK, TEMP, TEMP_TOL, HUE_MIN, LIGHT_DH, TIME_DH, LIGHT_KEYS, STUB_KEYS, STUB_KNEE, STUB_USES,
  lch, dHue, dE, hueDE, HUE_DE_MIN, INSET_KEYS, AX4, ax4, ax,
  PERF, perfMask, PERF_WHY, PHOTO_STOP, PHOTO_DIM, PHOTO_STOP_TOL, SCALE_DE, EXEMPT, dERgb, cellSeen, measStamp,
} from './tokens.mjs';
import { CANCEL_COV, CANCEL_PATH, CANCEL_BOX, polyArea } from './brush.mjs';
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
  G26b: '母體＝落款印的八筆，逐筆對位（八筆就是全集，沒有可以交叉的第二個維度）',
  G26c: '母體＝驗收排上的每一格（三種外觀 × 四個尺寸，笛卡兒積宣告在 G26）',
  G25: '母體＝畫面上每一顆第三方品牌鍵與它的整個子樹',
  MG1: '它自己就是母體檢查，不能用自己宣告自己',
  MG2: '母體＝畫面上出現的每一個豁免標記 ∪ 登記簿上的每一筆（等式的兩邊都是全集）',
  MG3: '母體＝負面對照的樣本表，每一發都具名列出（見 selftest.mjs）',
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
    if (/Tokens|Notes|AppIcon|GlassSeam/.test(f)) continue;   // 交付板：朱在這裡是圖例／標註，不是畫面上的訊號
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
      if (/Tokens/.test(f)) { seen.push(`${f.replace('.dc.html', '')} 印了全部 ${[...new Set([...s.matchAll(/data-grad="stub(\d)"/g)].map((m) => +m[1]))].length} 階`); continue; }
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
        if (/Notes/.test(f)) continue;
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
   板上印的與這裡判的是同一支函式。 */
{
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
    if (/Tokens|Notes|AX/.test(f)) continue;
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
  const bad = Object.entries(M.cta).filter(([k, v]) => !/Tokens|Notes|Stress/.test(k) && v > 1);
  ok(bad.length === 0, `G8 陶土：${M.ctaBoards} 張流程板，最外層陶土區塊最多 ${M.ctaMax} 個／板`,
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
  const PAUSE = RULE.pause, FLOW = (f) => !/Tokens|Notes|Stress|AppIcon|GlassSeam/.test(f);
  ok(M.pauseBad.filter((v) => FLOW(v.file)).length === 0,
    `G10 呼吸帶①：內容之間 >${PAUSE}px 的空白共 ${M.pauses.length} 段，全部掛了 data-pause 說明理由（手機 iPad 同一條門檻）`,
    M.pauseBad.filter((v) => FLOW(v.file)).map((v) => `${v.file}/${v.col}=${v.len}px@${v.at} 未掛牌`).join(' '));
  ok(M.pauses.every((p) => p.why.length >= 8),
    `G10 呼吸帶①：掛牌的理由都是句子不是敷衍`, M.pauses.filter((p) => p.why.length < 8).map((p) => p.file).join(' '));
  {
    const tails = new Set(M.boards.filter((b) => FLOW(b.file) && b.trail > PAUSE).map((b) => b.file));
    const rows = M.mainBtn.filter((b) => tails.has(b.file));
    const bad = rows.filter((b) => b.pct > RULE.btnPct);
    ok(bad.length === 0,
      `G10 呼吸帶②：尾段空白 >${PAUSE}px 的 ${tails.size} 張流程板，主按鈕中心位置最低 ${rows.length ? Math.max(...rows.map((b) => b.pct)) : '-'}%（門檻 ${RULE.btnPct}）`,
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
    ok(bad.length === 0, `G10 板高：${phones.length} 張手機板，放得下的一律 844、放不下的才長高（${phones.filter((b) => b.h > 844).map((b) => `${b.file} ${b.h}`).join(' ')}）`,
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
      if (!/AppIcon/.test(f) && loose !== 0) mat.push(`${f} 有 ${loose} 個不在 lockup 裡的筆跡`);
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
  ok(off.length >= 2 && off.every((k) => k.cr >= 3),
    `G19b OFF 的把手看得見：${off.length} 張關閉態的板，把手對軌道實測 ${off.map((k) => `${k.file.replace('Invite', '')} ${k.cr}:1`).join('／')}（門檻 3:1；第 2 輪是 1.04:1）`,
    off.filter((k) => k.cr < 3).map((k) => `${k.file} ${k.cr}`).join(' '));
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
   寫在 icon.mjs（四分之一字身、刻刀最細的一劃、20°、長度比、身分比值）。 */
{
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
   一張以「這一排是驗收不是展示」自居的表，如果尺寸可以偷改，那它就是展示。 */
{
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
  ok(rows.length >= 8 && rows.every((r) => r.layers === 3 && r.holes === 3 && /intersect|source-in/.test(r.composite)),
    `G27① 真的是洞不是線：${rows.length} 個騎縫線使用點，每一個都是三層遮罩取交集（一排圓孔 ∩ 左缺口 ∩ 右缺口），洞裡透出來的是台紙本身`,
    rows.filter((r) => !(r.layers === 3 && r.holes === 3)).map((r) => `${r.file}/${r.kind} 層數 ${r.layers}／洞 ${r.holes}`).join(' '));
  /* 齒距綁字級：一般板 PERF.pitch、AX4 板 ax4()、AX5 板 ax()。紙變大，紙上的齒跟著變大。
     AX 板上出現一般齒距 ＝ 那張紙長大了、齒沒有跟著長大 ＝ 它又變回一張貼上去的圖樣。 */
  const pitches = [...new Set(rows.map((r) => r.pitch))].sort((a, b) => a - b);
  const legalP = [PERF.pitch, ax4(PERF.pitch), ax(PERF.pitch)];
  const axBad = rows.filter((r) => (/AX/.test(r.file) ? r.pitch === PERF.pitch : r.pitch !== PERF.pitch));
  ok(pitches.every((p2) => legalP.includes(p2)) && axBad.length === 0,
    `G27② 齒距綁字級：一般板 ${PERF.pitch}px、AX4 ${ax4(PERF.pitch)}px、AX5 ${ax(PERF.pitch)}px —— 實測只出現這些：${pitches.join('／')}`,
    axBad.map((r) => `${r.file}/${r.kind} pitch=${r.pitch}`).join(' '));
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

/* ══ G32  登入鍵的標籤有三階（第 5 輪 D4-05）══════════════════════
   第 4 輪：AX5 下兩顆品牌鍵都只剩「登入」二字 —— 等高達標但語意塌。 */
if (M.brandLab && M.brandLab.length) {
  const wrap = M.brandLab.filter((b) => b.lines !== 1), over = M.brandLab.filter((b) => b.over >= 0);
  ok(wrap.length === 0 && over.length === 0,
    `G32① 三階標籤都不折行也不溢出：${M.brandLab.length} 顆品牌鍵，全部一行，最擠的一顆還剩 ${-Math.max(...M.brandLab.map((b) => b.over))}px`,
    [...wrap.map((b) => `${b.file}/${b.brand} 折了 ${b.lines} 行`), ...over.map((b) => `${b.file}/${b.brand} 溢出 ${b.over}px`)].join(' '));
  const byTitle = (tt) => M.brandLab.filter((b) => b.title === tt);
  ok(byTitle('full').length > 0 && byTitle('brand').length === 2 && byTitle('short').length === 2,
    `G32② 三階都畫出來了：一般字級「透過 X 登入」${byTitle('full').length} 顆、AX4「X 登入」${byTitle('brand').length} 顆、AX5「登入」${byTitle('short').length} 顆`,
    `full ${byTitle('full').length} / brand ${byTitle('brand').length} / short ${byTitle('short').length}`);
  ok(byTitle('brand').every((b) => /^(Apple|Google) 登入$/.test(b.text)) && byTitle('full').every((b) => /^透過 (Apple|Google) 登入$/.test(b.text)),
    'G32③ AX4 的標籤是「品牌詞＋登入」：虛詞（透過）丟掉、品牌詞留著（第 4 輪從一般字級直接跳到「登入」，中間這一階不存在）',
    M.brandLab.filter((b) => b.title === 'brand').map((b) => b.text).join('／'));
  const fit = (M.axFit || []).find((x) => x.id === 'ax5-google');
  ok(!!fit && fit.short > 0,
    `G32④ AX5 換短標題是量出來的：同一階字級下「Google 登入」需要 ${fit ? fit.need : '?'}px，那顆鍵真正剩給標籤的是 ${fit ? fit.room : '?'}px —— 差 ${fit ? fit.short : '?'}px，板上把那條放不下的示範行照實畫出來`,
    fit ? '' : 'StressLoginAX 上找不到那條示範行');
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
  const rows26 = Object.keys(Icon.APPEARANCE).flatMap((look) => Icon.SIZES.flatMap(([px]) => Icon.SCALES.map((sc) => `${look}|${px}|${sc}`)));
  pop('G26', { look: Object.keys(Icon.APPEARANCE), size: Icon.SIZES.map(([px]) => px), scale: Icon.SCALES },
    rows26.filter((r) => {
      const [look, px, sc] = r.split('|');
      const m2 = Icon.measureAt(+px, +sc, { fg: Icon.APPEARANCE[look].fg || T.light.ink, bg: Icon.TINT_BASE });
      return !!m2;
    }), '三種外觀 × 四個實際尺寸 × 兩個倍率：24 格全部要量，缺一格就是「那個尺寸沒有被驗過」');
  pop('G27', { kind: ['joined', 'torn'], scale: ['base', 'ax'] },
    (M.perf || []).map((r) => `${r.kind.replace(/-[bt]$/, '')}|${r.pitch === PERF.pitch ? 'base' : 'ax'}`),
    '兩種切法（還沒撕／撕下來的）在一般字級與 AX 都要有樣本 —— 齒距綁 ax() 只有在 AX 板上才驗得到');
  pop('G29', { mode: ['light', 'dark'], uses: STUB_USES },
    (M.scale || []).filter((r) => r.uses !== 'blank').map((r) => `${r.dark ? 'dark' : 'light'}|${r.uses}`),
    '四個狀態在兩個模式下都要畫出來，否則「相鄰態讀得出來」在缺樣本的那一邊等於沒有驗');
  pop('G31', { mode: ['day', 'night'] }, (M.photoPix || []).map((r) => r.mode),
    '照片的光：白天與夜裡各要有一張，只有一張就沒有「比」這回事');
  pop('G32', { brand: ['apple', 'google'], title: ['full', 'brand', 'short'] },
    (M.brandLab || []).map((b) => `${b.brand}|${b.title}`),
    '兩個品牌 × 三階標籤：每一階都要真的被畫出來，不能只寫在說明裡');
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
  ok(markers.filter((m2) => m2 !== 'data-cancel').every((m2) => inCode.includes(m2)),
    `MG2⑤ 登記簿上的每一種 marker 都真的有人在用它豁免：${inCode.join('／')}（data-cancel 由 G4 在原始碼端剝除，不走 probe）`,
    `清單 ${markers.join('/')} vs 程式 ${inCode.join('/')}`);
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
  const codeFp = hash12(['build.mjs', 'verify.mjs', 'measure.mjs', 'tokens.mjs', 'icon.mjs', 'brush.mjs', '_probe.html', 'selftest.mjs']
    .map((f) => `${f}:${hash12(readFileSync(at(f), 'utf8'))}`).join('|'));
  ok(!!st, 'MG3① 負面對照跑過了（node selftest.mjs）', st ? '' : '沒有 selftest.json —— 管線的第 ⑤ 步沒跑');
  if (st) {
    ok(st.codeFp === codeFp,
      `MG3② 對照與現行的 gate 程式同版（#${codeFp}）—— 改了任何一支 gate 程式，上一次的對照就作廢`,
      st.codeFp !== codeFp ? `對照跑的是 #${st.codeFp}，現在是 #${codeFp}：重跑 node selftest.mjs` : '');
    const red = st.samples.filter((x) => x.red), green = st.samples.filter((x) => !x.red);
    ok(green.length === 0 && st.samples.length >= 8,
      `MG3③ ${st.samples.length} 發壞樣本**全部轉紅**（每一發都指名它應該咬到的那一條）：${st.samples.map((x) => `${x.id}→${x.gate}`).join('、')}`,
      green.map((x) => `${x.id} 沒有任何 gate 叫 —— 這就是漏洞本人`).join(' · '));
    const wrong = st.samples.filter((x) => x.red && !x.hitExpected);
    ok(wrong.length === 0,
      'MG3④ 咬到的是**指名的那一條**，不是別的 gate 順便叫（不然下一次別的地方改壞了，這一發會誤報成綠）',
      wrong.map((x) => `${x.id} 期望 ${x.gate}，實際叫的是 ${x.hits.slice(0, 2).join('/')}`).join(' · '));
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
