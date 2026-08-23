// 自驗：設計稿上「宣稱」的每一件事，都必須在這裡跑得出來。
// 靜態項自己掃 HTML 原始碼；量測項讀 measured.json（measure.mjs 在真瀏覽器裡量的）。
// 第 2 輪被抓到三盞燈接錯線（grep helper 定義、只掃 gap、全幅量死帶），
// 所以 G1–G12 全部進管線，reviewer 拒絕管線外自證。
// Run: node measure.mjs && node verify.mjs
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import {
  T, GAPS, SIZES, FIX, AX, RULE, H1_GROUPS, H1_EXCLUDED, hash12,
  GRAD_KEYS, GRAD_WHY, NO_GRAD_WHY, CONTRAST, gradCss, perfCss,
  TRACK, TEMP, TEMP_TOL, HUE_MIN, LIGHT_DH, TIME_DH, LIGHT_KEYS, STUB_KEYS, STUB_KNEE,
  lch, dHue, dE,
} from './tokens.mjs';

const files = readdirSync(new URL('.', import.meta.url)).filter((f) => f.endsWith('.dc.html')).sort();
const read = (f) => readFileSync(new URL(f, import.meta.url), 'utf8');
const src = readFileSync(new URL('build.mjs', import.meta.url), 'utf8');
let fail = 0;
const MJ = new URL('measured.json', import.meta.url);
/* G21 用：現行 measured.json 的原文與指紋。verify 跑到最後會把 G1/G2 的統計寫回這個檔，
   所以指紋一律取「verify 開跑時讀到的那一份」—— 與 build 讀到的是同一個狀態。 */
const MEAS_RAW = existsSync(MJ) ? readFileSync(MJ, 'utf8') : '';
const M = MEAS_RAW ? JSON.parse(MEAS_RAW) : {};
const ok = (pass, label, detail = '') => {
  if (!pass) fail++;
  console.log(`${pass ? 'PASS' : 'FAIL'}  ${label}${detail ? `  ${detail}` : ''}`);
};
const need = (key, label) => { console.log(`SKIP  ${label} —— measured.json 缺 ${key}，先跑 node measure.mjs`); fail++; };

/* ══ G1  間距級距：gap ＋ padding ＋ margin 全部掃 ══════════════════
   第 2 輪只掃 gap（370 個），放走了 133 個級距外的 padding/margin。 */
{
  const AXV = new Set();
  for (const n of [...SIZES, 12, 18, 21, 25, 40, 56, 80]) AXV.add(Math.round(n * AX));
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
  for (const n of [...SIZES, 12, 18, 21, 25, 40, 56, 80]) derived.add(Math.round(n * AX));
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
    if (/Tokens|Notes/.test(f)) continue;
    const body = read(f).replace(/--ls-pen:[^;]+;/g, '');
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
  ok(M.insetBad.length === 0, `G5 凹的白名單：${M.insetTotal} 個帶 inset 的使用點，全部落在 ${Object.keys(M.insetUse).length} 個角色`,
    M.insetBad.length ? M.insetBad.slice(0, 6).join(' | ') : Object.entries(M.insetUse).map(([k, v]) => `${k}×${v}`).join(' '));
  ok(!/inset/.test(src.slice(src.indexOf('const raise ='), src.indexOf('// 平印：'))),
    'G5 浮起只有兩層：raise() 的函式體裡沒有 inset（第三層 topLight 已移除）');
  ok(/border-bottom:\$\{FIX\.lip\}px/.test(src), 'G5 浮起保留 3pt 唇邊');
  ok(!/const flat =[\s\S]*?box-shadow/.test(src.slice(src.indexOf('const flat ='), src.indexOf('const press ='))), 'G5 平印：flat() 沒有 inset、沒有 box-shadow');
  ok(/const win[\s\S]{0,300}?inset 0 1\.5px 0/.test(src), 'G5 凹窗：win() 保留上緣內陰影（真凹沒有被動到）');
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
    {
      const edges = [T.light, T.dark].map((th) => {
        const m = /#([0-9A-Fa-f]{6})/.exec(th.edge);
        return `rgb(${[0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16)).join(', ')})`;
      });
      const badP = patterns.filter((c) => {
        const cols = [...new Set([...c.matchAll(/rgba?\([^)]*\)/g)].map((x) => x[0]))];
        const solid = cols.filter((x) => !/,\s*0\)$/.test(x));
        const beats = [...c.matchAll(/([\d.]+)px/g)].map((x) => x[1]).join(',');
        return !(solid.length === 1 && edges.includes(solid[0]) && beats === '0,6,6,12');
      });
      ok(patterns.length > 0 && badP.length === 0,
        `G22③ 騎縫線：${patterns.length} 種 repeating 寫法只有 edge 一個實色＋全透明，節拍 6/12px（它是圖樣不是明暗漸層，方向例外印在板上）`,
        badP.slice(0, 2).join(' | ') || (patterns.length ? '' : '一個都沒有 —— 票根的騎縫線不見了'));
    }
  } else need('grad', 'G22 漸層');

  // 理由與端點都要印在 Tokens 板上：沒印理由的漸層就是裝飾，不是設計
  {
    const missWhy = [], missHex = [];
    for (const k of [...GRAD_KEYS, 'perf']) {
      if (!sheet.includes(GRAD_WHY[k])) missWhy.push(k);
      if (k === 'perf') continue;
      for (const th of [T.light, T.dark]) {
        for (const [hex, pos] of th.grad[k]) if (!sheet.includes(`${hex} ${pos}%`)) missHex.push(`${k}:${hex}@${pos}%`);
      }
    }
    ok(missWhy.length === 0 && missHex.length === 0,
      `G22③ 漸層理由：${GRAD_KEYS.length + 1} 種漸層的理由與兩端 hex（淺／深各一組）全部印在 Tokens 板上`,
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
        const got = dHue(lch(th[k]).h, base);
        seen.push(`${name}${k} ${got > 0 ? '+' : ''}${got.toFixed(1)}°`);
        if (Math.abs(got - want) > TEMP_TOL) bad.push(`${name} ${k} 實測 ${got.toFixed(1)}°、宣告 ${want}°（容差 ±${TEMP_TOL}）`);
      }
    }
    ok(bad.length === 0,
      `G23① 溫度階梯：四階台紙與染料相對台紙本體的色相角，淺色與深色都等於宣告的 TEMP（${seen.join(' · ')}）`,
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
    ok(M.flatBad.length === 0,
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
    const bad = [], seen = [];
    for (const f of files) {
      const s = read(f);
      const lv = [...new Set([...s.matchAll(/data-grad="stub(\d)"/g)].map((m) => +m[1]))];
      const say = [...new Set([...s.matchAll(/還可以用 (\d) 次/g)].map((m) => +m[1]))];
      if (!lv.length && !say.length) continue;
      if (/Tokens/.test(f)) { seen.push(`${f.replace('.dc.html', '')} 印了全部 ${lv.length} 階`); continue; }
      if (lv.length !== 1 || say.length !== 1 || lv[0] !== say[0]) {
        bad.push(`${f} 畫的是 stub${lv.join('/')}、寫的是「還可以用 ${say.join('/')} 次」`);
      } else seen.push(`${f.replace('.dc.html', '')} ${lv[0]}`);
    }
    ok(bad.length === 0,
      `G23⑤ 褪色階＝剩餘次數：${seen.length} 張有號碼帶的板，畫出來的階數等於印在上面的次數（${seen.join(' · ')}）`,
      bad.join(' · '));
  }
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

  // ① 輸入格：真的有一個分隔元素（不是散文裡的頓號）。刪掉它就 FAIL。
  const SEP = /flex:none">、<\/span>/g;
  const seps = (s) => [...s.matchAll(SEP)].length;
  ok(seps(join) === 1 && seps(otp) === 0,
    `G7 分隔（輸入格）：JoinCode 的分格帶中間有 ${seps(join)} 個分隔 span、Otp ${seps(otp)} 個 —— 量的是元素，不是散文裡的「、」`,
    `join=${seps(join)} otp=${seps(otp)}`);

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
  // 交付板不是畫面（Tokens／Notes／壓力板／AppIcon），呼吸帶與板高的兩條規則不適用；
  // 排除清單明講在這裡，不是靠 verify 靜靜跳過（AppIcon 板上也印了它自己的豁免清單）。
  const PAUSE = RULE.pause, FLOW = (f) => !/Tokens|Notes|Stress|AppIcon/.test(f);
  ok(M.pauseBad.length === 0,
    `G10 呼吸帶①：內容之間 >${PAUSE}px 的空白共 ${M.pauses.length} 段，全部掛了 data-pause 說明理由（手機 iPad 同一條門檻）`,
    M.pauseBad.map((v) => `${v.file}/${v.col}=${v.len}px@${v.at} 未掛牌`).join(' '));
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
  } else need('darkMotifs', 'G12 深色母題');
  ok(/press: '0 -1px 0/.test(readFileSync(new URL('tokens.mjs', import.meta.url), 'utf8')),
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
    ['票根降成一行', 'InviteRequestsMany.dc.html'],
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
    ok(brand.length + sw.length === M.lipNone && brand.length === 8 && sw.length === 3,
      `G19 沒有唇邊的浮起面只有兩種、共 ${M.lipNone} 個：兩顆品牌鍵（Apple ${brand.filter((s) => /apple/.test(s)).length}＋Google ${brand.filter((s) => /google/.test(s)).length}，我們不改別人的外觀 —— 連加一道唇邊、連把它規範的 1px 描邊加粗成 3px 都算改）與審核開關 ON 的軌道 ${sw.length} 個（膠囊軌道，唇邊會壓到把手行程）`,
      M.lipNoneWho.join(' '));
  }
} else need('lips', 'G19 唇邊');

if (M.toggles) {
  const ys = [...new Set(M.toggles.map((t) => t.top))];
  ok(M.toggles.length >= 5 && ys.length === 1,
    `G19 開關列固定在票根正下方：${M.toggles.length} 張板（空／產生中／已產生／審核關閉／深色）全部在 y=${ys.join('／')}`,
    ys.length > 1 ? M.toggles.map((t) => `${t.file}@${t.top}`).join(' ') : '');
} else need('toggles', 'G19 開關列');

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
    ['板高 (\\d+)px', (n) => n === hOf('InviteRequestsMany.dc.html'), () => `canvas.json 的 InviteRequestsMany 板高 ${hOf('InviteRequestsMany.dc.html')}`],
    ['放不下 (\\d+) 才長高', (n) => n === hOf('InviteRequests.dc.html'), () => `canvas.json 的手機板高 ${hOf('InviteRequests.dc.html')}`],
    ['其餘待核板一律 (\\d+)', (n) => n === hOf('InviteRequests.dc.html'), () => `canvas.json 的手機板高 ${hOf('InviteRequests.dc.html')}`],
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
  const now = MEAS_RAW ? hash12(MEAS_RAW) : 'no-measurement';
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
  const rootFile = new URL('_root.json', import.meta.url);
  const local = existsSync(rootFile) ? JSON.parse(readFileSync(rootFile, 'utf8')) : null;
  ok(!!local && !!M.root && M.root.track === local.track && M.root.fp === local.fp,
    `G21b 量測來源：measured.json 是在本軌的根目錄上量的（${local ? `${local.track} #${local.fp}／${local.boards} 板` : '_root.json 不見了'}）`,
    !local ? '沒有 _root.json —— 先跑 node build.mjs'
      : !M.root ? 'measured.json 沒有記下根目錄 —— 重跑 node measure.mjs'
        : `量測時是 ${M.root.track} #${M.root.fp}（${M.root.boards} 板）`);
}

/* ══ G17  截圖與重渲染的底部 40px 一致（_shot.mjs 寫回）══════════ */
if (M.shot) {
  ok(M.shot.sizeBad.length === 0, `G17 截圖尺寸：${M.shot.n} 張 PNG 的像素尺寸全部等於板的 w×h`, M.shot.sizeBad.join(' '));
  ok(M.shot.tailBad.length === 0, `G17 截圖底部 40px 與重渲染一致（最大差 ${M.shot.maxDiff}）`, M.shot.tailBad.join(' '));
} else {
  console.log('SKIP  G17 截圖一致性 —— 先跑 node _shot.mjs');
}

writeFileSync(MJ, JSON.stringify(M, null, 2));
console.log(`\n${fail ? `${fail} 項未過` : '全部通過'}`);
process.exit(fail ? 1 : 0);
