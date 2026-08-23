// Little Sprout M1 — 單一 token 來源。build.mjs 與 verify.mjs 都從這裡讀，
// 所以「宣稱的值」與「畫出來的值」不可能再漂移。
import { createHash } from 'node:crypto';

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
    /* 漸層端點，一律寫成 [上, 下]。它們自己就是 token（不是在 build 裡算出來的），
       因為 Tokens 板要逐個印出來、verify 要逐個比對。光從**上**來。 */
    grad: {
      paper: ['#F8E6DD', '#EFD8D9'],
      win: ['#E0C4C3', '#EED5D2'],
      win3: ['#D8B9B1', '#E6C9C1'],
      face: ['#E9CFC7', '#DBBDB5'],
      cta: ['#901F49', '#7C1236'],
      stub: ['#FAEADE', '#ECD0D6'],
      seam: ['rgba(42,18,25,0)', 'rgba(42,18,25,.42)'],
    },
  },
  dark: {
    board: '#25141A', board2: '#1E1015', board3: '#352029', lit: '#452A33',
    ink: '#F8E7E2', ink2: '#DCBEBC',
    cta: '#E9A8B6', ctaDeep: '#A05D70', ctaBusy: '#C89AA0', onCta: '#25141A',
    pen: '#FFAE86', sprout: '#8FD2A6', onSprout: '#25141A',
    edge: '#A0807C',
    appleBg: '#FFFFFF', appleFg: '#000000',
    googleBg: '#131314', googleFg: '#E3E3E3', googleLine: '#8E918F',
    bevelTop: 'rgba(0,0,0,.6)', bevelSoft: 'rgba(0,0,0,.45)', bevelBot: 'rgba(255,214,208,.20)',
    lift: '0 1px 0 rgba(0,0,0,.5), 0 8px 16px -10px rgba(0,0,0,.9)',
    press: '0 -1px 0 rgba(0,0,0,.55)',        // 深色：光從下來，亮邊翻到上緣（同一條規則的鏡像）
    grain: '.09',
    /* 深色是同一套語言的鏡像：光源翻到下方，所以每一種漸層的兩端也一起對調
       （台紙較亮的那一端、浮起面較亮的那一端、凹窗較暗的那一端）。
       唯一不翻的是 seam —— 它由「紙壓在照片上」的幾何決定，不由光源決定。 */
    grad: {
      paper: ['#1F1015', '#2B181F'],
      win: ['#241419', '#170B10'],
      win3: ['#3D262F', '#2C1A22'],
      face: ['#2C1A22', '#3D262F'],
      cta: ['#DE97A7', '#F0B2BF'],
      stub: ['#241318', '#33202A'],
      seam: ['rgba(0,0,0,0)', 'rgba(0,0,0,.62)'],
    },
  },
};

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
  stub: '票根的號碼帶。這是照相館的取件存根：印刷品會褪色，而且從見光的那一頭開始褪。跟台紙同一條漸層，只是振幅放大到看得見（明度差 12%）—— 它是全稿唯一「時間」的漸層，不是光的漸層，所以它可以出現在平印表面上。還沒印上號碼的空票根沒有這條漸層：沒印過的東西不會褪色。',
  seam: '台紙壓在照片上投下的影子。紙有厚度，影子從實到無 —— 全稿唯一不是「明暗」而是「有無」的漸層，也是唯一壓在照片上的（所以它上面永遠沒有字）。它是唯一深色不翻面的漸層：紙的邊緣永遠向上蓋住照片，影子就永遠往上，那是幾何不是光源。',
  perf: '騎縫線。它用 repeating-linear-gradient 的語法，但它是圖樣不是明暗漸層（橫向、1px 高、上面永遠沒有字）—— 全稿唯一的方向例外，列在這裡是為了不讓它變成沒印出來的例外。',
};

/* 刻意**沒有**漸層的表面，每一個都要有理由 —— 「規則有例外可以，例外沒印出來不行」。 */
export const NO_GRAD_WHY = {
  平印: '只能讀的東西不接光：票根外框、明細表、說明框、待核卡片、警語條全部沒有漸層。唯一的例外是票根的號碼帶（stub），那條是褪色不是光。',
  載入中: '按鈕載入中時漸層整條拿掉、換成實色，唇邊與底同色 —— 按不動的東西不反光。這是「就地轉態」在光語言裡的落地，不是另做一顆按鈕。',
  品牌鍵: 'Apple 與 Google 兩顆鍵的外觀由對方的品牌規範決定：實色底、指定的描邊與字色，不加漸層。我們只借幾何（高度、圓角、間距、命中盒），不借光。',
};

export const GRAD_KEYS = ['paper', 'win', 'win3', 'face', 'cta', 'stub', 'seam'];

/* 產出與比對用的唯一寫法。build 畫的、verify 掃的、Tokens 板印的，都是這一個函式。 */
export const gradCss = (t, name) => `linear-gradient(180deg, ${t.grad[name][0]} 0%, ${t.grad[name][1]} 100%)`;
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
  knob: 3,          // 開關把手與軌道的間隙（56×32 軌道、26 把手）
};

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
  有步驟條: ['Email', 'EmailError', 'Otp', 'OtpError', 'OtpErrorDark', 'JoinCode', 'JoinCodeDark', 'JoinExpired', 'JoinUsedUp'],
  無步驟條: ['Fork', 'CreateFamily', 'CreateFamilySending', 'Pending', 'InviteEmpty', 'InviteGenerating',
    'InviteReady', 'InviteApprovalOff', 'InviteApprovalOffDark', 'InviteRequests', 'InviteRequestsMany'],
  '歡迎頁（H1 在卡紙裡）': ['Main', 'WelcomeDark', 'WelcomeSending'],
};
export const H1_EXCLUDED = ['WelcomeIPad', 'ForkIPad', 'StressType', 'StressLoginAX', 'StressCodeAX', 'StressContent', 'Tokens', 'Notes'];

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
