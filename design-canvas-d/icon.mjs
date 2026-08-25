/* ── App icon：落款印的幾何、光柵化與量測（第 3 輪新增）─────────────────
   第 2 輪的 AppIcon 板是概念稿，板上自己寫著「20pt 讀不讀得出來是目視項，
   第 3 輪要想辦法變成量得出來的」。reviewer 量了：20pt 最細筆畫 0.44 裝置像素、
   墨覆蓋率 7.63%（官方導引的形體約 39%）——「物理上讀不出來」。

   所以這一支做三件事，而且三件都不靠眼睛：
     ① 刻的筆寬（CARVE）：中線一個點都不動，只換筆寬映射。刻的比寫的粗。
     ② 光柵化：路徑全部是多邊形（brush.mjs 的 stroke() 輸出的是外框多邊形，
        不是圓頭 stroke），所以可以用掃描線精確填色，不需要瀏覽器。
     ③ 量測：每一個實際尺寸（60/40/29/20pt × @2x/@3x）算最細筆畫、墨覆蓋率、
        前景對比，三種外觀（Light／Dark／Tinted）各算一次。G26 讀的就是這裡。 */
import { buildSeal } from './brush.mjs';

/* ── 刻的筆寬 ──────────────────────────────────────────────
   把「寫」的筆寬區間 [wMin, wMax] 線性映射到「刻」的區間 [lo, hi]，
   提按幅度打折（swell）。刀有刃寬，所以：最細的變粗很多、最粗的變粗一點，
   動態範圍被壓縮 —— 那正是刻與寫的差別，不是「整體加粗」。 */
export const CARVE = { wMin: 1.0, wMax: 8.6, lo: 7.5, hi: 16.5, swell: 0.55 };
export const carveWidth = {
  w: (v) => CARVE.lo + (v - CARVE.wMin) / (CARVE.wMax - CARVE.wMin) * (CARVE.hi - CARVE.lo),
  swell: CARVE.swell,
};

export const ICON = 1024;          // 母稿邊長
export const SEAL_FRAC = 0.66;     // 墨跡外框寬佔母稿的比例（第 2 輪是 .52）

export const SEAL = buildSeal(carveWidth);
export const WRITTEN = buildSeal();          // 字標用的「寫」的版本，供對照
/* 母稿上 1 個字身單位等於幾個 px。sealMark() 把 vb.w 縮到 ICON*SEAL_FRAC 寬，
   所以這個比例就是縮放倍率 —— 板上印的、G26 算的是同一個數。 */
export const UNIT_PX = ICON * SEAL_FRAC / SEAL.vb.w;

const med = (a) => { const s = [...a].sort((x, y) => x - y); const n = s.length; return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; };
export const strokeStats = (seal) => ({
  median: med(seal.nominal) * (ICON * SEAL_FRAC / seal.vb.w),
  min: Math.min(...seal.nominal) * (ICON * SEAL_FRAC / seal.vb.w),
  n: seal.nominal.length,
});

/* ── 光柵化 ───────────────────────────────────────────────
   路徑是「M x y L x y … Z」的多邊形串。每一筆各自填（non-zero 對一個凸凹多邊形
   等同 even-odd，因為 stroke() 的外框不自交），再取聯集 —— 筆與筆重疊的地方
   不會被算兩次墨。SS 是超取樣倍率，回傳每個像素的墨覆蓋率 0..1。

   evenodd:true 走另一條路（第 8 輪 D7-02／G33⑤ 加的）：**所有輪廓放在同一條掃描線上
   一起判奇偶**。描摹出來的字樣（ink.mjs）外框與洞在同一個 d 裡、靠 fill-rule="evenodd"
   分（瀏覽器就是這樣畫的），逐筆聯集會把「日」「月」「牙」的反白填實 ——
   要量反白就必須用瀏覽器那一套判法，不能用刻印那一套。 */
const parsePolys = (d) => d.split('Z').filter((s) => s.trim()).map((s) => {
  const pts = [];
  for (const m of s.matchAll(/[ML](-?[\d.]+) (-?[\d.]+)/g)) pts.push([+m[1], +m[2]]);
  return pts;
});

export const raster = (px, { seal = SEAL, ss = 4, evenodd = false } = {}) => {
  const N = px * ss;
  const hit = new Uint8Array(N * N);
  // 母稿座標：墨跡置中，寬 = ICON*SEAL_FRAC
  const k = ICON * SEAL_FRAC / seal.vb.w;                       // 字身單位 → 母稿 px
  const drawnH = seal.vb.h * k;
  const ox = (ICON - ICON * SEAL_FRAC) / 2, oy = (ICON - drawnH) / 2;
  const toDev = (p) => [((p[0] - seal.vb.x) * k + ox) * N / ICON, ((p[1] - seal.vb.y) * k + oy) * N / ICON];
  const polys = parsePolys(seal.d).map((poly) => poly.map(toDev));
  const span = (xs, y) => {
    xs.sort((p, q) => p - q);
    for (let i = 0; i + 1 < xs.length; i += 2) {
      for (let x = Math.max(0, Math.ceil(xs[i] - 0.5)); x <= Math.min(N - 1, Math.floor(xs[i + 1] - 0.5)); x++) hit[y * N + x] = 1;
    }
  };
  const cross = (P, yc, xs) => {
    for (let i = 0, j = P.length - 1; i < P.length; j = i++) {
      const a = P[j], b = P[i];
      if ((a[1] > yc) === (b[1] > yc)) continue;
      xs.push(a[0] + (yc - a[1]) / (b[1] - a[1]) * (b[0] - a[0]));
    }
  };
  if (evenodd) {
    for (let y = 0; y < N; y++) { const xs = []; for (const P of polys) cross(P, y + 0.5, xs); span(xs, y); }
  } else {
    for (const P of polys) {
      let y0 = Infinity, y1 = -Infinity;
      for (const p of P) { y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
      for (let y = Math.max(0, Math.floor(y0)); y <= Math.min(N - 1, Math.ceil(y1)); y++) { const xs = []; cross(P, y + 0.5, xs); span(xs, y); }
    }
  }
  const cov = new Float32Array(px * px);
  for (let y = 0; y < px; y++) for (let x = 0; x < px; x++) {
    let s = 0;
    for (let dy = 0; dy < ss; dy++) for (let dx = 0; dx < ss; dx++) s += hit[(y * ss + dy) * N + x * ss + dx];
    cov[y * px + x] = s / (ss * ss);
  }
  return cov;
};

/* ── 字間白 vs 字內白（第 8 輪 D7-02／G33⑤）──────────────────────────
   「字間的白比字內最大的白還窄，所以『萌芽』讀成一個詞而不是兩個字」——
   第 6 輪這是一句目測的宣稱。這一支把它變成三個從 d 自己算出來的數：
     gap   兩字之間那一段**整條直欄都沒有墨**的最寬處
     left  ／ right  不與外界連通的白（counter）裡，左右兩字各自最寬的一個
   單位是字身單位（LOCKUP 的座標系），所以它不隨畫面上畫多大而變。
   光柵化走 even-odd（瀏覽器畫這個 d 的那一套）—— 逐筆聯集會把反白填實。
   build 印板上那句話、verify 的 G33⑤ 下判斷，兩邊叫的是這同一支。 */
export const counterStats = (seal, px = 512) => {
  const U = seal.vb.w / (px * SEAL_FRAC);                       // 一個光柵格 ＝ 幾個字身單位
  const cov = raster(px, { seal, ss: 2, evenodd: true });
  const ink = (x, y) => cov[y * px + x] > 0.5;
  const col = Array.from({ length: px }, (_, x) => { for (let y = 0; y < px; y++) if (ink(x, y)) return 1; return 0; });
  const x0 = col.indexOf(1), x1 = col.lastIndexOf(1);
  let gap = 0, gapEnd = 0, run = 0;
  for (let x = x0; x <= x1; x++) { if (!col[x]) { run++; if (run > gap) { gap = run; gapEnd = x; } } else run = 0; }
  const mid = gapEnd - gap / 2;
  const ext = new Uint8Array(px * px), st = [];
  const flood = (x, y) => { if (!ink(x, y) && !ext[y * px + x]) { ext[y * px + x] = 1; st.push(x * px + y); } };
  for (let x = 0; x < px; x++) { flood(x, 0); flood(x, px - 1); }
  for (let y = 0; y < px; y++) { flood(0, y); flood(px - 1, y); }
  while (st.length) {
    const v = st.pop(), x = (v / px) | 0, y = v % px;
    if (x > 0) flood(x - 1, y); if (x < px - 1) flood(x + 1, y);
    if (y > 0) flood(x, y - 1); if (y < px - 1) flood(x, y + 1);
  }
  const seen = new Uint8Array(px * px), comps = [];
  for (let y = 0; y < px; y++) for (let x = 0; x < px; x++) {
    if (ink(x, y) || ext[y * px + x] || seen[y * px + x]) continue;
    const q = [x * px + y]; seen[y * px + x] = 1;
    let lo = x, hi = x;
    while (q.length) {
      const v = q.pop(), a = (v / px) | 0, b = v % px;
      lo = Math.min(lo, a); hi = Math.max(hi, a);
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) {
        const c = a + dx, e = b + dy;
        if (c < 0 || e < 0 || c >= px || e >= px || ink(c, e) || ext[e * px + c] || seen[e * px + c]) continue;
        seen[e * px + c] = 1; q.push(c * px + e);
      }
    }
    comps.push({ w: hi - lo + 1, cx: (lo + hi) / 2 });
  }
  const widest = (side) => { const a = comps.filter(side); return a.length ? Math.max(...a.map((c) => c.w)) * U : 0; };
  return { gap: gap * U, left: widest((c) => c.cx < mid), right: widest((c) => c.cx >= mid), n: comps.length };
};

/* 反白（counter）最小值：墨與墨之間那條白。糊成一團的物理原因就是它掉到 1 像素以下。
   逐列逐行找「墨—白—墨」的白段，取最短的那一段（單位：裝置像素）。
   reviewer 裁的三條沒有這一條 —— 但最細筆畫合格而反白不合格，字一樣是一團墨，
   所以這一條自己加上去（加嚴不減嚴，理由印在板上）。 */
export const counterGap = (cov, px) => {
  const runs = [];
  const scan = (get) => {
    for (let a = 0; a < px; a++) {
      let run = 0, seenInk = false;
      for (let b = 0; b < px; b++) {
        const ink = get(a, b) > 0.5;
        if (ink) { if (seenInk && run > 0) runs.push(run); run = 0; seenInk = true; }
        else if (seenInk) run++;
      }
    }
  };
  scan((y, x) => cov[y * px + x]);
  scan((x, y) => cov[y * px + x]);
  if (!runs.length) return { p05: px, min: px, n: 0 };
  runs.sort((a, b) => a - b);
  /* 取的是第 5 百分位，不是最小值。理由是幾何的：兩筆交會的地方，白會收成一個楔形，
     所以「恰好 1 像素的白」在**任何**解析度都必然存在（那是交點前的最後一列）。
     最小值因此永遠是 1，量的是交點不是反白。第 5 百分位量的才是「成片的白」。 */
  return { p05: runs[Math.floor(runs.length * .05)], min: runs[0], n: runs.length };
};

const lin = (v) => (v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
const relLum = ([r, g, b]) => .2126 * lin(r / 255) + .7152 * lin(g / 255) + .0722 * lin(b / 255);
export const contrast = (a, b) => { const l1 = relLum(a), l2 = relLum(b); const [hi, lo] = l1 > l2 ? [l1, l2] : [l2, l1]; return (hi + .05) / (lo + .05); };
export const rgbOf = (h) => { h = h.replace('#', ''); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };

/* 官方的中灰玻璃底。取樣自 Apple design kit（iOS 27）匯出的 kit-AppIcons 第三排
   （Tinted 那一排）：整排的眾數像素就是 rgb(128,128,128)。
   第 2 輪拿純黑當 Tinted 的驗收底 —— 黑底會讓任何白色前景都好看，等於沒驗。 */
export const TINT_BASE = '#808080';
export const TINT_FG = '#FFFFFF';

export const SIZES = [[60, '主畫面'], [40, 'Spotlight'], [29, '設定'], [20, '通知']];
export const SCALES = [2, 3];
export const RULE = { minStrokeDev: 1.5, coverage: 0.12, contrast: 3, counterDev: 1.0 };

/* 一種外觀（appearance）在一個實際尺寸上的三＋一個數。
   fg/bg 是那個外觀的前景色與底色；ink 為 true 時前景是不透明的墨。 */
export const measureAt = (pt, scale, { fg, bg }) => {
  const dev = pt * scale;
  const cov = raster(dev, { ss: 4 });
  let sum = 0, core = 0;
  for (let i = 0; i < cov.length; i++) { sum += cov[i]; if (cov[i] >= .5) core++; }
  const st = strokeStats(SEAL);
  const F = rgbOf(fg), B = rgbOf(bg);
  const gap = counterGap(cov, dev);
  return {
    pt, scale, dev,
    minStrokeDev: st.min * dev / ICON,
    medStrokeDev: st.median * dev / ICON,
    coverage: sum / cov.length,
    coreCoverage: core / cov.length,
    counterDev: gap.p05, counterMin: gap.min,
    contrast: contrast(F, B),
  };
};

/* ── 「刻是為刀重排，但還是同一個字」——把那句話變成八個可以被否證的數（第 5 輪 D4-10）──
   第 4 輪 reviewer 的判定：板上寫著「同一個字、同一組八筆、同一個筆序」，
   而底下那張表量的是**可讀性**（最細筆畫、墨覆蓋、對比、反白），其中兩個還是規格算術 ——
   「同不同一個字」從來沒有被量過，那句話因此只是自我宣告。

   逐筆量三個數（單位：字身，整個字是 100×100）：
     move  中線的平均位移 —— 「重排」有沒有真的發生（全部為 0 就等於只是加粗）
     tilt  首尾連線的角度差 —— 這一筆還是不是同一個方向的那一筆
     len   長度比 —— 這一筆有沒有被拉長或截短成另一支筆
   再加一條**身分**斷言（這一條才是「同一個字」的真正判準）：
     每一筆離自己的對應筆，比離其他任何一筆都近 —— 重排沒有把任何一筆搬成另一筆。
   門檻是設計自己開的，寫在這裡、印在板上、由 G26b 判：位移 ≤ MOVE_MAX、
   角度 ≤ TILT_MAX、長度比落在 LEN_RANGE 之內，而且身分配對必須全中。 */
/* 門檻的出處（每一個都不是照著實測畫的線）：
     moveMax 25  ＝ 四分之一個字身。一筆搬得比這個遠，它就走進別的部件的地盤 —— 那是重寫不是重排。
     reMin   7.5 ＝ 刻刀最細的一劃（CARVE.lo）。**至少要有一筆**搬得比一劃還遠，
                   否則「重排」根本沒發生（只是加粗）—— 這一條是下界，防的是自己說謊。
     tiltMax 20° ＝ 一筆轉超過 20° 就換了方向，橫會變成撇。
     len 0.7–1.4 ＝ 長度可以為了分白伸縮，但不能被截成另一支筆。
     nearest 0.75＝ **身分**：每一筆離自己的對應筆，至少要比離最近的其他筆再近 25%。
                   這一條才是「同一個字」的判準，前面四條只是「沒有亂搬」。 */
export const CARVE_RULE = { moveMax: 25, reMin: CARVE.lo, tiltMax: 20, lenLo: 0.7, lenHi: 1.4, nearest: 0.75 };
const bezPt = (p, u) => {
  const v = 1 - u, a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u;
  return [a * p[0][0] + b * p[1][0] + c * p[2][0] + d * p[3][0],
    a * p[0][1] + b * p[1][1] + c * p[2][1] + d * p[3][1]];
};
const samples = (pts, n = 24) => Array.from({ length: n + 1 }, (_, i) => bezPt(pts, i / n));
const meanDist = (A, B) => A.reduce((s, p, i) => s + Math.hypot(p[0] - B[i][0], p[1] - B[i][1]), 0) / A.length;
const chord = (P) => Math.atan2(P[P.length - 1][1] - P[0][1], P[P.length - 1][0] - P[0][0]) * 180 / Math.PI;
const arclen = (P) => P.reduce((s, p, i) => (i ? s + Math.hypot(p[0] - P[i - 1][0], p[1] - P[i - 1][1]) : 0), 0);
export const centerlineDev = () => {
  const W = WRITTEN.strokes.map((s) => samples(s.pts)), C = SEAL.strokes.map((s) => samples(s.pts));
  return W.map((w, i) => {
    const c = C[i];
    // 身分：這一筆離自己的對應筆，比離別的筆近多少（比值 <1 才成立）
    const others = C.map((o, j) => (j === i ? Infinity : meanDist(w, o)));
    const own = meanDist(w, c);
    return {
      i: i + 1,
      move: +own.toFixed(2),
      tilt: +Math.abs(((chord(c) - chord(w) + 540) % 360) - 180).toFixed(2),
      len: +(arclen(c) / arclen(w)).toFixed(3),
      nearest: +(own / Math.min(...others)).toFixed(3),
    };
  });
};

export const APPEARANCE = {
  淺色: { fg: null, bg: null },   // build.mjs 填入 t.ink / 台紙漸層的最不利端
  深色: { fg: null, bg: null },
  Tinted: { fg: TINT_FG, bg: TINT_BASE },
};
