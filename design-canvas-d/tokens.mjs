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
/* 量測回來的顏色是 [r,g,b]（0–255）不是 hex —— 刻度、照片、玻璃那幾條 gate
   量的都是「畫面上算出來的顏色」，所以 Lab 與 ΔE 另備一組吃陣列的。同一條算式。 */
export const labRgb = (c) => {
  const [r, g, b] = c.slice(0, 3).map((v) => srgbToLin(v / 255));
  const xyz = [(.4124564 * r + .3575761 * g + .1804375 * b) / WP[0],
    (.2126729 * r + .7151522 * g + .0721750 * b) / WP[1],
    (.0193339 * r + .1191920 * g + .9503041 * b) / WP[2]];
  const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : (841 / 108) * t + 4 / 29);
  const [fx, fy, fz] = xyz.map(f);
  return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
};
export const dERgb = (a, b) => { const x = labRgb(a), y = labRgb(b); return Math.hypot(x[0] - y[0], x[1] - y[1], x[2] - y[2]); };
/* 一格刻度「看起來的顏色」＝底色與銷記的墨按覆蓋率合成。
   覆蓋率不是手填的：它是銷記那一筆的多邊形面積除以格子面積（brush.mjs 的 polyArea），
   而且 verify 會拿**板上那條 path** 重算一次再比對（與 G26「板上畫的就是被量的那一份」同一招）。 */
export const cellSeen = (cell, cov) => (cell.ink && cell.ink.length === 3
  ? cell.bg.map((v, i) => v * (1 - cov) + cell.ink[i] * cov)
  : cell.bg.slice(0, 3));
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
    /* dir ＝ 光從哪邊來：+1 上、−1 下。**同一個常數同時決定四件事** ——
       凹的內陰影落在哪一緣、浮起的落影往哪邊投、平印的亮邊翻到哪一緣、
       漸層的兩端誰亮。第 2 輪這四件事在深色下互相牴觸（bevelTop/bevelBot 沒鏡像、
       lift 還在往下投），同一個元件上有兩個互相矛盾的光源。G24 逐個使用點驗它。 */
    dir: +1,
    board: '#F4DFDB', board2: '#E7CDCB', board3: '#E2C6BE', lit: '#FBEBE4',
    ink: '#2A1219', ink2: '#3E232B',
    cta: '#86183F', ctaDeep: '#4A0722', ctaBusy: '#5E0A2A', onCta: '#FEF3F0',
    pen: '#7E1414', sprout: '#1C4630', onSprout: '#FEF3F0',
    edge: '#8C6159',
    /* 系統開關的兩個零件（解剖照 Apple design kit）。把手在四種組合裡都是同一個顏色 ——
       官方 kit 的 Light/Dark × ON/OFF 四顆，把手全部是白的（見 kit-Toggles 匯出）。
       第 2 輪的 OFF 把手用 board3 坐在 win 上，實測 1.04:1：全稿唯一會出事的可用性缺陷。 */
    knob: '#FFFFFF', wellEdge: '#6E4640',
    /* 系統的 Liquid Glass。這兩個值**不是我們的表面語言** —— 它們是為了在稿上
       畫出「系統材質疊在我們的紙上會長什麼樣」而存在的，唯一的使用點是 GlassSeam 板。
       真的實作時這一層由系統畫（.presentationBackground 之類），我們一個像素都不出。 */
    glassFill: 'rgba(251,235,228,.72)', glassEdge: 'rgba(255,255,255,.62)', glassDim: 'rgba(42,18,25,.10)',
    appleBg: '#000000', appleFg: '#FFFFFF',
    /* 第三方品牌鍵：外觀由對方的規範決定，不吃我們的色。列在這裡是因為
       「沒印出來的例外就是 bug」——它們是全稿唯二不走台紙色的表面。 */
    googleBg: '#FFFFFF', googleFg: '#1F1F1F', googleLine: '#747775',
    /* 極性（不是位置）：bevelLit ＝ 被照到的那一壁、bevelDark ＝ 背光的那一壁。
       bevelTop／bevelBot 是由 dir 推出來的**位置別名**（見檔案下方），
       所以「哪一緣亮」永遠是光源方向的結果，不可能再有人單獨改一邊。 */
    bevelLit: 'rgba(255,246,242,.78)', bevelDark: 'rgba(42,18,25,.34)', bevelSoft: 'rgba(42,18,25,.22)',
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
      well: [['#866867', 0], ['#957B7A', 100]],
      seam: [['rgba(42,18,25,0)', 0], ['rgba(42,18,25,.42)', 100]],
    },
    /* 號碼帶的兩個錨點：剛印好的染料帶（上緣已經見過光，所以上淺下濃），
       與褪到底之後剩下的東西 —— 票根自己那張泛黃的紙。 */
    stubFresh: ['#FAEADE', '#ECD0D6'],
    stubSpent: '#F7ECE4',
  },
  dark: {
    dir: -1,                                   // 深色：光從下面來
    board: '#261416', board2: '#1F1013', board3: '#372020', lit: '#462B28',
    ink: '#F8E7E2', ink2: '#DCBEBC',
    cta: '#E3A9C4', ctaDeep: '#995F7F', ctaBusy: '#C39BAE', onCta: '#261416',
    /* 朱（紅筆）：第 6 輪 D5-03 從 #FFAE86 改成 #FFAC9E。
       舊值的色相是 52.16°，比淺色的朱（34.23°）**往暖轉 +17.94°** —— 而全稿四階台紙在
       深色下是往冷轉 −19° 到 −21°。一支顏料在同一份設計裡往兩個相反的方向跑，
       只能是巧合或藉口。改法回到隱喻本身：**朱是筆，不是紙**。
       紙會因為時間與光改變顏色（那是四階台紙那條 −19° 的來源）；筆的顏料不會 ——
       白天寫的紅字與晚上寫的紅字是同一支筆。所以深色的朱與淺色的朱**同一個色相角**
       （實測差 0.09°），變的只有兩件事，而且兩件都是被逼的：
         · L* 26.70 → 78.02：深底上要維持 AAA，紅必須變亮（實測對深色四階 7.12–10.20:1）
         · C* 52.84 → 34.85：sRGB 在 L*78 上這個色相角的可表示彩度上限就是 34.85
           （掃描過：再高就出界）—— 不是我們選擇讓它變淡。
       G23⑥ 把這三句話變成三個斷言。 */
    pen: '#FFAC9E', sprout: '#8FD2A6', onSprout: '#261416',
    edge: '#A0807C',
    knob: '#FFFFFF', wellEdge: '#5A3B37',
    glassFill: 'rgba(55,32,32,.70)', glassEdge: 'rgba(255,255,255,.16)', glassDim: 'rgba(0,0,0,.28)',
    appleBg: '#FFFFFF', appleFg: '#000000',
    googleBg: '#131314', googleFg: '#E3E3E3', googleLine: '#8E918F',
    /* 第 2 輪的 bug（reviewer 的 M3 突變在這裡有真實對應）：深色的 bevelTop 是暗的、
       bevelBot 是亮的 —— 與淺色同極性。可是深色的光從下面來，凹進去的洞裡，
       被照到的是**上**內壁、暗的是下內壁。所以同一個 win() 在深色下印出來的是
       「光從上」，而同一張板的 press 印的是「光從下」：一個元件兩個互相牴觸的光源，
       而且錯的那一支振幅（.6）是對的那一支（.20）的三倍，所以錯的那個看起來還比較像真的。
       這一輪 bevelTop 一律是「受光緣」、bevelBot 一律是「背光緣」，光的方向由 dir 決定。 */
    bevelLit: 'rgba(255,214,208,.26)', bevelDark: 'rgba(0,0,0,.62)', bevelSoft: 'rgba(0,0,0,.45)',
    lift: '0 -1px 0 rgba(0,0,0,.5), 0 -8px 16px -10px rgba(0,0,0,.9)',
    /* 淺色的 press 是「亮邊在下」（光從上，壓進去的字，遠側那一壁被照到）。
       深色的鏡像因此是「亮邊在上」—— 位置翻面，**極性也要跟著翻**。
       第 2 輪只翻了位置沒翻極性（暗邊在上），那讀起來還是光從上面來。 */
    press: '0 -1px 0 rgba(255,214,208,.22)',
    grain: '.09',
    /* 深色是同一套語言的鏡像：光源翻到下方，所以每一種漸層的兩端也一起對調
       （台紙較亮的那一端、浮起面較亮的那一端、凹窗較暗的那一端）。
       唯一不翻的是 seam —— 它由「紙壓在照片上」的幾何決定，不由光源決定。
       第 2 輪：每一個端點的 L* 與 C* 原封不動，只把色相轉到深色的錨點上。
       **「−18.95°」這個數只對實體 token（board／board2／board3／lit／cta）成立**——
       漸層端點是另一回事，它們各自順著自己那一支的光走，兩端跨距最大到 78°。
       第 2 輪把這個數寫成「所有東西都轉了 −18.95°」，reviewer 實測，那是假的。
       而且「對比一位元都沒動」字面上也是假的：sRGB 是 8 bit，固定 L* 轉色相之後
       每個通道各自進位一次，實測整批對比變動在 0.04:1 以內（Tokens 板印實測上界）。 */
    grad: {
      paper: [['#1F1015', 0], ['#2B1915', 100]],
      win: [['#251417', 0], ['#180B0E', 100]],
      win3: [['#3F2626', 0], ['#2E1A1A', 100]],
      face: [['#2E1A1A', 0], ['#3F2626', 100]],
      cta: [['#D998B4', 0], ['#E9B3CE', 100]],
      well: [['#261418', 0], ['#1D0C10', 100]],
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
/* 位置別名：凹進去的洞裡，被照到的是**離光源遠**的那一壁。
   淺色光從上 ⇒ 上緣背光（暗）、下緣受光（亮）；深色光從下 ⇒ 整個翻過來。
   第 2 輪深色兩邊都沒翻（上暗下亮，與淺色同極性），所以同一個 win() 在深色下
   說「光從上」，而同一張板的 press／漸層說「光從下」——一個元件兩個光源。
   現在這兩個名字是推出來的，翻面是自動的。 */
for (const th of [T.light, T.dark]) {
  th.bevelTop = th.dir > 0 ? th.bevelDark : th.bevelLit;
  th.bevelBot = th.dir > 0 ? th.bevelLit : th.bevelDark;
}

/* 「凹」的兩族白名單。build.mjs 的 INSET_FAM、_probe.html 的 INSET_OK、
   verify 的 G5 都應該讀得到同一份 —— 這裡是它的規格出處（板上也印這一份）。 */
export const INSET_KEYS = { fillable: ['field', 'cell', 'codeslot', 'tray', 'switchTrack'], mount: ['photo', 'avatar'] };

export const TEMP = { board2: -8.7, board3: +6.7, lit: +16.5, cta: -28.2 };
export const TEMP_TOL = 3;

/* 第 3 輪 R1：G23① 原本只驗**角度**，而角度在低彩度上等於沒有溫度 ——
   淺色 lit 宣告 +6.0°、實測 +6.05°，這一項一路綠燈；但它的 C* 只有 4.2，
   6° 的色相位移單獨貢獻的 ΔE 是 **0.51**，在 JND（≈1）之下：
   「四階台紙有溫度層次」這句話在最亮的那一階上是量得出來的假。
   兩件事一起修：
     ① 門檻從角度改成 ΔE —— 每一階的色相位移**單獨**要貢獻 ΔE ≥ HUE_DE_MIN；
     ② lit 真的把溫度做出來：TEMP.lit 從 +6.0 抬到 +16.5，色 #FEF3F0 → #FBEBE4。
   為什麼是 lit 抬角度而不是加彩度：概念上 lit 是「還沒被翻過的新紙」＝**還沒開始褪的原色**，
   它離「褪過的台紙」最遠是對的；而 C* 必須維持四階最低（越老才越有顏色，G23③ 的
   淺色階梯就是這條），所以能動的只有角度。抬完之後四階的溫度也不再兩兩重疊
   （第 2 輪 lit +6.05° 與 board3 +6.71° 幾乎同溫，等於四階只有三種溫度）。
   為什麼不寫成 lchHex() 的推導值：L*96 附近的 sRGB 是 8 bit 的粗網格，那個高度上
   找不到落在宣告角度上的可表示點（推導出來的 #FFF3ED 實測位移 20.2°，離宣告的 16.5°
   有 3.7°—— 推導反而製造漂移）。所以四階一律是實值，關係由 G23① 守。
   新的 lit：L* 96.6→94.11（仍是四階最亮，board 90.4）、C* 6.82（仍是四階最低）、
   位移 +16.53°、單獨貢獻 ΔE 2.16。L* 動了 2.5 ⇒ 對比會動一點點，動多少由板上實測。 */
export const HUE_DE_MIN = 1.0;
/* 色相位移**單獨**貢獻的 ΔE：固定 L* 與 C*，只把色相轉回台紙本體的角度，量兩者的距離。
   板上印的、G23① 判的是同一個函式。 */
export const hueDE = (th, k) => {
  const c = lch(th[k]);
  return dE(lchHex(c.L, c.C, c.h), lchHex(c.L, c.C, lch(th.board).h));
};

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
  stub3: '號碼帶．還可以用 3 次（剛產生）。這是全稿唯一「時間」的漸層：染料褪、碳墨不褪。它不是一支振幅比較大的光 —— 光只改明度（其他四支兩端色相差 ≤7°），褪色會把染料抽走露出泛黃的紙，所以兩端色相差 63°；而且它是<b>邊緣加權</b>的：只有露在外面的那一段見得到光，35% 之內就褪完，剩下 65% 幾乎沒動（全稿唯一的三色停、唯一非等速的漸層）。',
  stub2: '號碼帶．還可以用 2 次。已經被用掉一次 —— 整條往「乾淨的紙」褪一階：色相位移、明度差、彩度三個量一起降。',
  stub1: '號碼帶．還可以用 1 次。褪到第三階，號碼帶快要跟票根本身的紙分不出來了；號碼本身完全沒有變（碳墨不褪，實測仍 13:1 以上）。',
  stub0: '號碼帶．用完了。三個量都趨近於零 —— <b>褪完了就沒有褪色的方向了</b>。這與「還沒印上號碼的空票根沒有這條漸層」是同一句話的兩端：沒印過的不會褪，褪完的也不再褪。',
  well: '審核開關關掉時的軌道 ＝ 台紙被打穿之後那個空的槽。與 win 同一條光（凹進去的地方上暗下亮），只是深得多 —— 因為它必須讓把手（那片打孔留下的紙圓片）在 1 公尺外看得出來停在哪一端：實測對比印在 Tokens 板上，硬門檻 3:1。第 2 輪的 OFF 把手對軌道只有 1.04:1，是全稿唯一會出事的可用性缺陷。',
  seam: '台紙壓在照片上投下的影子。紙有厚度，影子從實到無 —— 全稿唯一不是「明暗」而是「有無」的漸層，也是唯一壓在照片上的（所以它上面永遠沒有字）。它是唯一深色不翻面的漸層：紙的邊緣永遠向上蓋住照片，影子就永遠往上，那是幾何不是光源。',
};

/* 騎縫線第 4 輪還在這張表裡（它那時是一條 repeating-linear-gradient 的圖樣）。
   本輪它改成遮罩挖出來的洞 —— 遮罩不是背景，所以它從漸層清冊裡整個離開：
   平印面上合法的背景漸層因此從兩個減成**一個**（只剩號碼帶）。理由見 PERF。 */
/* ── 斷面唇的色差（第 8 輪；PERF_WHY 的誠實話與 G27⑥ 用）───────────────
   唇是半透明的（rgba），所以先合成到台紙上再量 —— 量的是「畫出來之後看到的顏色」，
   不是宣告的顏色。四個值（淺／深 × 亮壁／暗壁）取最小與最大。 */
const rgbaOf = (str) => { const m = /rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)/.exec(str); return [+m[1], +m[2], +m[3], m[4] === undefined ? 1 : +m[4]]; };
const overBg = (fg, bg) => { const [r, g, b, a] = rgbaOf(fg); return [r * a + bg[0] * (1 - a), g * a + bg[1] * (1 - a), b * a + bg[2] * (1 - a)]; };
export const LIP_DE = (() => {
  const v = [];
  for (const th of [T.light, T.dark]) { const bg = hexRgb(th.board); for (const k of ['bevelLit', 'bevelDark']) v.push(dERgb(overBg(th[k], bg), bg)); }
  return [Math.min(...v), Math.max(...v)];
})();
export const PERF_WHY = `騎縫線＝紙被打穿。它不是畫上去的線，是遮罩挖掉的洞：底下透出來的是台紙本身。票根（還沒撕）上下兩半各切自己那一緣的一半，合起來是完整的圓孔；托盤（已經從我們自己那張紙上撕下來）只切上緣，留下半圓的扇貝邊。齒距綁 ax()，所以字級放大時紙上的齒跟著變大。<b>第 6 輪再進一步：那些洞不再等距、也不再一樣大</b> —— 五顆一循環的抖動（圓心偏移最大 0.21 個齒距、半徑比例 0.82–1.14），因為等距等大的圓孔是打孔機打的，手撕不會。抖動是<b>寫死的一組數不是亂數</b>：產物可重現、gate 驗得到，而且「抖多少」是設計決定的。撕口另外有一道 <b>1px 的斷面唇</b>（紙芯露出來、在光下反光），用 drop-shadow 畫 —— 它吃的是遮罩之後的輪廓，所以那道唇沿著每一顆扇貝的弧走；box-shadow 只會沿著矩形。唇的顏色由 dir 決定（朝光＝亮邊、背光＝暗邊），沒有第二個光源。<b>誠實話（第 8 輪；第 5 輪 reviewer 對這一手的評語是「加了一個沒人看得到的東西」）</b>：那道唇的顏色與台紙的色差是 ΔE ${LIP_DE.map((v) => v.toFixed(1)).join('–')}（JND 是 ${HUE_DE_MIN}，所以它<b>不是</b>一個看不見的顏色），可是它<b>只有一個裝置像素高</b> —— 這張 1290px 寬的板被縮到螢幕上看的時候，它確實在感知閾之下。留著的理由是尺度：1:1（手機真的畫出來的大小）時它才是「撕口的斷面」與「用刀切齊的邊」的分界，而這一稿的票根在手機上就是 1:1。<b>兩件事都寫在這裡</b>，不留給看板的人自己發現：顏色差得到，高度看不到。`;

/* 刻意<b>沒有</b>漸層的表面，每一個都要有理由 —— 「規則有例外可以，例外沒印出來不行」。 */
export const NO_GRAD_WHY = {
  平印: '只能讀的東西不接光：票根外框、明細表、說明框、待核卡片、警語條全部沒有漸層。例外只有<b>一個</b>，而且是逐個元素標記出來的（data-grad）：號碼帶（stub，那條是褪色不是光）。第 4 輪還有第二個例外（騎縫線），第 5 輪它改成遮罩挖出來的洞 —— 遮罩不是背景，所以它整個離開了漸層清冊。G23② 掃的是平印元素<b>與它所有後代</b>的 computed background，這個標記以外的漸層一律 FAIL —— 上一輪 reviewer 把台紙漸層加到平印面上，71 項 gate 沒有一項會叫。',
  載入中: '按鈕載入中時漸層整條拿掉、換成實色，唇邊與底同色 —— 按不動的東西不反光。這是「就地轉態」在光語言裡的落地，不是另做一顆按鈕。',
  品牌鍵: 'Apple 與 Google 兩顆鍵的外觀由對方的品牌規範決定：實色底、指定的描邊與字色，不加漸層。我們只借幾何（高度、圓角、間距、命中盒），不借光。',
};

export const GRAD_KEYS = ['paper', 'win', 'win3', 'face', 'cta', 'well', 'stub3', 'stub2', 'stub1', 'stub0', 'seam'];
export const STUB_KEYS = STUB_USES.map((n) => `stub${n}`);
export const LIGHT_KEYS = ['win', 'win3', 'face', 'cta', 'well'];   // 「光」的漸層
export const TIME_KEYS = ['paper', ...STUB_KEYS];           // 「時間」的漸層

/* 產出與比對用的唯一寫法。build 畫的、verify 掃的、Tokens 板印的，都是這一個函式。 */
export const gradCss = (t, name) =>
  `linear-gradient(180deg, ${t.grad[name].map(([c, p]) => `${c} ${p}%`).join(', ')})`;
export const stubOf = (uses) => `stub${uses}`;

/* ── 騎縫線：紙的形狀，不是印在紙上的線（第 5 輪 D4-04）──────────────────
   第 4 輪的判定：那條「騎縫線」是 1px 高的 repeating-linear-gradient，畫材是
   edge（＝印上去的框的顏色），撕了也不會有東西分開，AX5 下不變大 ——
   **它是一條裝飾線，不是一道齒孔**。真的騎縫線是紙被打穿：撕開之前是一排圓孔，
   撕開之後留下半圓的扇貝邊。

   所以這一版用遮罩把紙**真的挖掉**（radial-gradient 的 transparent 是洞，
   底下透出來的是台紙本身，不是我們畫的另一個顏色）：
     · 圓孔：一排 r=PERF.r 的洞，齒距綁 ax() —— 字級放大時紙上的齒也跟著變大，
       因為那是同一張紙上的東西（第 4 輪它是硬寫的 12px，AX5 下紙變大、齒不變）。
     · 邊緣的半圓缺口：票根左右兩緣各咬掉一口。這是印刷品被打孔機咬過的證據。
   兩種切法各有意思，而且是可以被 gate 咬的區別：
     joined（票根）  上下兩半各在自己那一緣切一半 → 合起來是**完整的圓孔**（還沒撕）
     torn  （托盤）  只有一緣被切 → **半圓的扇貝邊**（已經從我們自己那張紙上撕下來）
   遮罩不是背景，所以騎縫線從此不在「漸層清冊」裡 —— 平印面上的背景漸層例外
   因此從兩個減成一個（只剩號碼帶）。 */
export const PERF = {
  r: 4,        // 圓孔半徑
  pitch: 18,   // 齒距（孔心到孔心）；AX 板用 ax(pitch)
  notch: 10,   // 左右兩緣的半圓缺口半徑
  band: 20,    // 齒孔帶的高度（＝2×notch，缺口不會被切掉一半）
};
/* 一層遮罩 ＝ 一種形狀。三層取交集（intersect）：一排圓孔 ∩ 左缺口 ∩ 右缺口。
   edge='bottom' 切自己的下緣、'top' 切自己的上緣。位置用百分比不用 px ——
   元件高度會隨 Dynamic Type 變，用 px 的話齒孔會跑掉。 */
/* ── 撕邊不是機器切的（第 6 輪 D5-06）────────────────────────────────
   第 5 輪把騎縫線從「畫上去的線」改成「遮罩挖掉的洞」——那一步是對的，但那些洞
   **等距而且一樣大**：那是打孔機打出來的，不是手撕的。真的撕開一張紙，齒的間距與
   大小都會抖，而且撕口的斷面會露出紙芯，在光下是一道很細的亮唇（軌 C 的 paper-edge
   已經證明這一手有效）。兩件事一起補，兩件都**不是隨機數**：
     · JITTER 是一組寫死的抖動（五顆一循環），所以產物可重現、gate 驗得到，
       而且「抖多少」是設計決定的不是亂數決定的（dx 是齒距的比例、dr 是半徑的比例）
     · 亮唇由 dir 決定顏色：撕口朝著光就是亮邊、背著光就是暗邊 —— 沒有第二個光源
   五顆一循環（不是三顆）是刻意的：托盤寬約 342px、齒距 18px，五顆的週期 90px
   在一條邊上會重複不到四次，眼睛讀不出那是一個循環。 */
export const PERF_TILE = 5;
export const JITTER = [
  { dx: 0, dr: 1 },
  { dx: .18, dr: .82 },
  { dx: -.12, dr: 1.14 },
  { dx: .07, dr: .93 },
  { dx: -.21, dr: 1.06 },
];
export const perfMask = (edge, pitch = PERF.pitch, { r = PERF.r, notch = PERF.notch } = {}) => {
  const y = edge === 'top' ? '0' : '100%';
  const hole = (cx, rad) => `radial-gradient(circle ${rad}px at ${cx} ${y}, transparent ${rad}px, #000 ${rad + 0.5}px)`;
  const tile = PERF_TILE * pitch;
  const teeth = JITTER.map((j, i) => hole(`${((i + .5 + j.dx) * pitch).toFixed(2)}px`, +(r * j.dr).toFixed(2)));
  const img = [...teeth, hole('0', notch), hole('100%', notch)].join(', ');
  const size = [...teeth.map(() => `${tile}px 100%`), '100% 100%', '100% 100%'].join(', ');
  const rep = [...teeth.map(() => 'repeat-x'), 'no-repeat', 'no-repeat'].join(', ');
  const n = teeth.length + 1;   // composite 的層數比 image 少一層
  return `-webkit-mask-image:${img};-webkit-mask-size:${size};-webkit-mask-repeat:${rep};-webkit-mask-composite:${Array(n).fill('source-in').join(',')};`
    + `mask-image:${img};mask-size:${size};mask-repeat:${rep};mask-composite:${Array(n).fill('intersect').join(',')}`;
};
/* 撕口的斷面。drop-shadow 吃的是**遮罩之後的輪廓**（不是矩形的 box），
   所以這道 1px 的唇會沿著每一顆扇貝的弧走 —— box-shadow 做不到這件事。 */
export const perfLip = (th, edge) => {
  const lit = th.dir > 0 ? edge === 'top' : edge !== 'top';
  return `filter:drop-shadow(0 ${edge === 'top' ? -1 : 1}px 0 ${lit ? th.bevelLit : th.bevelDark})`;
};

/* ── 深色的照片：少一格光（第 5 輪 D4-03）───────────────────────────
   第 4 輪實測：深色版的照片與淺色版逐像素平均差 ΔRGB −2.6 ——
   「這一稿蓋了一個有光源、有時間的世界，唯獨照片不在裡面。」

   為什麼不照台紙的比例降：台紙從 Y=0.771 掉到 0.0097（1.3%），照片跟著掉就是一塊黑。
   相紙不是台紙 —— 它是這本相簿裡唯一自己就是影像的東西，把它降到紙的比例等於把主角關掉。
   所以規則用攝影自己的單位寫：**夜裡少一格光**（曝光少一格 ＝ 亮度剩一半）。
   sRGB 的 brightness() 是通道乘法，所以 0.5^(1/2.2)=0.73 —— 這個數是推出來的，
   實測（probe 逐像素）平均亮度比 0.497、p99 比 0.490，兩者都落在「一格」上。
   誠實話（印在 Tokens 板上）：少一格之後照片的白仍然比它裱在上面的紙亮十幾倍。
   一格是「看得出來變暗、而且長輩仍然看得清楚祖母的臉」之間的取捨，不是物理的終點。 */
export const PHOTO_STOP = 0.5;                       // 一格＝亮度剩一半
export const PHOTO_DIM = +(PHOTO_STOP ** (1 / 2.2)).toFixed(2);   // ＝0.73，寫進 CSS 的 brightness()
export const PHOTO_STOP_TOL = 0.04;

/* ── 三格刻度的可讀性門檻（第 5 輪 D4-01）──────────────────────────
   第 4 輪實測：五個狀態裡有三個狀態的刻度**逐格顏色完全一樣**（ΔE=0）——
   因為「還沒用的格」永遠畫 stub3、「用掉的格」永遠畫 stub0，
   號碼帶自己走到第幾階從來沒有出現在刻度上。兩件事一起修（見 build 的 stubScale）：
     ① 還沒用的格改畫**當前階**（與號碼帶同一支漸層，ΔE→0）
     ② 用掉的格蓋一道**朱筆銷記**（照相館的存根蓋銷）
   門檻：相鄰狀態之間，同一個格位的最大 ΔE ≥ adj；剛印好 ↔ 用完了之間，
   三個格位**每一個**都要 ≥ ends。逐格對位比，因為人讀的是「哪一格不一樣」。

   **第 6 輪 D5-02：這三個數改寫成推導**（可推導的門檻不該是手寫的字面值）。
   全部長在 HUE_DE_MIN（＝CIE ΔE*ab 的 JND，剛好分得出來的最小色差）上：
     band ＝ 1 個 JND  ——「未用格與號碼帶是同一支漸層」＝ 兩者的差要在人眼分不出來之內
     adj  ＝ 3 個 JND  —— 相鄰兩態要「一眼讀得出不一樣」，不是「盯著比才看得出來」
     ends ＝ 2 × adj   —— 兩端之間隔了三步；每一步都要達到 adj，兩端至少是相鄰的兩倍
   換句話說：這三個門檻只有一個自由參數，而那個參數有外部出處。 */
export const SCALE_DE = { adj: 3 * HUE_DE_MIN, ends: 6 * HUE_DE_MIN, band: 1 * HUE_DE_MIN };

/* ── 具名豁免登記簿（第 5 輪 D4-07②）────────────────────────────
   第 4 輪的 M1b：在任何一個元素上加 data-light="隨便什麼值" 就能讓它整個豁免 G24 的
   光方向檢查，而且**沒有任何一份清單記得誰被豁免了** —— 那正好違反 GlassSeam 板
   自己寫的規則③（「豁免必須是具名的」）。

   這張表是那份具名清單，而且是**等於**不是包含：
     · 畫面上出現的每一個豁免標記，都必須在這裡（多一個 → FAIL）
     · 這裡的每一筆，畫面上都必須真的用到（少一個 → FAIL，死掉的豁免也是漏洞）
     · _probe.html 只認這張表裡的 marker+role；不在表上的值不豁免（所以 M1b 那一招
       現在會**同時**踩到兩條線：豁免不生效、而且登記簿對不上）
   欄位：marker（屬性）／role（屬性值）／files（哪幾張板）／gate（豁免哪一條）／why。 */
export const EXEMPT = [
  {
    marker: 'data-sys', role: 'glass', gate: 'G24',
    files: ['GlassSeam'],
    why: '系統的 Liquid Glass 由系統畫，它的邊緣高光方向由系統決定；拿我們的 dir 去驗它只會驗出假的 FAIL。理由與這一條豁免本身都印在 GlassSeam 板的規則③上。',
  },
  {
    marker: 'data-sys', role: 'grabber', gate: 'G24',
    files: ['GlassSeam'],
    why: '系統 sheet 的抓桿，與玻璃同一層、同一個理由 —— 它是系統 chrome 的一部分，不是我們畫的表面。',
  },
  {
    marker: 'data-light', role: 'geometry', gate: 'G24',
    files: ['WelcomeIPad'],
    why: 'iPad 內容欄的左緣投影是**幾何**造成的（那張紙壓在照片上，影子往左投），不是上下受光緣；G24 驗的是上下緣的相對亮度，對一道左向投影沒有意義。',
  },
  {
    marker: 'data-veto', role: 'icon-concept', gate: 'G26',
    files: ['AppIcon'],
    why: '使用者於 2026-08-23 否決了「app icon ＝ 一個字」這個概念本身（不是筆觸、不是尺寸 —— 是字形 icon 這件事），外部 icon 素材另外生成中。所以 AppIcon 板整張凍結在被否決的那一版，G26／G26b／G26c 三族在這張板上暫停：它們量的是「那顆落款印讀不讀得出來」，而那顆印已經不是我們要交的東西了。恢復條件＝外部素材到位、AppIcon 板重做，屆時把這一筆從登記簿刪掉，三族自動恢復（刪不掉就是還沒重做）。',
    /* 反向鎖（第 8 輪 D7-03）：這一筆豁免說的是「這張板凍結在**被否決的那一版**」。
       只有理由沒有雜湊的話，那句話是空的 —— 誰動了這張板，豁免照樣生效，
       而它豁免掉的是整整三族 gate。所以把被否決版的內容雜湊釘在這裡：
       板一改，MG2⑥ 當場紅，這一筆豁免失效（要嘛把板改回去，要嘛這一筆本來就該刪了）。
       雜湊排除 ls-measured 戳記 —— 那是量測版本章，不是這張板的內容。 */
    /* 第 10 輪 D9-02：規線改法（見 EXPIRED_RULE 那段）是合法的設計修正，
       不是有人偷改內容，所以雜湊照規矩重釘——舊值 6c9c082cec321ffa119dfa0ca696e2f6c744f409adc30aabd420f75cfe201275，
       新值是 CSS 加了 s[data-expired]／::after 兩條規則、helmet 的 :root
       多兩個變數、兩處 <s> 收尾補一個半形空白之後重算的。 */
    frozen: { file: 'AppIcon', sha256: '1464fe85d5b4abb799bd2f4e8d44a37d52ed1a215fd1da46743b1cd6dfa93335' },
  },
  {
    marker: 'data-cancel', role: 'stub', gate: 'G4',
    files: ['InviteRequests', 'InviteRequestsMany', 'InviteSpent', 'GlassSeam', 'Tokens'],
    why: '票根刻度上「用掉的格」蓋的那一道朱筆銷記。G4 管的是「朱＝錯誤訊號，每張板最多兩處」；銷記是紅筆的另一個本業（劃掉），不是錯誤 —— 它永遠只出現在刻度格裡，而且一次出現幾道由剩餘次數決定，不是由設計者決定。',
  },
];

/* ── 對比門檻：一個數字一個出處 ──────────────────────
   aaa   內文的硬門檻（WCAG 2.1 AAA）。以「漸層最不利點」計，不是以平均值計。
   grain 顆粒層把底乘暗之後的下限。顆粒是每畫素的雜訊，最暗的那一格是極端值，
         不拿它當 AAA 門檻（那會逼整套色階失真），但它必須留在 AA 以上很多。 */
export const CONTRAST = { aaa: 7, grain: 6 };
/* 開關把手對軌道的下限（G19b①）。第 5 輪這個 3 是**寫死在 verify.mjs 裡的一個字面值** ——
   一條連自己的門檻都沒有出處的 gate。它有外部出處：WCAG 2.1 SC 1.4.11 Non-text Contrast
   規定「識別 UI 元件所必需的視覺資訊」至少 3:1，把手停在哪一端正是那種資訊。 */
export const KNOB_CR = 3;
/* 朱在深淺兩個模式之間的色相角容差（G23⑥）。它是**同一支筆**：
   深色的朱只准為了對比變亮、為了色域變淡，不准換色相。1° 是 8 bit 網格上
   同一個角度找得到的最接近點的抖動幅度 —— 比它大就不是「同一個角度」了。 */
export const PEN_DH = 1;

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
    'InviteReady', 'InviteReadyDark', 'InviteSpent', 'InviteApprovalOff', 'InviteApprovalOffDark', 'InviteRequests', 'InviteRequestsMany'],
  '歡迎頁（H1 在卡紙裡）': ['Main', 'WelcomeDark'],
};
export const H1_EXCLUDED = ['WelcomeIPad', 'ForkIPad', 'StressType', 'StressLoginAX', 'StressCodeAX', 'StressContent', 'Tokens', 'Notes', 'AppIcon', 'GlassSeam'];

/* ── 板級排除登記簿（第 6 輪 D5-04）─────────────────────────────────
   第 5 輪 reviewer：G10 的排除清單只寫在註解裡，斷言印出來的是「35 張板全部通過」——
   看的人不知道那 35 裡少了哪幾張。更糟的是同樣的排除在四個地方各寫了一份**內嵌正則**，
   而且四份都不一樣（`Tokens|Notes|AppIcon|GlassSeam`／`Tokens|Notes|AX`／
   `Tokens|Notes|Stress`／`Tokens|Notes|Stress|AppIcon|GlassSeam`），其中兩處連註解都沒有。
   四份各自漂移的排除清單＝四個沒有人看得見的豁免。

   現在它們是**一張具名的表**：每一條 gate 排除哪幾張板、為什麼，寫在這裡；
   verify 與 measure 都從這裡讀；斷言把排除的板名**印出來**（G34 另外反驗
   「登記的板真的存在」與「沒有一條 gate 還在用內嵌正則」）。 */
export const DELIVERY_BOARDS = ['Tokens', 'Notes', 'AppIcon', 'GlassSeam'];
export const STRESS_BOARDS = ['StressType', 'StressLoginAX', 'StressCodeAX', 'StressContent'];
export const SCOPE = {
  G4: { skip: DELIVERY_BOARDS,
    why: '交付板上的朱是圖例與標註（色票、gate 代號、被否決的標示），不是畫面上給使用者看的錯誤訊號。壓力板不排除 —— 它們是真的畫面，只是字級被推到極端。' },
  G7: { skip: [...DELIVERY_BOARDS.filter((b) => b !== 'AppIcon' && b !== 'GlassSeam'), 'StressLoginAX', 'StressCodeAX'],
    why: '六位碼的兩種正典（票根 60pt／輸入格 36pt）只在一般字級成立。AX 板的字級被乘上 2.35 或 3.1，量到的會是推導值不是正典；AppIcon 與 GlassSeam 上沒有六位碼，列在這裡是為了讓「沒有樣本」與「被排除」分得開。' },
  G8: { skip: [...DELIVERY_BOARDS.filter((b) => b !== 'AppIcon' && b !== 'GlassSeam'), ...STRESS_BOARDS],
    why: '「每張流程板最多一個最外層陶土區塊」講的是畫面的視覺重量分配。交付板是規格文件（Tokens 板上光色票就有好幾塊），壓力板是同一個畫面的多個字級版本疊在一起。' },
  G10: { skip: [...DELIVERY_BOARDS, ...STRESS_BOARDS],
    why: '呼吸帶與板高兩條規則的落地範圍是「一個會被捲動、有主按鈕的畫面」。交付板是文件（Tokens 板 8760px 高本來就要捲）、壓力板是把同一個畫面的三個字級版本並排 —— 兩者都不是使用者會走到的畫面。' },
  'G23-stub': { skip: ['Tokens'],
    why: 'Tokens 板把褪色階**全部四階**並排印出來當色票（那是它的工作），所以「一張板上的號碼帶階數＝那張板上印的剩餘次數」在它身上不成立。它不是被跳過：斷言改印「這張板印了全部幾階」。' },
  'G23-scale': { skip: ['Notes'],
    why: 'Notes 板寫的是三格刻度的**規格文字**，不是刻度本身；掃它會掃到規格句裡的 data-scale 字串而不是畫出來的格子。' },
  G15: { skip: ['AppIcon'],
    why: '「落單的筆跡」（不在 lockup 裡的 data-ink="brush"）只准出現在 AppIcon 板上 —— 那張板講的就是「把一個字單獨拿去刻成印」，落款印本來就只有筆跡沒有系統字。其他任何板上出現半組字標一律 FAIL。' },
  cta: { skip: [...DELIVERY_BOARDS.filter((b) => b !== 'AppIcon' && b !== 'GlassSeam'), ...STRESS_BOARDS],
    why: 'measure 端算「流程板的陶土計數」時用的同一份範圍（G8 讀它）。兩邊共用一筆登記，不再各寫一份正則。' },
};
/* 檔名 → 這條 gate 管不管它。板名比對用的是**去掉副檔名的完整板名**，不是正則片段 ——
   `AX` 這種片段會順手掃到任何名字裡有 AX 的板，那正是第 5 輪四份清單漂移的方式。 */
export const inScope = (gate, file) => !(SCOPE[gate].skip.includes(String(file).replace(/\.dc\.html$/, '')));

/* cap-height 佔字級的比例（SF Pro / PingFang 實測近似）。
   iPad 跨欄基線與 H1 分組基線都用這個常數換算，verify 也用同一個。 */
export const CAP = 0.72;

/* AX5 ≈ 310%、AX4 ≈ 235%（body 17pt → 53／40，照 iOS 的 accessibility 字級表）。
   壓力板用，是推導值不是新階。第 5 輪多了 AX4：登入鍵的標籤在 AX4 還說得完整句
   （「Apple 登入」），AX5 才放不下 —— 那個斷點是量出來的，見 StressLoginAX 板。 */
export const AX = 3.1;
export const AX4 = 2.35;
export const ax = (px) => Math.round(px * AX);
export const ax4 = (px) => Math.round(px * AX4);

/* ── 呼吸帶兩條規則的門檻：一個數字一個出處 ──────────
   pause  ①「內容首末之間，任何一段連續空白 ≤120px」的門檻
   btnPct ②「主按鈕中心須落在畫面 70% 以內」的門檻
   板上印的、measure.mjs 分流用的、verify.mjs 判定用的，全部讀這裡。
   刻意不放進 FIX：FIX 的值同時是 G1 允許的間距白名單，門檻不是間距。 */
export const RULE = { pause: 120, btnPct: 70 };

/* ── 過期句規線（第 10 輪 D9-02）─────────────────────────
   AppIcon 板凍結豁免上那三句「同一支筆」用 <s data-expired> 劃掉，第 9 輪抓到：
   瀏覽器內建 line-through 的預設位置落在 CJK 橫畫帶，把「同一支筆」裡三個「一」
   的那一橫吃掉，讀成「同⎯支筆」——規線本身銷毀了要保存的內容。
   改成自己畫一條背景線，粗細（w）與垂直位置（y，em 框的百分比）都是這裡的具名值，
   不是瀏覽器決定的；G35 驗畫面上真的引用 var(--ls-expired-rule-w/-y) 這兩個名字，
   不是抄一份數字進去。y 落在 58–62 的安全帶：CJK 單橫畫字的那一橫多半在 45–55%
   附近，60% 已經明顯下移，不會壓在筆畫上。刻意不放進 FIX：同上一條的理由，
   FIX 的值同時是 G1 的間距白名單，規線粗細不是間距。 */
export const EXPIRED_RULE = { w: 2, y: 60 };   // w：px；y：% of em box

/* ── 產物與量測資料的綁定（G21）──────────────────────
   build.mjs 把它「當次讀到的 measured.json」的指紋寫進每一張產物，
   verify.mjs 拿現行 measured.json 的指紋比對 —— 不一致＝板上印的實測句是上一版的。
   兩邊算法必須是同一份，所以定義在這裡。 */
export const hash12 = (s) => createHash('sha256').update(s).digest('hex').slice(0, 12);

/* ── 產物上蓋的量測戳記（第 5 輪 D4-09）────────────────────────────
   戳記**排除 measured.json 的 root 欄位**。不排除的話會有一個自我餵食的迴圈：
     板上的戳記 → 板的內容 → root.contentFp → measured.json → 板上的戳記……
   第 4 輪因此跑兩次就得到兩份不同的產物，沒有人能靠重建來核對這一份稿子。
   root 自己另有兩道守衛（measure 開跑前的三方對帳、G21b／G21c），不靠戳記。
   build 蓋章與 verify 比對用的是**同一個函式**，所以不可能各算各的。 */
export const measStamp = (raw) => {
  if (!raw) return 'no-measurement';
  try { const o = JSON.parse(raw); delete o.root; return hash12(JSON.stringify(o)); } catch { return hash12(raw); }
};
