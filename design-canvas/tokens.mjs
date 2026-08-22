// Little Sprout M1 — 單一 token 來源。build.mjs 與 verify.mjs 都從這裡讀，
// 所以「宣稱的值」與「畫出來的值」不可能再漂移。

/* ── 色 ──────────────────────────────────────────────
   規則：文字只有兩級（ink / ink2）。陶土、酒紅、芽綠只當底色或線，
   永遠不當長文字色。edge 是全稿唯一的線色（分隔線、開窗邊、未走的步驟段）。 */
export const T = {
  light: {
    board: '#EFE3D0', board2: '#E3D2B8', board3: '#D9C7AB', lit: '#FBF4E8',
    ink: '#241A12', ink2: '#413327',
    cta: '#8A3016', ctaDeep: '#6B2410', ctaBusy: '#6B2410', onCta: '#FFFFFF',
    wine: '#6E1424', sprout: '#1F5230', onSprout: '#FFFFFF',
    edge: '#7D6342',
    bevelTop: 'rgba(36,26,18,.34)', bevelSoft: 'rgba(36,26,18,.22)', bevelBot: 'rgba(255,250,238,.75)',
    lift: '0 1px 0 rgba(36,26,18,.20), 0 8px 16px -10px rgba(36,26,18,.55)',
    press: '0 1px 0 rgba(255,250,238,.75)',   // 平印：光從上來，字的下緣有亮邊
    grain: '.055',
  },
  dark: {
    board: '#211913', board2: '#191310', board3: '#2E2419', lit: '#463726',
    ink: '#F4E8D7', ink2: '#CBB69F',
    cta: '#E59468', ctaDeep: '#B96C43', ctaBusy: '#F0A97F', onCta: '#211913',
    wine: '#F19EAB', sprout: '#8ACF9E', onSprout: '#211913',
    edge: '#94806B',
    bevelTop: 'rgba(0,0,0,.6)', bevelSoft: 'rgba(0,0,0,.45)', bevelBot: 'rgba(255,226,190,.18)',
    lift: '0 1px 0 rgba(0,0,0,.5), 0 8px 16px -10px rgba(0,0,0,.9)',
    press: '0 -1px 0 rgba(0,0,0,.55)',        // 深色：光從下來，亮邊翻到上緣（同一條規則的鏡像）
    grain: '.09',
  },
};

/* ── 間距：七階，沒有第八階 ──────────────────────────
   每一個 gap / padding / margin 都必須是這七階、FIX 常數、或 0。
   verify.mjs check 1 會掃產出的 HTML 逐一驗證（第 2 輪只掃 gap，放走 133 個 padding）。 */
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
  capAlign: 39,     // iPad 跨欄 cap-height 對齊補償（左欄 42/50 標題 vs 右欄卡內 28/34 標題，卡上緣內距 44）
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
export const H1_EXCLUDED = ['WelcomeIPad', 'ForkIPad', 'StressType', 'StressCodeAX', 'StressContent', 'Tokens', 'Notes'];

/* cap-height 佔字級的比例（SF Pro / PingFang 實測近似）。
   iPad 跨欄基線與 H1 分組基線都用這個常數換算，verify 也用同一個。 */
export const CAP = 0.72;

/* AX5 ≈ 310%。壓力板用，是推導值不是新階。 */
export const AX = 3.1;
export const ax = (px) => Math.round(px * AX);
