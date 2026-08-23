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
   不會被算兩次墨。SS 是超取樣倍率，回傳每個像素的墨覆蓋率 0..1。 */
const parsePolys = (d) => d.split('Z').filter((s) => s.trim()).map((s) => {
  const pts = [];
  for (const m of s.matchAll(/[ML](-?[\d.]+) (-?[\d.]+)/g)) pts.push([+m[1], +m[2]]);
  return pts;
});

export const raster = (px, { seal = SEAL, ss = 4 } = {}) => {
  const N = px * ss;
  const hit = new Uint8Array(N * N);
  // 母稿座標：墨跡置中，寬 = ICON*SEAL_FRAC
  const k = ICON * SEAL_FRAC / seal.vb.w;                       // 字身單位 → 母稿 px
  const drawnH = seal.vb.h * k;
  const ox = (ICON - ICON * SEAL_FRAC) / 2, oy = (ICON - drawnH) / 2;
  const toDev = (p) => [((p[0] - seal.vb.x) * k + ox) * N / ICON, ((p[1] - seal.vb.y) * k + oy) * N / ICON];
  for (const poly of parsePolys(seal.d)) {
    const P = poly.map(toDev);
    let y0 = Infinity, y1 = -Infinity;
    for (const p of P) { y0 = Math.min(y0, p[1]); y1 = Math.max(y1, p[1]); }
    for (let y = Math.max(0, Math.floor(y0)); y <= Math.min(N - 1, Math.ceil(y1)); y++) {
      const yc = y + 0.5, xs = [];
      for (let i = 0, j = P.length - 1; i < P.length; j = i++) {
        const a = P[j], b = P[i];
        if ((a[1] > yc) === (b[1] > yc)) continue;
        xs.push(a[0] + (yc - a[1]) / (b[1] - a[1]) * (b[0] - a[0]));
      }
      xs.sort((p, q) => p - q);
      for (let i = 0; i + 1 < xs.length; i += 2) {
        for (let x = Math.max(0, Math.ceil(xs[i] - 0.5)); x <= Math.min(N - 1, Math.floor(xs[i + 1] - 0.5)); x++) hit[y * N + x] = 1;
      }
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

export const APPEARANCE = {
  淺色: { fg: null, bg: null },   // build.mjs 填入 t.ink / 台紙漸層的最不利端
  深色: { fg: null, bg: null },
  Tinted: { fg: TINT_FG, bg: TINT_BASE },
};
