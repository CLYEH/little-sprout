// 手寫字標「萌芽」＋系統字「日記」——全稿唯一的非系統線條。
//
// 為什麼是手寫：歡迎頁的溫度不能靠「暖色底＋系統粗體」硬撐，那是每個 app 都有的東西。
// 一支有起筆、有提按、有收鋒的筆跡，是這個 app 唯一做得出來、別人抄不走的東西 ——
// 而且它可以跨板再現（信件明細的「寄件人」、建立家庭的即時預覽），把流程縫起來。
//
// 為什麼四個字不全部手寫（第 2 輪，產品中文名定為「萌芽日記」）：
//   「萌」十四筆、「記」十筆。在信件明細那一格，字標只有 26pt 高 —— 四個字全手寫的話，
//   每一筆不到 1.3pt、筆與筆的空隙不到 1pt，對長輩就是一團墨。
//   所以 lockup 拆成兩層：**手寫的是「萌芽」（名字的意思：發芽）**，
//   **系統字的是「日記」（東西的種類）**。險只冒在一個地方，其餘保持安靜；
//   而且「日記」是真的文字，會跟著 Dynamic Type 長大，手寫的那兩個字是圖不會。
//
// 做法：每一筆給一條三次貝茲中線 + 起筆寬 + 收筆寬 + 中段提按，
// 取樣後往法線兩側推出外框，輸出成填色多邊形。所以筆畫真的有粗細變化，
// 不是「圓頭 stroke 假裝手寫」。

const bez = (p, u) => {
  const v = 1 - u, a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u;
  return [a * p[0][0] + b * p[1][0] + c * p[2][0] + d * p[3][0],
    a * p[0][1] + b * p[1][1] + c * p[2][1] + d * p[3][1]];
};

const r2 = (n) => Math.round(n * 100) / 100;

// 每一筆的外框點都記在這裡，viewBox 由它算出來 —— 第 1 輪的四個 bbox 數字是手量的，
// 換了字就會過期（換名字這件事正好證明了這一點）。現在它是推出來的。
let BOX = null;
const seen = (x, y) => {
  if (!BOX) BOX = { x0: x, y0: y, x1: x, y1: y };
  BOX.x0 = Math.min(BOX.x0, x); BOX.y0 = Math.min(BOX.y0, y);
  BOX.x1 = Math.max(BOX.x1, x); BOX.y1 = Math.max(BOX.y1, y);
};

// pts: 四個控制點 [起, c1, c2, 終]；w0/w1 起訖筆寬；swell 中段提按（0 = 沒有）
// place: 這一筆在兩字並排時的位移與縮放（bbox 要算的是**排好之後**的位置）
const stroke = (pts, w0, w1, swell = 0, place = null) => {
  const N = 26, L = [], R = [];
  for (let i = 0; i <= N; i++) {
    const u = i / N;
    const [x, y] = bez(pts, u);
    const [x2, y2] = bez(pts, Math.min(1, u + 0.004));
    const [x1, y1] = bez(pts, Math.max(0, u - 0.004));
    let tx = x2 - x1, ty = y2 - y1;
    const len = Math.hypot(tx, ty) || 1;
    tx /= len; ty /= len;
    const w = (w0 + (w1 - w0) * u) * (1 + swell * Math.sin(Math.PI * u)) / 2;
    L.push([r2(x - ty * w), r2(y + tx * w)]);
    R.push([r2(x + ty * w), r2(y - tx * w)]);
    if (place) for (const p of [L[i], R[i]]) seen(...place(p));
  }
  const path = [`M${L[0][0]} ${L[0][1]}`];
  for (let i = 1; i <= N; i++) path.push(`L${L[i][0]} ${L[i][1]}`);
  for (let i = N; i >= 0; i--) path.push(`L${R[i][0]} ${R[i][1]}`);
  return `<path d="${path.join('')}Z"/>`;
};

/* ── 艹（草字頭）─────────────────────────────────────
   「萌」與「芽」共用同一個部首 —— 這是這個詞在字形上本來就有的呼應。
   但手寫的人不會把同一個部首寫成兩份一樣的：v 是同一支筆的兩次落筆，
   長橫的弧度、兩豎的出頭各差一點點。 */
const grass = (v, place) => [
  stroke([[7 - v, 24.5 - v], [32, 21.8 - v * .6], [62, 20.2 - v * .4], [92 + v, 18 - v]], 5, 8 + v * .3, .07, place),
  stroke([[31 - v, 11 + v], [30, 18], [29, 26], [27.5, 35 - v]], 6.2, 4.6, 0, place),
  stroke([[67.5 + v, 10 + v * 1.4], [69, 18], [70.5, 26], [72, 35 - v]], 4.8, 6.6, 0, place),
];

/* ── 萌（0–100 見方）───────────────────────────────────
   艹 在上（壓扁到 y 8–35），明在下：日在左、月在右。
   日的橫折拆成「上橫＋右豎」兩筆下筆 —— 手寫時本來就是一筆轉過去，
   拆成兩段才畫得出轉角處的提按。 */
const MENG = (place) => [
  ...grass(0, place).map((s) => s),
  // 日
  stroke([[13, 41], [13.6, 58], [14, 75], [14.5, 91]], 7.4, 5.8, 0, place),
  stroke([[12, 41], [23, 40], [34, 39], [45, 38]], 5.6, 7.2, .05, place),
  stroke([[45, 38.5], [44.5, 56], [44, 74], [43.4, 90]], 7.6, 6, 0, place),
  stroke([[15, 66], [24, 65.6], [34, 65.2], [44, 64.8]], 4.6, 6, .05, place),
  stroke([[14, 90], [24, 89.6], [34, 89.2], [44, 88.6]], 5, 6.6, .05, place),
  // 月
  stroke([[64, 36], [61, 55], [58, 76], [52, 97]], 7.6, 2.2, .05, place),
  stroke([[64, 35], [74, 34.3], [84, 33.8], [94, 33]], 5.4, 7, .05, place),
  stroke([[94, 34], [93.4, 52], [92.8, 70], [92, 88]], 7.4, 6, 0, place),
  stroke([[92, 88], [90.5, 94], [85, 97.5], [76, 95]], 6, 1.2, 0, place),
  stroke([[60, 57], [70, 56.6], [81, 56.2], [91, 55.8]], 4.4, 5.8, .05, place),
  stroke([[56, 78], [68, 77.6], [79, 77.2], [90, 76.8]], 4.4, 5.8, .05, place),
].join('');

/* ── 芽（0–100 見方）─────────────────────────────────
   艹（第二次落筆，弧度與出頭都差一點）＋牙：左上短撇、長橫、長撇、右豎鉤。 */
const YA = (place) => [
  ...grass(.8, place),
  stroke([[64, 37.5], [55, 42], [43, 47], [27, 52.5]], 6.6, 1.8, .06, place),
  stroke([[10, 60.5], [34, 58.4], [62, 56.8], [90, 55]], 5, 8, .06, place),
  stroke([[60, 40], [51, 59], [35, 78], [11, 96]], 8, 1.4, .07, place),
  stroke([[72.8, 32.5], [72, 52], [71.4, 70], [70.6, 86]], 8.6, 6.4, 0, place),
  stroke([[70.6, 86], [69, 92.5], [63, 96.5], [51, 94]], 6.4, 1, 0, place),
].join('');

/* 兩字並排：手寫的字不會排得像表格 —— 第二個字微微下沉、微微轉一點，
   是筆跡自然的參差。字距收到 93（原 100）：兩字之間的白比字內的白小，
   才會讀成一個詞，而不是兩個各自站著的字。
   兩組 transform 與下面兩個 place() 是同一組數 —— viewBox 因此貼著真正的墨跡。 */
const T1 = { dx: 2, dy: 2, rot: -1.1, s: .97 };
const T2 = { dx: 93, dy: -1, rot: .9, s: 1 };
const placer = (t) => ([x, y]) => {
  const a = t.rot * Math.PI / 180;
  const px = (x - 50) * t.s, py = (y - 50) * t.s;
  return [t.dx + 50 + px * Math.cos(a) - py * Math.sin(a), t.dy + 50 + px * Math.sin(a) + py * Math.cos(a)];
};
const MENG_D = MENG(placer(T1));
const YA_D = YA(placer(T2));
const PAD = 1.5;   // 抗鋸齒餘裕
export const VB = {
  x: r2(BOX.x0 - PAD), y: r2(BOX.y0 - PAD),
  w: r2(BOX.x1 - BOX.x0 + PAD * 2), h: r2(BOX.y1 - BOX.y0 + PAD * 2),
};

const gt = (t) => `translate(${t.dx} ${t.dy}) rotate(${t.rot} 50 50) scale(${t.s})`;

/* 落款印：app icon 用的單字版，只取「芽」——**同一支筆的同一份幾何**，
   不是另外畫一個圖形（換一支筆就等於換一個品牌）。
   它自己的 bbox 也是推出來的，所以圖示裡的留白是量出來的不是眼睛抓的。 */
let SEAL_BOX = null;
const sealSeen = (x, y) => {
  if (!SEAL_BOX) SEAL_BOX = { x0: x, y0: y, x1: x, y1: y };
  SEAL_BOX.x0 = Math.min(SEAL_BOX.x0, x); SEAL_BOX.y0 = Math.min(SEAL_BOX.y0, y);
  SEAL_BOX.x1 = Math.max(SEAL_BOX.x1, x); SEAL_BOX.y1 = Math.max(SEAL_BOX.y1, y);
};
const SEAL_D = YA(([x, y]) => { sealSeen(x, y); return [x, y]; });
export const SEAL_VB = {
  x: r2(SEAL_BOX.x0 - PAD), y: r2(SEAL_BOX.y0 - PAD),
  w: r2(SEAL_BOX.x1 - SEAL_BOX.x0 + PAD * 2), h: r2(SEAL_BOX.y1 - SEAL_BOX.y0 + PAD * 2),
};
export const sealMark = (size, color) =>
  `<svg width="${Math.round(size)}" height="${Math.round(size * SEAL_VB.h / SEAL_VB.w)}" viewBox="${SEAL_VB.x} ${SEAL_VB.y} ${SEAL_VB.w} ${SEAL_VB.h}" fill="${color}" role="img" aria-label="萌芽日記的落款印" style="display:block">${SEAL_D}</svg>`;

/* 字標＝手寫「萌芽」＋系統字「日記」。整組只有一個無障礙名稱（產品全名），
   裡面兩塊都是 aria-hidden —— 讀螢幕的人聽到的是「萌芽日記」一次，不是兩次。 */
export const inkMark = (spec, color, subColor = color) => {
  const h = Math.round(spec.h), w = Math.round(spec.h * VB.w / VB.h);
  return `<span role="img" aria-label="萌芽日記" style="display:inline-flex;align-items:flex-end;gap:${spec.gap}px">`
    + `<svg width="${w}" height="${h}" viewBox="${VB.x} ${VB.y} ${VB.w} ${VB.h}" fill="${color}" aria-hidden="true" style="display:block;flex:none">`
    + `<g transform="${gt(T1)}">${MENG_D}</g><g transform="${gt(T2)}">${YA_D}</g></svg>`
    + `<span aria-hidden="true" style="font-size:${spec.sub}px;line-height:${spec.sub}px;font-weight:500;letter-spacing:.16em;color:${subColor};white-space:nowrap">日記</span>`
    + '</span>';
};
