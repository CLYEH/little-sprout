// 萌芽日記（Little Sprout）M1 — 單一 token 來源。build.mjs 與 verify.mjs 都從這裡讀，
// 所以「宣稱的值」與「畫出來的值」不可能再漂移。
import { createHash } from 'node:crypto';

/* 這一份產物的身分。measure.mjs 開跑前拿 http server 上的 _root.json 比對它 ——
   軌 B 的複本欄位與這裡完全相容，埠號指錯時 gate 會全綠地放行「別人的設計」。 */
export const TRACK = 'LS-38-track-D';

/* ── 色彩量測：CIELAB / LCh（D65、sRGB）───────────────────────
   G23 的色彩語意斷言、Tokens 板上印的 L* 、C* 、h、號碼帶的褪色階，
   三者用的都是這一份函式 —— 不可能「板上印一套、gate 算另一套」。
   用 L* 是刻意的：WCAG 的相對亮度 Y 與 L* 是一對一的，所以
   「固定 L* 只轉色相」＝對比一位元都不會變（深色四階的溫度就是這樣修的）。 */
const srgbToLin = (v) => (v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
const linToSrgb = (v) => (v <= .0031308 ? v * 12.92 : 1.055 * v ** (1 / 2.4) - .055);
const WP = [0.95047, 1, 1.08883];
export const hexRgb = (h) => { h = h.replace('#', ''); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
export const lab = (hexStr) => {
  const [r, g, b] = hexRgb(hexStr).map((v) => srgbToLin(v / 255));
  const xyz = [(.4124564 * r + .3575761 * g + .1804375 * b) / WP[0],
    (.2126729 * r + .7151522 * g + .0721750 * b) / WP[1],
    (.0193339 * r + .1191920 * g + .9503041 * b) / WP[2]];
  const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : (841 / 108) * t + 4 / 29);
  const [fx, fy, fz] = xyz.map(f);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
};
export const lch = (hexStr) => {
  const [L, a, b] = lab(hexStr);
  let h = Math.atan2(b, a) * 180 / Math.PI; if (h < 0) h += 360;
  return { L, C: Math.hypot(a, b), h };
};
/* 兩個色相角之間的最短弧（-180, 180]。四階溫度全部用相對角，因為深色的
   絕對色相在 0° 附近繞圈，用絕對值比會比出假的大小關係。 */
export const dHue = (a, b) => { let d = a - b; while (d > 180) d -= 360; while (d < -180) d += 360; return d; };
export const dE = (a, b) => { const x = lab(a), y = lab(b); return Math.hypot(x[0] - y[0], x[1] - y[1], x[2] - y[2]); };
const labHex = (L, a, b) => {
  const fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200;
  const fi = (t) => (t > 6 / 29 ? t ** 3 : (t - 4 / 29) * 3 * (6 / 29) ** 2);
  const [x, y, z] = [fi(fx) * WP[0], fi(fy) * WP[1], fi(fz) * WP[2]];
  const rgb = [3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
    -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
    0.0556434 * x - 0.2040259 * y + 1.0572252 * z].map(linToSrgb);
  return { rgb, hex: `#${rgb.map((v) => Math.max(0, Math.min(255, Math.round(v * 255))).toString(16).padStart(2, '0').toUpperCase()).join('')}` };
};
// LCh → hex，出色域就把彩度往回收（收了多少會被印出來，不會靜靜地變成別的顏色）
export const lchHex = (L, C, h) => {
  for (let c = C; c > 0; c -= .1) {
    const r = labHex(L, c * Math.cos(h * Math.PI / 180), c * Math.sin(h * Math.PI / 180));
    if (r.rgb.every((v) => v >= -.0015 && v <= 1.0015)) return r.hex;
  }
  return labHex(L, 0, 0).hex;
};

/* ── 色 ──────────────────────────────────────────────
   這一稿的粉不是把上一稿加粉紅濾鏡：粉是**家庭相簿老化的方向**。
   彩色沖印的青色染料衰退得最快，所以八〇、九〇年代的家庭照片與相簿台紙
   都是往洋紅／玫瑰偏過去的 —— 這個 app 的底色，就是家庭記憶會變成的顏色。

   四階台紙（lit / board / board2 / board3）刻意不是同一支粉調亮調暗：
     lit    最亮，偏暖白 —— 還沒被翻過的新紙
     board  台紙本體 —— 中性的塵玫瑰
     board2 開窗底，偏**冷**粉 —— 凹進去的地方是陰影，陰影偏冷
     board3 次要面，偏**暖**褐 —— 翻動最多的地方有手澤，先黃
   中性階因此有溫度層次，不是一個色相的四個明度。

   **深色不是把淺色反相**（第 1 輪的深色四階色相全落 6.5° 內，正是設計自己說它不是的
   那個東西）。深色是同一套語言在暗處重新推導：絕對色相由各自的錨點決定（淺色 h≈35
   的泛黃紙、深色 h≈16），但**四階之間的相對溫度是同一組常數 TEMP，兩個模式都要對得上**。
   修法是「固定 L*、只轉色相」—— L* 與 WCAG 的相對亮度一一對應，所以整批對比一位元都沒動。

   規則：文字只有兩級（ink / ink2）。玫瑰、朱、芽綠只當底色或線，
   永遠不當長文字色（朱的錯誤句是唯一例外，實測 AAA）。
   edge 是全稿唯一的線色（分隔線、開窗邊、未走的步驟段）。 */
export const T = {
  light: {
    board: '#F4DFDB', board2: '#E7CDCB', board3: '#E2C6BE', lit: '#FEF3F0',
    ink: '#2A1219', ink2: '#3E232B',
    cta: '#86183F', ctaDeep: '#4A0722', ctaBusy: '#5E0A2A', onCta: '#FEF3F0',
    pen: '#7E1414', sprout: '#1C4630', onSprout: '#FEF3F0',
    edge: '#8C6159',
    /* 第三方品牌鍵：外觀由對方的規範決定，不吃我們的色。列在這裡是因為
       「沒印出來的例外就是 bug」——它們是全稿唯二不走台紙色的表面。 */
    appleBg: '#000000', appleFg: '#FFFFFF',
    googleBg: '#FFFFFF', googleFg: '#1F1F1F', googleLine: '#747775',
    bevelTop: 'rgba(42,18,25,.34)', bevelSoft: 'rgba(42,18,25,.22)', bevelBot: 'rgba(255,246,242,.78)',
    lift: '0 1px 0 rgba(42,18,25,.20), 0 8px 16px -10px rgba(42,18,25,.55)',
    press: '0 1px 0 rgba(255,246,242,.80)',   // 平印：光從上來，字的下緣有亮邊
    grain: '.055',
    /* 漸層的色停，一律寫成 [[色, 位置%], …]，由上往下。它們自己就是 token
       （不是在 build 裡算出來的），因為 Tokens 板要逐個印出來、verify 要逐個比對。
       光從**上**來。號碼帶的褪色階（stub3–stub0）在檔案下方由 fadeLadder() 推出來。 */
    grad: {
      paper: [['#F8E6DD', 0], ['#EFD8D9', 100]],
      win: [['#E0C4C3', 0], ['#EED5D2', 100]],
      win3: [['#D8B9B1', 0], ['#E6C9C1', 100]],
      face: [['#E9CFC7', 0], ['#DBBDB5', 100]],
      cta: [['#901F49', 0], ['#7C1236', 100]],
      seam: [['rgba(42,18,25,0)', 0], ['rgba(42,18,25,.42)', 100]],
    },
    /* 號碼帶的兩個錨點：剛印好的染料帶（上緣已經見過光，所以上淺下濃），
       與褪到底之後剩下的東西 —— 票根自己那張泛黃的紙。 */
    stubFresh: ['#FAEADE', '#ECD0D6'],
    stubSpent: '#F7ECE4',
  },
  dark: {
    board: '#261416', board2: '#1F1013', board3: '#372020', lit: '#462A2B',
    ink: '#F8E7E2', ink2: '#DCBEBC',
    cta: '#E3A9C4', ctaDeep: '#995F7F', ctaBusy: '#C39BAE', onCta: '#261416',
    pen: '#FFAE86', sprout: '#8FD2A6', onSprout: '#261416',
    edge: '#A0807C',
    appleBg: '#FFFFFF', appleFg: '#000000',
    googleBg: '#131314', googleFg: '#E3E3E3', googleLine: '#8E918F',
    bevelTop: 'rgba(0,0,0,.6)', bevelSoft: 'rgba(0,0,0,.45)', bevelBot: 'rgba(255,214,208,.20)',
    lift: '0 1px 0 rgba(0,0,0,.5), 0 8px 16px -10px rgba(0,0,0,.9)',
    press: '0 -1px 0 rgba(0,0,0,.55)',        // 深色：光從下來，亮邊翻到上緣（同一條規則的鏡像）
    grain: '.09',
    /* 深色是同一套語言的鏡像：光源翻到下方，所以每一種漸層的兩端也一起對調
       （台紙較亮的那一端、浮起面較亮的那一端、凹窗較暗的那一端）。
       唯一不翻的是 seam —— 它由「紙壓在照片上」的幾何決定，不由光源決定。
       第 2 輪：每一個端點的 L* 與 C* 原封不動，只把色相轉到深色的錨點上
       （＝淺色同名端點的色相 −18.95°）—— 對比因此一位元都沒動，溫度階梯卻回來了。 */
    grad: {
      paper: [['#1F1015', 0], ['#2B1915', 100]],
      win: [['#251417', 0], ['#180B0E', 100]],
      win3: [['#3F2626', 0], ['#2E1A1A', 100]],
      face: [['#2E1A1A', 0], ['#3F2626', 100]],
      cta: [['#D998B4', 0], ['#E9B3CE', 100]],
      seam: [['rgba(0,0,0,0)', 0], ['rgba(0,0,0,.62)', 100]],
    },
    stubFresh: ['#22131C', '#34211A'],
    stubSpent: '#2D2521',
  },
};

/* ── 四階台紙的溫度：一組常數，兩個模式共用 ───────────────────
   相對 board 的 LCh 色相角（度）。這是「凹處偏冷、手澤偏暖」這句話的數值形式。
   G23① 逐項比對淺色與深色，容差 ±TEMP_TOL —— 深色第 1 輪四階全落 6.5° 內，
   這張表會直接把它咬掉。cta 也在表上：主按鈕是「同一支粉還沒褪色的樣子」，
   染料永遠比它印上去的那張泛黃的紙**冷**，兩個模式都是。
   墨（ink/ink2）與訊號色（朱、芽綠）不在這張表上：它們不是這張紙的老化，
   是後來畫上去的東西（紅筆、機制），不參加台紙的溫度階梯。 */
export const TEMP = { board2: -8.7, board3: +6.7, lit: +6.0, cta: -28.2 };
export const TEMP_TOL = 3;

/* 漸層層級的溫度下限（度）。寫死的是**實測下限**：
   淺色 win 比 paper 冷 9.31°、win3 比 paper 暖 4.71°、跨距 15.4°；
   深色（本輪修正後）10.80° / 4.81° / 15.6°。門檻取在實測值下方留一點餘裕，
   但遠高於「一個色相四個明度」會有的 0–5°。 */
export const HUE_MIN = { cool: 6, warm: 3, span: 12 };

/* 「光」與「時間」的分界（度）：光只改明度不改色相，時間會改色相。
   光的漸層（win/win3/face/cta）兩端色相差 ≤LIGHT_DH；
   時間的漸層（paper 的泛黃、剛印好的 stub3）≥TIME_DH。 */
export const LIGHT_DH = 7;
export const TIME_DH = 15;

/* ── 號碼帶的褪色階：剩餘次數就是褪色階（第 2 輪新增）────────────
   票根是照相館的取件存根。號碼帶是**印在紙上的染料**，號碼本身是**碳墨**。
   彩色染料會褪、碳墨不會 —— 這正是整個 app 的粉的出處（青染料先死）。
   所以：這組碼每被用掉一次，號碼帶就往「乾淨的紙」褪一階，而號碼永遠讀得到
   （四階的對比實測全部 12:1 以上，AAA 不動）。褪色階 ＝ 3 − 已經被用掉的次數。

   兩件事讓「時間」長得**不像光**（第 1 輪 R4：平印表面上唯一的漸層不能只是
   一支振幅比較大的光）：
     ① 色相會動。光只改明度（win/win3/face/cta 兩端色相差 ≤7°），
        褪色會把染料抽走、露出底下泛黃的紙，所以色相大幅位移（stub3 兩端差 63°）。
     ② 曲線不是等速的。光是等速的（兩個色停、0%→100%）；褪色是**邊緣加權**的 ——
        只有露在外面的那一段見得到光，所以 STUB_KNEE% 之內就褪完，剩下的幾乎沒動。
        號碼帶因此有三個色停，是全稿唯一非等速的漸層；小字（「邀 請 碼」）落在
        會褪的那一段，號碼落在褪不動的那一段。
   褪到最後（stub0）三個量（色相位移、明度差、彩度）一起趨近於零：
   **褪完了就沒有褪色的方向了**。這與「還沒印上號碼的空票根沒有這條漸層」是同一句話的兩端。 */
export const STUB_KNEE = 35;   // 膝點位置（%）
export const STUB_AT_KNEE = .88; // 膝點已經走完的比例：0→35% 吃掉 88%，35→100% 只剩 12%
export const STUB_END = .85;   // stub0 走到「乾淨的紙」的 85%（留下印過的痕跡，不是全白）
export const USES_TOTAL = 3;   // 一組碼能用幾次（票根下緣印的那個數）
export const STUB_USES = [3, 2, 1, 0];

const mixLch = (a, b, f) => ({ L: a.L + (b.L - a.L) * f, C: a.C + (b.C - a.C) * f, h: ((a.h + dHue(b.h, a.h) * f) % 360 + 360) % 360 });
const toHex = (o) => lchHex(o.L, o.C, o.h);
for (const th of [T.light, T.dark]) {
  const top0 = lch(th.stubFresh[0]), bot0 = lch(th.stubFresh[1]), spent = lch(th.stubSpent);
  for (const n of STUB_USES) {
    const f = (3 - n) / 3 * STUB_END;
    const top = mixLch(top0, spent, f), bot = mixLch(bot0, spent, f);
    th.grad[`stub${n}`] = [[toHex(top), 0], [toHex(mixLch(top, bot, STUB_AT_KNEE)), STUB_KNEE], [toHex(bot), 100]];
  }
}

/* ── 漸層：每一種都要有一個物理上的理由，理由印在 Tokens 板上 ─────────
   全稿只有一個光源假設（淺色從上、深色從下）與一個時間假設（見光的那一邊先褪），
   五種漸層都是這兩句話的落地。verify 的 G22 逐項驗：
     ① 只有垂直（180deg）線性漸層 —— 斜的量不了漸層下的最不利點，量不了就不准壓字
     ② 壓在漸層上的每一個字，以「它蓋到的那一段漸層裡最不利的一點」計對比
     ③ 出現在畫面上的每一種漸層，都要在這張表裡，而且理由印在 Tokens 板上
     ④ 深色的兩端與淺色相反（seam 例外，理由如上）
   flat（平印）刻意**沒有**漸層 —— 那是它的識別：只能讀的東西不接光。 */
export const GRAD_WHY = {
  paper: '台紙本身。相簿翻開時上緣先見光，見光的那一邊先黃 —— 所以每一張紙都是上暖下粉。全稿振幅最小的一支（明度差 4%），但它是光源假設的出處，其他四支都順著它。',
  win: '開窗底（凹）。光被開窗的上緣擋住，陰影落在上緣 —— 上暗下亮。「凹＝可以填」因此多了第四個判準：不只形狀凹，光也進不去。',
  win3: '開窗底的次要面版本（頭像位）。與 win 同一條規則，只是底色是 board3。',
  face: '浮起面（可按）。凸面朝上，上緣接到的光比下緣多 —— 上亮下暗，正好與凹相反。長輩不必分辨陰影方向也知道能不能按，但摸過一次就會記得。',
  cta: '主按鈕的浮起面。與 face 同一條光，只是底色是「還沒褪色的那個粉」—— 台紙是褪過色的，主按鈕是它還沒褪色時的樣子。',
  stub3: '號碼帶．還可以用 3 次（剛產生）。這是全稿唯一「時間」的漸層：染料褪、碳墨不褪。它不是一支振幅比較大的光 —— 光只改明度（其他四支兩端色相差 ≤7°），褪色會把染料抽走露出泛黃的紙，所以兩端色相差 63°；而且它是**邊緣加權**的：只有露在外面的那一段見得到光，35% 之內就褪完，剩下 65% 幾乎沒動（全稿唯一的三色停、唯一非等速的漸層）。',
  stub2: '號碼帶．還可以用 2 次。已經被用掉一次 —— 整條往「乾淨的紙」褪一階：色相位移、明度差、彩度三個量一起降。',
  stub1: '號碼帶．還可以用 1 次。褪到第三階，號碼帶快要跟票根本身的紙分不出來了；號碼本身完全沒有變（碳墨不褪，實測仍 13:1 以上）。',
  stub0: '號碼帶．用完了。三個量都趨近於零 —— **褪完了就沒有褪色的方向了**。這與「還沒印上號碼的空票根沒有這條漸層」是同一句話的兩端：沒印過的不會褪，褪完的也不再褪。',
  seam: '台紙壓在照片上投下的影子。紙有厚度，影子從實到無 —— 全稿唯一不是「明暗」而是「有無」的漸層，也是唯一壓在照片上的（所以它上面永遠沒有字）。它是唯一深色不翻面的漸層：紙的邊緣永遠向上蓋住照片，影子就永遠往上，那是幾何不是光源。',
  perf: '騎縫線。它用 repeating-linear-gradient 的語法，但它是圖樣不是明暗漸層（橫向、1px 高、上面永遠沒有字）—— 全稿唯一的方向例外，列在這裡是為了不讓它變成沒印出來的例外。',
};

/* 刻意**沒有**漸層的表面，每一個都要有理由 —— 「規則有例外可以，例外沒印出來不行」。 */
export const NO_GRAD_WHY = {
  平印: '只能讀的東西不接光：票根外框、明細表、說明框、待核卡片、警語條全部沒有漸層。例外只有兩個，而且是逐個元素標記出來的（data-grad）：號碼帶（stub，那條是褪色不是光）與騎縫線（perf，那是圖樣不是明暗）。G23② 掃的是平印元素**與它所有後代**的 computed background，這兩個標記以外的漸層一律 FAIL —— 上一輪 reviewer 把台紙漸層加到平印面上，71 項 gate 沒有一項會叫。',
  載入中: '按鈕載入中時漸層整條拿掉、換成實色，唇邊與底同色 —— 按不動的東西不反光。這是「就地轉態」在光語言裡的落地，不是另做一顆按鈕。',
  品牌鍵: 'Apple 與 Google 兩顆鍵的外觀由對方的品牌規範決定：實色底、指定的描邊與字色，不加漸層。我們只借幾何（高度、圓角、間距、命中盒），不借光。',
};

export const GRAD_KEYS = ['paper', 'win', 'win3', 'face', 'cta', 'stub3', 'stub2', 'stub1', 'stub0', 'seam'];
export const STUB_KEYS = STUB_USES.map((n) => `stub${n}`);
export const LIGHT_KEYS = ['win', 'win3', 'face', 'cta'];   // 「光」的漸層
export const TIME_KEYS = ['paper', ...STUB_KEYS];           // 「時間」的漸層

/* 產出與比對用的唯一寫法。build 畫的、verify 掃的、Tokens 板印的，都是這一個函式。 */
export const gradCss = (t, name) =>
  `linear-gradient(180deg, ${t.grad[name].map(([c, p]) => `${c} ${p}%`).join(', ')})`;
export const stubOf = (uses) => `stub${uses}`;
export const perfCss = (t) => `repeating-linear-gradient(90deg, ${t.edge} 0 6px, transparent 6px 12px)`;

/* ── 對比門檻：一個數字一個出處 ──────────────────────
   aaa   內文的硬門檻（WCAG 2.1 AAA）。以「漸層最不利點」計，不是以平均值計。
   grain 顆粒層把底乘暗之後的下限。顆粒是每畫素的雜訊，最暗的那一格是極端值，
         不拿它當 AAA 門檻（那會逼整套色階失真），但它必須留在 AA 以上很多。 */
export const CONTRAST = { aaa: 7, grain: 6 };

/* ── 間距：七階，沒有第八階 ──────────────────────────
   每一個 gap / padding / margin 都必須是這七階、FIX 常數、或 0。
   verify.mjs G1 會掃產出的 HTML 逐一驗證。 */
export const SP = { xs: 4, s: 8, m: 12, l: 16, xl: 24, xxl: 32, tap: 44 };
export const GAPS = [4, 8, 12, 16, 24, 32, 44];

/* ── 固定常數：不是間距階，是量出來的實體尺寸 ─────────
   每一個都必須印在 Tokens 板上（「規則有例外可以，例外沒印出來不行」）。 */
export const FIX = {
  safeTop: 59,      // iOS 狀態列
  safeBottom: 34,   // Home indicator
  tap: 44,          // 最小點擊
  button: 56,       // 主要按鈕高
  cell: 80,         // 驗證碼格高
  avatar: 52,       // 待核卡頭像
  gutter: 24,       // 手機版心
  padPad: 56,       // iPad 版心（直）
  padPadX: 64,      // iPad 版心（橫）
  padSheet: 48,     // 交付板（Tokens／Notes／壓力板）版心
  btnMax: 360,      // iPad 主按鈕寬度上限
  codeLine: 64,     // 票根數字帶的高度（＝60pt 的行高）；空票根用同一個值，兩者外框才會等高
  capAlign: 29,     // iPad 跨欄 cap-height 對齊補償（右欄選項卡往下推，讓右欄首卡標題 28/34
  //                   的 cap 對齊左欄 H1 42/50 的 cap；左欄 H1 上方有帳號列 44＋間距 24）
  navOpt: 6,        // 返回鍵圖示的視覺左對齊（負值外推）
  seam: 20,         // iPad 卡紙壓過照片的重疊
  seamPhone: 34,    // 手機卡紙壓過照片的重疊
  lip: 3,           // 浮起表面的下緣唇邊
  errBar: 2,        // 錯誤線（比唇邊薄，且與唇邊不共邊）
  hair: 1,          // 切邊
  /* 系統開關的解剖照 Apple 官方 design kit（iOS/iPadOS 27）：軌道 51×31、把手 27，
     所以把手與軌道的間隙是 (31−27)/2 = 2。第 1 輪自己畫的是 56×32／26／間隙 3 ——
     長得像但不是系統的那一個。識別層（凹浮平印、芽綠）留著，**解剖照系統**：
     長輩在別的 app 學會的那個開關，在這裡要一樣大、一樣的行程。 */
  switchW: 51, switchH: 31, switchKnob: 27,
};
FIX.knob = (FIX.switchH - FIX.switchKnob) / 2;   // ＝2，推導值不是新常數

/* ── 字級：十階，誠實列出 ────────────────────────────
   6 階文字 + 2 階數字 + 2 階 iPad 加大。沒有第十一階。 */
export const SIZES = [60, 42, 36, 34, 28, 22, 19, 17, 15, 13];

export const FONT = `-apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang TC", "Noto Sans TC", "Helvetica Neue", sans-serif`;
export const MONO = `ui-monospace, 'SF Mono', 'SFMono-Regular', Menlo, monospace`;

export const TY = {
  d: 'font-size:34px;line-height:40px;font-weight:700;letter-spacing:-.012em',  // 只在歡迎頁
  h: 'font-size:28px;line-height:34px;font-weight:700;letter-spacing:-.01em',   // 每畫面 1 個
  c: 'font-size:22px;line-height:28px;font-weight:600;letter-spacing:-.005em',  // 每畫面 ≤1
  b: 'font-size:17px;line-height:25px;font-weight:400',
  bs: 'font-size:17px;line-height:25px;font-weight:600',
  l: 'font-size:15px;line-height:21px;font-weight:600',
  cap: 'font-size:13px;line-height:18px;font-weight:500',
  // 數字（等寬）：只有兩種正典
  n1: `font-family:${MONO};font-variant-numeric:tabular-nums;font-size:60px;line-height:64px;font-weight:600;letter-spacing:.04em`,
  n2: `font-family:${MONO};font-variant-numeric:tabular-nums;font-size:36px;line-height:40px;font-weight:600`,
  // iPad 加大（同一套階，只有這兩個往上加）
  dHero: 'font-size:60px;line-height:68px;font-weight:700;letter-spacing:-.02em',   // 與票根同一階（60），iPad 歡迎頁
  dPad: 'font-size:42px;line-height:50px;font-weight:700;letter-spacing:-.015em',
  bPad: 'font-size:19px;line-height:28px;font-weight:400',
  bPadS: 'font-size:19px;line-height:28px;font-weight:600',
};

/* H1 起跑線：同一組的畫面共用一條線。分組是明講的，不是用檔名猜的。
   排除的板也明講：iPad 兩板走跨欄基線、AX 壓力板字級是 ×3.1、板中板與交付板不是畫面。 */
export const H1_GROUPS = {
  有步驟條: ['Email', 'EmailError', 'EmailSending', 'Otp', 'OtpError', 'OtpErrorDark', 'JoinCode', 'JoinCodeDark', 'JoinExpired', 'JoinUsedUp'],
  無步驟條: ['Fork', 'CreateFamily', 'CreateFamilySending', 'Pending', 'InviteEmpty', 'InviteGenerating',
    'InviteReady', 'InviteApprovalOff', 'InviteApprovalOffDark', 'InviteRequests', 'InviteRequestsMany'],
  '歡迎頁（H1 在卡紙裡）': ['Main', 'WelcomeDark'],
};
export const H1_EXCLUDED = ['WelcomeIPad', 'ForkIPad', 'StressType', 'StressLoginAX', 'StressCodeAX', 'StressContent', 'Tokens', 'Notes', 'AppIcon'];

/* cap-height 佔字級的比例（SF Pro / PingFang 實測近似）。
   iPad 跨欄基線與 H1 分組基線都用這個常數換算，verify 也用同一個。 */
export const CAP = 0.72;

/* AX5 ≈ 310%。壓力板用，是推導值不是新階。 */
export const AX = 3.1;
export const ax = (px) => Math.round(px * AX);

/* ── 呼吸帶兩條規則的門檻：一個數字一個出處 ──────────
   pause  ①「內容首末之間，任何一段連續空白 ≤120px」的門檻
   btnPct ②「主按鈕中心須落在畫面 70% 以內」的門檻
   板上印的、measure.mjs 分流用的、verify.mjs 判定用的，全部讀這裡。
   刻意不放進 FIX：FIX 的值同時是 G1 允許的間距白名單，門檻不是間距。 */
export const RULE = { pause: 120, btnPct: 70 };

/* ── 產物與量測資料的綁定（G21）──────────────────────
   build.mjs 把它「當次讀到的 measured.json」的指紋寫進每一張產物，
   verify.mjs 拿現行 measured.json 的指紋比對 —— 不一致＝板上印的實測句是上一版的。
   兩邊算法必須是同一份，所以定義在這裡。 */
export const hash12 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 12);
