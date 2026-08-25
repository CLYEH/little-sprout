// Little Sprout — M1 (LS-17 登入 / LS-18 家庭) design canvas.
// tokens.mjs 是唯一 token 來源 -> 30 .dc.html artboards。Run: node build.mjs
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import { T, SP, FIX, TY, FONT, MONO, CAP, H1_GROUPS, H1_EXCLUDED, RULE, AX, ax, hash12 } from './tokens.mjs';
import { inkMark } from './brush.mjs';

/* ── 給自驗管線的標記 ──────────────────────────────────
   verify/measure 不用猜元件是什麼，直接讀這些屬性 ——
   第 2 輪的三盞燈接錯線，就是因為檢查靠 grep 猜。 */
const S = (kind, role = '') => ` data-s="${kind}"${role ? ` data-role="${role}"` : ''}`;
const MO = (motif) => ` data-m="${motif}"`;
const CTA = ' data-cta="1"';

/* 手寫字標的五個尺寸只有這一份。Tokens 板印的也是這裡的值 ——
   規格與畫面同源，不可能再各說各話。 */
const INK = { phone: 51, pad: 140, sheet: 34, preview: 26, mail: 20 };

/* ─────────────────────────  ICONS  ─────────────────────────
   24px 格線、1.75 stroke、currentColor。全稿沒有 emoji。 */
const ic = (d, s = 24) =>
  `<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
const I = {
  back: ic('<path d="M14.5 5 8 12l6.5 7"/>'),
  mail: ic('<rect x="2.8" y="5.2" width="18.4" height="13.6" rx="2.4"/><path d="m3.6 6.6 8.4 6.4 8.4-6.4"/>'),
  key: ic('<circle cx="8" cy="12" r="3.6"/><path d="M11.6 12h9.2M17.6 12v3.4M20 12v2.4"/>'),
  link: ic('<path d="M10.2 13.8a3.8 3.8 0 0 0 5.6.3l2.6-2.6a3.8 3.8 0 0 0-5.4-5.4l-1.5 1.5"/><path d="M13.8 10.2a3.8 3.8 0 0 0-5.6-.3l-2.6 2.6a3.8 3.8 0 0 0 5.4 5.4l1.5-1.5"/>'),
  house: ic('<path d="M4 10.4 12 4l8 6.4V19a1.4 1.4 0 0 1-1.4 1.4H5.4A1.4 1.4 0 0 1 4 19Z"/><path d="M9.6 20.4v-6h4.8v6"/>'),
  clock: ic('<circle cx="12" cy="12" r="8.4"/><path d="M12 7.2V12l3.2 2"/>'),
  check: ic('<path d="m4.8 12.4 4.6 4.6 9.8-10"/>'),
  check16: ic('<path d="m4.8 12.4 4.6 4.6 9.8-10"/>', 16),
  copy: ic('<rect x="8.6" y="8.6" width="11.6" height="11.6" rx="2.2"/><path d="M15.4 5.4H5.8a2 2 0 0 0-2 2v9.6"/>'),
  send: ic('<path d="M20.6 3.4 3.6 10.2l6.6 2.8 2.8 6.6Z"/><path d="m10.2 13 4.2-4.2"/>'),
  refresh: ic('<path d="M20 12a8 8 0 1 1-2.6-5.9"/><path d="M20.4 4.4v4.4H16"/>'),
  plus: ic('<path d="M12 5v14M5 12h14"/>'),
  eye: ic('<path d="M2.4 12S6 5.8 12 5.8 21.6 12 21.6 12 18 18.2 12 18.2 2.4 12 2.4 12Z"/><circle cx="12" cy="12" r="2.8"/>'),
  people: ic('<circle cx="9" cy="8.4" r="3.4"/><path d="M2.8 20c.8-3.4 3.2-5.2 6.2-5.2s5.4 1.8 6.2 5.2"/><path d="M16 5.4a3.4 3.4 0 0 1 0 6.6M17.4 14.8c2.2.7 3.4 2.4 3.8 5.2"/>'),
  more: ic('<path d="M9 5.5 15.5 12 9 18.5"/>', 20),
};

/* ────────────────────  三種表面，一種一個意思  ────────────────────
   凹 = 可以填東西進去（輸入框、驗證碼格、照片位、頭像、號碼位、選中項、開關軌道、卡紙接縫）
   浮 = 可以按（按鈕、可點的卡片、身分選項、開關列）—— 兩層：3pt 唇邊 + 落影，沒有 inset
   平印 = 只能讀（票根、明細表、說明框）—— 沒有 bevel、沒有 inset、沒有浮起
   長輩只要學會這三條，就知道畫面上哪裡能按、哪裡要填、哪裡只是印上去的。

   凹的白名單有八個角色，每一個都印在 Tokens 板上。verify check 5 掃的是
   「使用點的 computed box-shadow」，不是 helper 定義 —— 第 2 輪就是掃錯地方。
------------------------------------------------------------------ */

const win = (t, { pad = '0', tone = 'board2', stroke = null, radius = 12, extra = '' } = {}) =>
  `background:${t[tone]};border:${FIX.hair}px solid ${stroke || t.edge};border-radius:${typeof radius === 'number' ? `${radius}px` : radius};` +
  `box-shadow:inset 0 1.5px 0 ${t.bevelTop}, inset 0 4px 6px -3px ${t.bevelSoft}, inset 0 -1.5px 0 ${t.bevelBot};padding:${pad}${extra ? `;${extra}` : ''}`;

// 浮起只有兩層：3pt 唇邊（實體的邊）+ 落影。第 2 輪的 inset topLight 是第三層，
// 它讓「有 inset = 可以填」這條規則出現無聲的例外 —— 拿掉，規則就是真的。
const raise = (t, { fill, lip, radius = 14, extra = '' } = {}) =>
  `background:${fill};border-radius:${radius}px;border-bottom:${FIX.lip}px solid ${lip};box-shadow:${t.lift}${extra ? `;${extra}` : ''}`;

const flat = (t, { pad = '0', radius = 12, tone = null, extra = '' } = {}) =>
  `${tone ? `background:${t[tone]};` : ''}border:${FIX.hair}px solid ${t.edge};border-radius:${radius}px;padding:${pad}${extra ? `;${extra}` : ''}`;

const noWt = (sty) => sty.replace(/;font-weight:\d+/, '');
const press = (t) => `text-shadow:${t.press}`;                  // 平印的字：壓進紙裡
const rule = (t) => `<div style="height:${FIX.hair}px;background:${t.edge}"></div>`;

/* ─────────────────────────  控制項  ───────────────────────── */

/* 載入中的按鈕不是另一個元件，是同一顆按鈕就地轉態 —— 所以走同一個函式：
   圖示位換成轉圈、底色換 ctaBusy、唇邊與底同色（＝這一刻按不動）。
   手刻第二份的話，兩個狀態會差幾個 px，畫面就會在轉態時抖一下。 */
const btn = (t, label, { icon = '', tone = 'primary', busy = false } = {}) => {
  const primary = tone === 'primary';
  const fill = primary ? (busy ? t.ctaBusy : t.cta) : t.board3;
  const lip = primary ? (busy ? t.ctaBusy : t.ctaDeep) : t.edge;
  const fg = primary ? t.onCta : t.ink;
  const mark = busy ? spinner(t, fg) : icon;
  return `<div${S('raise', 'button')}${primary ? CTA : ''} style="${raise(t, { fill, lip })};min-height:${FIX.button}px;display:flex;align-items:center;justify-content:center;gap:${SP.m}px;padding:0 ${SP.l}px;color:${fg}">
      ${mark ? `<span style="display:flex;flex:none">${mark}</span>` : ''}
      <span style="${TY.bs};color:${fg};text-align:center">${label}</span>
    </div>`;
};

// Apple 的鈕是固定的：黑底白字、官方字串。不吃我們的 accent，也不可改色。
const btnApple = (onDark = false) => {
  const bg = onDark ? '#FFFFFF' : '#000000', fg = onDark ? '#000000' : '#FFFFFF';
  return `<div${S('raise', 'button')} style="background:${bg};border-radius:14px;min-height:${FIX.button}px;display:flex;align-items:center;justify-content:center;gap:${SP.s}px;color:${fg};box-shadow:0 8px 16px -12px rgba(0,0,0,.8)">
      <svg width="20" height="24" viewBox="0 0 17 20" fill="${fg}" aria-hidden="true"><path d="M14.02 10.6c.02-2.2 1.8-3.26 1.88-3.31-1.02-1.5-2.62-1.7-3.18-1.72-1.35-.14-2.64.79-3.33.79-.69 0-1.75-.77-2.87-.75-1.48.02-2.84.86-3.6 2.18-1.53 2.66-.39 6.6 1.1 8.76.73 1.06 1.6 2.25 2.74 2.2 1.1-.04 1.51-.71 2.84-.71 1.32 0 1.7.71 2.86.69 1.18-.02 1.93-1.08 2.65-2.14.84-1.23 1.18-2.42 1.2-2.48-.03-.01-2.3-.88-2.29-3.51ZM11.85 4.16c.6-.74 1.01-1.76.9-2.78-.87.04-1.93.58-2.56 1.31-.56.65-1.06 1.69-.93 2.69.97.07 1.97-.49 2.59-1.22Z"/></svg>
      <span style="font-size:17px;line-height:25px;font-weight:600">透過 Apple 登入</span>
    </div>`;
};

// 連結本身就是 44pt 命中盒（不是外面包一層），而且不吃滿版寬度。
const tapLink = (t, label, { center = false, size = TY.b } = {}) =>
  `<span${S('raise', 'link')} style="align-self:${center ? 'center' : 'flex-start'};min-height:${FIX.tap}px;display:inline-flex;align-items:center;padding:0 ${SP.s}px;${size.replace(/;font-weight:\d+/, '')};font-weight:600;color:${t.ink};text-decoration:underline;text-underline-offset:3px;text-decoration-thickness:1.5px">${label}</span>`;

const navBack = (t, label = '返回') =>
  `<div${S('raise', 'link')} style="min-height:${FIX.tap}px;display:flex;align-items:center;gap:${SP.xs}px;margin-left:-${FIX.navOpt}px;color:${t.ink}">
      <span style="display:flex">${I.back}</span><span style="${TY.bs}">${label}</span>
   </div>`;

// 真的是序列，才給進度標記。沒有編號圓圈。未走的段用實色 edge（≥3:1），不用透明度。
const stepRail = (t, step, total, label) => {
  const seg = Array.from({ length: total }, (_, i) =>
    `<span style="width:30px;height:4px;border-radius:2px;background:${i < step ? t.ink : t.edge}"></span>`).join('');
  return `<div data-rail="1" style="display:flex;align-items:center;gap:${SP.s}px">
      <div style="display:flex;gap:${SP.xs}px">${seg}</div>
      <span style="${TY.cap};color:${t.ink2};letter-spacing:.03em">${label}</span>
    </div>`;
};

const spinner = (t, color) =>
  `<svg width="22" height="22" viewBox="0 0 22 22" fill="none" aria-hidden="true">
     <circle cx="11" cy="11" r="8.5" stroke="${color}" stroke-opacity=".3" stroke-width="2.5"/>
     <path d="M19.5 11A8.5 8.5 0 0 0 11 2.5" stroke="${color}" stroke-width="2.5" stroke-linecap="round"/>
   </svg>`;

/* ─────────────────────────  輸入  ─────────────────────────
   錯誤只有兩個紅：一道獨立的 2pt 線 + 一行訊息。沒有第三個紅色訊號。

   第 2 輪抓到的幾何撞車：錯誤線原本是 border-bottom:3px，跟「浮起＝可以按」
   的 3pt 唇邊同寬同位置 —— 出錯的欄位長得像可以按的按鈕。
   這一輪錯誤線脫離欄位邊界：2pt（比唇邊薄）、距離欄位 8pt（間距階內），
   由同一個元件產生，四張錯誤板不可能長得不一樣。 */

const errBar = (t) => `<div data-err="bar"${MO('errbar')} style="height:${FIX.errBar}px;border-radius:1px;background:${t.wine}"></div>`;

const field = (t, { label, value = '', placeholder = '', state = 'idle', hint = '' }) => {
  const border = state === 'focus' ? `border:2px solid ${t.ink}` : `border:${FIX.hair}px solid ${t.edge}`;
  const tone = state === 'disabled' ? t.board3 : t.board2;
  const txt = value
    ? `<span style="${TY.b};color:${t.ink};overflow-wrap:anywhere">${value}</span>`
    : `<span style="${TY.b};color:${t.ink2}">${placeholder}</span>`;
  return `<div style="display:flex;flex-direction:column;gap:${SP.m}px">
      <span style="${TY.l};color:${t.ink2}">${label}</span>
      <div style="display:flex;flex-direction:column;gap:${SP.s}px">
        <div${S('win', 'field')} style="background:${tone};${border};border-radius:12px;box-shadow:inset 0 1.5px 0 ${t.bevelTop}, inset 0 4px 6px -3px ${t.bevelSoft}, inset 0 -1.5px 0 ${t.bevelBot};min-height:${FIX.button}px;display:flex;align-items:center;padding:0 ${SP.l}px">${txt}</div>
        ${state === 'error' ? errBar(t) : ''}
      </div>
      ${hint ? `<span style="${TY.cap};color:${t.ink2}">${hint}</span>` : ''}
    </div>`;
};

const errorLine = (t, msg) => `<span style="${TY.bs};color:${t.wine}">${msg}</span>`;

// 六位數字的第一種正典：3＋3 分格，36pt 等寬。OTP 與邀請碼共用同一個元件。
// 邀請碼那一版在兩組中間印一個「、」—— 畫面上的分組跟畫面下方那句
// 「念的時候是「七四二、九三六」。」是同一個分組。虛線卡因此變成真的簽名。
const codeCells = (t, digits, { caret = -1, error = false, sep = false } = {}) => {
  const cell = (d, i) => `<div${S('win', 'cell')}${MO('cells')} style="flex:1;background:${t.board2};border:${i === caret ? 2 : FIX.hair}px solid ${i === caret ? t.ink : t.edge};border-radius:12px;box-shadow:inset 0 1.5px 0 ${t.bevelTop}, inset 0 5px 8px -4px ${t.bevelSoft}, inset 0 -1.5px 0 ${t.bevelBot};height:${FIX.cell}px;display:flex;align-items:center;justify-content:center">
      <span style="${TY.n2};color:${t.ink}">${d || ''}</span></div>`;
  const group = (from) => `<div style="display:flex;gap:${SP.s}px;flex:1">${digits.slice(from, from + 3).map((d, j) => cell(d, from + j)).join('')}</div>`;
  const middle = sep
    ? `<div style="display:flex;gap:${SP.m}px;align-items:center">${group(0)}<span style="${TY.c};color:${t.ink2};flex:none">、</span>${group(3)}</div>`
    : `<div style="display:flex;gap:${SP.xl}px">${group(0)}${group(3)}</div>`;
  return `<div style="display:flex;flex-direction:column;gap:${SP.s}px">
      ${middle}
      ${error ? errBar(t) : ''}
    </div>`;
};

/* ─────────────────────  平印：只能讀的東西  ───────────────────── */

// 明細表：一格一格印在紙上。Pending、信件預覽、號碼用途都用同一個元件。
const table = (t, rows, { head = null, radius = 14 } = {}) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius })};display:flex;flex-direction:column;gap:${SP.m}px">
    ${head ? `<span style="${TY.l};color:${t.ink2};${press(t)}">${head}</span>` : ''}
    ${rows.map((r, i) => `${(i || head) ? rule(t) : ''}
      ${Array.isArray(r)
      ? `<div style="display:flex;justify-content:space-between;align-items:baseline;gap:${SP.l}px">
             <span style="${TY.l};color:${t.ink2}">${r[0]}</span>
             <span style="${TY.bs};color:${t.ink};text-align:right;${press(t)};overflow-wrap:anywhere">${r[1]}</span>
           </div>`
      : `<span style="${TY.b};color:${t.ink};${press(t)}">${r}</span>`}`).join('')}
  </div>`;

// 出錯的時候，明細表收成一行 —— 讓「欄位 → 錯誤句 → 下一步」擠成一群，
// 中間不要卡一張三行的表。同樣是平印，只是降一級。
const tableLine = (t, text) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.m}px ${SP.l}px` })}">
    <span style="${TY.b};color:${t.ink2};${press(t)}">${text}</span>
  </div>`;

// 說明框：也是平印。以前它穿著開窗的衣服 —— 那是錯的，它不能填東西。
const noteBox = (t, icon, text, { size = TY.b } = {}) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px` })};display:flex;gap:${SP.m}px;align-items:flex-start">
    <span style="display:flex;flex:none;color:${t.ink2}">${icon}</span>
    <span style="${size};color:${t.ink2};${press(t)}">${text}</span>
  </div>`;

/* 六位數字的第二種正典：票根，60pt。下半永遠印著期限與剩餘次數 ——
   號碼不會單獨出現在任何地方。

   還沒產生、產生中、已產生，是同一張票根的三個狀態：外框、數字帶高度（codeLine
   ＝60pt 的行高）、騎縫線、下緣帶完全一樣，所以三張畫面的高度一模一樣 ——
   開關列因此可以固定在票根正下方，不會因為狀態不同而跳位（第 3 輪 R4）。
   已產生＝平印（只能讀）；還沒產生＝凹（可以填的號碼位，白名單上的 codeslot）。 */
const ticketShell = (t, { surface, motif = '', label = '邀 請 碼', main, foot }) => `
  <div${surface.mark}${motif} style="${surface.css};overflow:hidden">
    <div style="padding:${SP.xl}px;display:flex;flex-direction:column;align-items:center;gap:${SP.m}px">
      <span style="${TY.cap};color:${t.ink2};letter-spacing:.16em;${press(t)}">${label}</span>
      <div style="height:${FIX.codeLine}px;display:flex;align-items:center;justify-content:center;gap:${SP.m}px">${main}</div>
    </div>
    <div style="height:${FIX.hair}px;background:repeating-linear-gradient(90deg,${t.edge} 0 6px,transparent 6px 12px)"></div>
    <div style="padding:${SP.m}px ${SP.xl}px;display:flex;justify-content:space-between;gap:${SP.m}px;align-items:center;background:${t.board3}">${foot}</div>
  </div>`;

const ticket = (t, { code = '742 936' } = {}) => ticketShell(t, {
  surface: { mark: S('flat'), css: flat(t, { pad: '0', radius: 18 }) },
  motif: MO('ticket'),
  main: `<span style="display:flex;gap:${SP.xl}px;${TY.n1};color:${t.ink};${press(t)}">${code.split(' ').map((g) => `<span>${g}</span>`).join('')}</span>`,
  foot: `<span style="${TY.cap};color:${t.ink2};${press(t)}">有效到 8 月 30 日</span>
         <span style="${TY.cap};color:${t.ink2};${press(t)}">還可以用 3 次</span>`,
});

// 空的票根：同一張票，只是還沒印上號碼。凹＝可以填。
const ticketSlot = (t, { busy = false } = {}) => ticketShell(t, {
  surface: { mark: S('win', 'codeslot'), css: win(t, { pad: '0', radius: 18 }) },
  main: `${busy ? spinner(t, t.ink2) : `<span style="display:flex;color:${t.ink2}">${I.key}</span>`}
         <span style="${TY.bs};color:${t.ink}">${busy ? '正在產生號碼…' : '號碼會出現在這裡'}</span>`,
  foot: `<span style="${TY.cap};color:${t.ink2}">產生之後，期限和次數印在這裡</span>`,
});

// 有待核清單時，票根降一級：變成一行印上去的字。
const ticketLine = (t) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.m}px ${SP.l}px` })};display:flex;justify-content:space-between;align-items:center;gap:${SP.m}px;flex-wrap:wrap">
    <span style="${TY.bs};color:${t.ink};${press(t)}">邀請碼 742 936</span>
    <span style="${TY.cap};color:${t.ink2};${press(t)}">8/30 到期 · 還可用 3 次</span>
  </div>`;

/* ─────────────────────  浮起：可以按的東西  ───────────────────── */

// 身分選項：浮起 = 可以按。選中 = 下沉 + 打勾 + 更亮（不是更暗）。
const choice = (t, { title, sub, selected = false }) => selected
  ? `<div${S('win', 'choiceSel')} style="flex:1;background:${t.lit};border:2px solid ${t.ink};border-radius:14px;box-shadow:inset 0 2px 5px -2px ${t.bevelSoft};min-height:${FIX.tap}px;padding:${SP.m}px;display:flex;flex-direction:column;gap:${SP.xs}px">
       <div style="display:flex;align-items:center;gap:${SP.xs}px;color:${t.ink}">
         <span style="display:flex;flex:none">${I.check16}</span>
         <span style="${TY.l};color:${t.ink}">${title}</span>
       </div>
       <span style="${TY.cap};color:${t.ink}">${sub}</span>
     </div>`
  : `<div${S('raise', 'choice')} style="flex:1;${raise(t, { fill: t.board3, lip: t.edge })};min-height:${FIX.tap}px;padding:${SP.m}px;display:flex;flex-direction:column;gap:${SP.xs}px">
       <span style="${TY.l};color:${t.ink}">${title}</span>
       <span style="${TY.cap};color:${t.ink2}">${sub}</span>
     </div>`;

/* 審核開關：整列可按，所以是浮起的。
   ON 的軌道是芽綠 —— 綠＝門禁開著、目前是安全的。這是芽綠在全稿的第二個
   （也是最後一個）使用點，例外印在 Tokens 板上。
   OFF：唇邊換酒紅（不是再加一圈描邊 —— 那會變成第三個紅），軌道凹回去。 */
const toggleRow = (t, { on = true } = {}) => {
  const sw = on
    ? `<div${S('raise', 'switch')}${MO('switch')} style="flex:none;width:56px;height:32px;border-radius:999px;background:${t.sprout};box-shadow:${t.lift};display:flex;align-items:center;justify-content:flex-end;padding:${FIX.knob}px">
         <div style="width:26px;height:26px;border-radius:50%;background:${t.onSprout}"></div></div>`
    : `<div${S('win', 'switchOff')}${MO('switch')} style="flex:none;width:56px;height:32px;border-radius:999px;background:${t.board2};border:${FIX.hair}px solid ${t.edge};box-shadow:inset 0 2px 4px -1px ${t.bevelSoft};display:flex;align-items:center;justify-content:flex-start;padding:${FIX.knob}px">
         <div style="width:26px;height:26px;border-radius:50%;background:${t.board3};border:${FIX.hair}px solid ${t.edge}"></div></div>`;
  return `<div${S('raise', 'toggleRow')} style="${raise(t, { fill: t.board3, lip: on ? t.edge : t.wine })};padding:${SP.l}px;display:flex;flex-direction:column;gap:${SP.m}px">
      <div style="display:flex;gap:${SP.l}px;align-items:flex-start">
        <div style="flex-grow:1;display:flex;flex-direction:column;gap:${SP.xs}px">
          <span style="${TY.bs};color:${t.ink}">新成員要我核准才能進來</span>
          <span style="${TY.cap};color:${t.ink2}">${on ? '關掉的話，只要輸入正確的碼就直接進家庭。' : '現在是關掉的。'}</span>
        </div>
        ${sw}
      </div>
      ${on ? '' : `<div style="border-top:${FIX.hair}px solid ${t.edge};padding-top:${SP.m}px">
           <span style="${TY.bs};color:${t.wine}">任何拿到號碼的人都能直接看到照片。</span></div>`}
    </div>`;
};

/* ─────────────────────────  SHELL  ───────────────────────── */

const helmet = (t) => `<style>
    /* ── Little Sprout M1 tokens（值即實作值，ios-dev 直接抄）── */
    :root{
      --ls-board:${t.board}; --ls-board-2:${t.board2}; --ls-board-3:${t.board3}; --ls-lit:${t.lit};
      --ls-ink:${t.ink}; --ls-ink-2:${t.ink2};
      --ls-cta:${t.cta}; --ls-cta-deep:${t.ctaDeep}; --ls-on-cta:${t.onCta};
      --ls-wine:${t.wine}; --ls-sprout:${t.sprout}; --ls-edge:${t.edge};
      --ls-r-window:12px; --ls-r-control:14px; --ls-r-card:18px;
      --ls-sp-1:4px; --ls-sp-2:8px; --ls-sp-3:12px; --ls-sp-4:16px;
      --ls-sp-5:24px; --ls-sp-6:32px; --ls-tap-min:44px;
    }
    *,*::before,*::after{box-sizing:border-box}
    body{margin:0;font-family:${FONT};-webkit-font-smoothing:antialiased;background:${t.board};color:${t.ink};text-wrap:pretty}
    a{color:${t.ink};text-decoration:underline} a:hover{color:${t.cta}}
    /* 紙的紋理：卡紙不是純色。全稿唯一用到透明度的地方。 */
    .g::after{content:"";position:absolute;inset:0;pointer-events:none;opacity:${t.grain};
      background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='140'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix type='saturate' values='0'/></filter><rect width='140' height='140' filter='url(%23n)'/></svg>");
      mix-blend-mode:multiply}
  </style>`;

/* 每一張產物都蓋上「這一次 build 讀到的 measured.json 指紋」。不渲染、不影響版面，
   但 verify 的 G21 靠它判定「板上印的實測句」與現行量測是不是同一版（第 4 輪 R10）。 */
const doc = (t, body) => `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <!-- ls-measured:${MEAS_HASH} -->
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>${helmet(t)}</helmet>
${body}
</x-dc>
</body>
</html>
`;

// iPhone 390x844。狀態列與 Home indicator 的位置刻意留白 —— 系統會畫在那裡。
const phone = (t, inner, { h = 844 } = {}) =>
  `<div class="g" data-col="phone" style="position:relative;width:390px;height:${h}px;background:${t.board};overflow:hidden;display:flex;flex-direction:column">${inner}</div>`;

const head = (t, backLabel) => `<div style="padding:${FIX.safeTop}px ${FIX.gutter}px 0">${navBack(t, backLabel)}</div>`;
const col = (inner, { gap = SP.xl, top = SP.l } = {}) =>
  `<div style="display:flex;flex-direction:column;gap:${gap}px;padding:${top}px ${FIX.gutter}px ${FIX.safeBottom}px;flex-grow:1">${inner}</div>`;
const titleBlock = (t, title, sub) => `
  <div style="display:flex;flex-direction:column;gap:${SP.s}px">
    <h1 style="${TY.h};color:${t.ink};margin:0">${title}</h1>
    <p style="${TY.b};color:${t.ink2};margin:0">${sub}</p>
  </div>`;

/* 板高：內容連同 34pt 安全區放得下 = 844（真實螢幕）；放不下才長高（= 這張會捲動）。
   verify 的 G10 逐張量：放得下卻長高，跟放不下卻不長高，都是 FAIL ——
   第 3 輪修掉四張「內容縮短了、板卻還留著 880」的舊高度。 */
const HH = {
  'InviteEmpty.dc.html': 880, 'InviteGenerating.dc.html': 880,
  'InviteRequestsMany.dc.html': 1280, 'StressType.dc.html': 1700,
  'StressCodeAX.dc.html': 2060,
  'Tokens.dc.html': 3560, 'Notes.dc.html': 2080, 'StressContent.dc.html': 960,
};
const h = (f) => HH[f] || 844;

/* ─────────────────────  照片：焦點寫一次，各斷點自己算  ─────────────────────
   焦點是「影像座標的比例」，不是 object-position。object-position 由焦點＋框的比例算出來 ——
   因為 cover 之後每個斷點只有一個軸真的會被裁，另一個軸寫什麼都沒有作用：
     手機 390×420：影像放大到 390×468.5，只裁掉縱向 48.5px（X 無作用）
     iPad 657×834：影像放大到 694.3×834，只裁掉橫向 37.3px（Y 無作用）
   兩個斷點的實際值都印在 Notes 板上，ios-dev 照抄即可。 */
const PHOTO = { w: 800, h: 961, fx: .70, fy: .53 };

const focus = (bw, bh) => {
  const s = Math.max(bw / PHOTO.w, bh / PHOTO.h);
  const sw = PHOTO.w * s, sh = PHOTO.h * s;
  const pct = (f, span, box, crop) => (crop < 1 ? null : Math.max(0, Math.min(1, (f * span - box / 2) / crop)));
  const cropX = sw - bw, cropY = sh - bh;
  return { cropX, cropY, x: pct(PHOTO.fx, sw, bw, cropX), y: pct(PHOTO.fy, sh, bh, cropY) };
};
const objPos = (bw, bh) => {
  const f = focus(bw, bh);
  return `${Math.round((f.x === null ? .5 : f.x) * 100)}% ${Math.round((f.y === null ? .5 : f.y) * 100)}%`;
};
// alt 寫「看得到什麼」。攝影 brief 不藏在 alt 裡（那是給採購看的，不是給讀螢幕的人聽的）。
const PHOTO_ALT = '暖光斜照的室內一角，木頭色的背景前有一塊淺色織品，右邊放著一個小小的木圈';

/* ─────────────────────  WELCOME  ───────────────────── */

// 全稿唯一的非系統線條。溫度來源就是它 —— 不是暖色底，不是粗體字。
// 它在三個地方再現：歡迎頁（大）、信件明細的「寄件人」、建立家庭的即時預覽。
const consent = (t) => `
  <div style="display:flex;flex-wrap:wrap;align-items:center;gap:${SP.xs}px">
    <span style="${TY.cap};color:${t.ink2}">登入即表示你同意</span>
    ${tapLink(t, '使用條款', { size: TY.cap })}
    <span style="${TY.cap};color:${t.ink2}">與</span>
    ${tapLink(t, '隱私權政策', { size: TY.cap })}
  </div>`;

const welcome = (t, { busy = false } = {}) => {
  const photoH = 420, overlap = FIX.seamPhone;
  return doc(t, `<div class="g" data-col="phone" style="position:relative;width:390px;height:844px;background:${t.board};overflow:hidden">
  <div${S('win', 'photo')} style="position:absolute;top:0;left:0;width:390px;height:${photoH}px;overflow:hidden;box-shadow:inset 0 -2px 4px -2px ${t.bevelSoft}">
    <img src="family.jpg" alt="${PHOTO_ALT}" style="width:100%;height:100%;object-fit:cover;object-position:${objPos(390, photoH)};display:block">
  </div>
  <div class="g"${S('win', 'seam')} style="position:absolute;left:0;top:${photoH - overlap}px;width:390px;height:${844 - photoH + overlap}px;background:${t.board};border-radius:20px 20px 0 0;border-top:${FIX.hair}px solid ${t.edge};box-shadow:inset 0 2px 0 ${t.bevelBot}, 0 -16px 30px -18px rgba(20,12,6,.85)">
    <div style="display:flex;flex-direction:column;height:100%;padding:${FIX.gutter}px ${FIX.gutter}px ${FIX.safeBottom}px;gap:${SP.xxl}px">
      <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px">
        ${inkMark(INK.phone, t.ink)}
        <div style="display:flex;flex-direction:column;gap:${SP.m}px">
          <h1 style="${TY.d};color:${t.ink};margin:0">孩子的每一天<br>只留給家人看</h1>
          <p style="${TY.b};color:${t.ink2};margin:0">照片、影片和日記，只有你邀請的人看得到。</p>
        </div>
      </div>
      <div style="display:flex;flex-direction:column;gap:${SP.m}px">
        ${busy
      ? btn(t, '正在傳送驗證信…', { busy: true })
      : btn(t, '用 Email 登入', { icon: I.mail })}
        ${btnApple(t.board === '#211913')}
        ${consent(t)}
      </div>
    </div>
  </div>
</div>`);
};

/* iPad 1194x834 —— 照片吃左邊 55%。內容欄不再垂直置中，改三段式：
   字標貼上緣（信箋抬頭）、標題組、按鈕＋法律行貼欄底。呼吸帶均分。 */
const welcomeIPad = (t) => doc(t, `
<div class="g" style="position:relative;width:1194px;height:834px;background:${t.board};overflow:hidden;display:flex">
  <div${S('win', 'photo')} data-col="photo" style="position:relative;width:657px;height:834px;overflow:hidden;flex:none">
    <img src="family.jpg" alt="${PHOTO_ALT}" style="width:100%;height:100%;object-fit:cover;object-position:${objPos(657, 834)};display:block">
  </div>
  <div class="g"${S('win', 'seam')} data-col="content" style="position:relative;width:537px;height:834px;background:${t.board};margin-left:-${FIX.seam}px;border-radius:24px 0 0 24px;border-left:${FIX.hair}px solid ${t.edge};box-shadow:inset 2px 0 0 ${t.bevelBot}, -18px 0 30px -24px rgba(20,12,6,.75)">
    <div style="display:flex;flex-direction:column;justify-content:space-between;height:100%;padding:${FIX.padPad}px">
      ${inkMark(INK.pad, t.ink)}
      <div data-pause="iPad 三段式：字標貼上緣當信箋抬頭、標題組落在視線高度，中間這段空白是刻意的間隔" style="display:flex;flex-direction:column;gap:${SP.xl}px;max-width:425px">
        <h1 style="${TY.dHero};color:${t.ink};margin:0">孩子的每一天<br>只留給家人看</h1>
        <p style="${TY.bPad};color:${t.ink2};margin:0">照片、影片和日記，只有你邀請的人看得到。</p>
      </div>
      <div data-pause="iPad 三段式：動作區貼欄底（拇指在下緣），與標題組之間的空白是刻意的間隔" style="display:flex;flex-direction:column;gap:${SP.m}px;max-width:${FIX.btnMax}px">
        ${btn(t, '用 Email 登入', { icon: I.mail })}
        ${btnApple(t.board === '#211913')}
        ${consent(t)}
      </div>
    </div>
  </div>
</div>`);

/* ─────────────────────  EMAIL / OTP  ───────────────────── */

// 下半部不是留白，是「你會收到什麼」——長輩最常卡在「信在哪裡」。
// 寄件人那一格印的是手寫字標本人：畫面上看到的筆跡，信裡也會看到同一支。
const mailPreview = (t) => table(t, [
  ['寄件人', `<span style="display:inline-flex;vertical-align:-4px">${inkMark(INK.mail, t.ink)}</span>`],
  ['主旨', '你的登入數字'],
  ['數字在哪', '信打開的第一行，字很大'],
], { head: '你會收到一封這樣的信' });

const emailScreen = (t, { error = false } = {}) => doc(t, phone(t, `
${head(t)}
${col(`
  ${stepRail(t, 1, 2, '步驟 1，共 2 步')}
  ${titleBlock(t, '輸入你的 Email', '我們會寄一組 6 位數字給你，不用記密碼。')}
  ${error
    ? field(t, { label: 'Email', value: 'ama.gmail.com', state: 'error' })
    : field(t, { label: 'Email', placeholder: '你的信箱', state: 'idle', hint: '例如 ama@gmail.com' })}
  ${error ? errorLine(t, '這個 Email 少了 @，請再看一次。') : ''}
  ${error
    ? tableLine(t, '信會由「小芽」寄出，主旨是「你的登入數字」。')
    : mailPreview(t)}
  ${btn(t, '傳送驗證碼', { icon: I.send })}
  <span style="${TY.cap};color:${t.ink2}">信通常一分鐘內會到。沒看到的話，找找「垃圾郵件」那一夾，或是回到這裡再按一次。</span>
`)}`));

const otpScreen = (t, { error = false } = {}) => doc(t, phone(t, `
${head(t)}
${col(`
  ${stepRail(t, 2, 2, '步驟 2，共 2 步')}
  ${titleBlock(t, '輸入信裡的 6 位數字', '已經寄到 ama@gmail.com')}
  ${error
    ? codeCells(t, ['', '', '', '', '', ''], { caret: 0, error: true })
    : codeCells(t, ['4', '9', '2', '', '', ''], { caret: 3 })}
  ${error
    ? errorLine(t, '數字不對，已經清空了，請再輸入一次。')
    : `<span style="${TY.b};color:${t.ink2}">還沒收到？01:23 後可以重新傳送。</span>`}
  ${error
    ? tableLine(t, '找不到信？看看「垃圾郵件」或「促銷內容」那一夾。')
    : table(t, [
      '看看「垃圾郵件」或「促銷內容」那一夾。',
      '寄件人是「小芽」，主旨「你的登入數字」。',
    ], { head: '找不到信？' })}
  ${btn(t, '確認')}
  <div style="display:flex;flex-direction:column;gap:${SP.s}px">
    ${error ? tapLink(t, '重新傳送驗證碼', { center: true }) : ''}
    ${tapLink(t, '改用別的 Email', { center: true })}
  </div>
`)}`, { h: error ? h('OtpError.dc.html') : 844 }));

/* ─────────────────────  三岔路 FORK  ───────────────────── */

// 三個選項共用同一副骨架：[44 圓形圖示] + [標題 / 說明]。
// 主要那條路只在「大小、色、圓角」上放大 —— 不是換一種卡片。
const forkOption = (t, { icon, title, sub, primary = false, pad = false }) => `
  <div${S('raise', 'choice')}${primary ? CTA : ''}${pad ? ' data-pause="iPad 選項卡：卡內距 44（卡面本身就是點擊面）＋卡間距 32，所以字到字之間必然超過 120px —— 那是卡片的厚度，不是版面的空洞"' : ''} style="${raise(t, { fill: primary ? t.cta : t.board3, lip: primary ? t.ctaDeep : t.edge, radius: primary ? 18 : 14 })};padding:${pad ? `${FIX.tap}px ${SP.xxl}px` : (primary ? `${FIX.gutter}px ${SP.l}px` : `${SP.l}px`)};display:flex;gap:${SP.l}px;align-items:flex-start">
    <span style="flex:none;width:44px;height:44px;border-radius:50%;background:${primary ? t.ctaDeep : t.board2};display:flex;align-items:center;justify-content:center;color:${primary ? t.onCta : t.ink2}">${icon}</span>
    <div style="display:flex;flex-direction:column;gap:${SP.s}px;min-width:0">
      <span ${primary && pad ? 'data-cap="R"' : ''} style="${primary ? (pad ? TY.h : TY.c) : (pad ? TY.bPadS : TY.bs)};color:${primary ? t.onCta : t.ink}">${title}</span>
      <span style="${pad ? TY.bPad : TY.b};color:${primary ? t.onCta : t.ink2}">${sub}</span>
    </div>
  </div>`;

const FORK_NOTE = '選錯了也沒關係。之後還可以加入別的家庭，一個帳號可以同時待在好幾個家裡；你在每個家裡的身分也可以不一樣。';

const forkOptions = (t, pad = false) => `
  ${forkOption(t, { pad, primary: true, icon: I.key, title: '我有邀請碼', sub: '家人給你一組 6 位數字。輸入之後，等他按下核准，你就進到家裡了。' })}
  ${forkOption(t, { pad, icon: I.link, title: '家人傳了連結給我', sub: '連結點不開的話，把它整段貼進來也可以，我們會認出裡面的號碼。' })}
  ${forkOption(t, { pad, icon: I.house, title: '建立我們家的空間', sub: '沒有人邀請你？自己開一個，再把號碼發給想看照片的家人。' })}`;

const accountRow = (t) => `
  <div style="display:flex;align-items:center;justify-content:space-between;gap:${SP.m}px;min-height:${FIX.tap}px">
    <span style="${TY.cap};color:${t.ink2};min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">已用 ama@gmail.com 登入</span>
    ${tapLink(t, '換帳號', { size: TY.cap })}
  </div>`;

const fork = (t) => doc(t, phone(t, `
<div style="padding:${FIX.safeTop}px ${FIX.gutter}px 0">${accountRow(t)}</div>
${col(`
  ${titleBlock(t, '接下來，選一個開始', '加入家人已經開好的空間，或是自己開一個。')}
  <div style="display:flex;flex-direction:column;gap:${SP.m}px">${forkOptions(t)}</div>
  ${noteBox(t, I.people, FORK_NOTE)}
`, { top: SP.l })}`));

/* iPad：沒有照片（照片在登入頁已經出場過一次）。雙欄 —— 左說明、右選項。
   說明欄跟手機版一樣，帳號列貼上緣，其餘一段一段往下排（24 / 8 / 32），
   排完就停 —— 沒有 space-between，剩下的空白落在欄底（第 3 輪 R3：
   space-between 把 171px 攤在說明中間，那不是呼吸，是被撐開的）。
   兩欄的第一行字仍然視覺同高：左欄 H1（42/50，上面有帳號列 44＋間距 24）的 cap-height
   對齊右欄首卡標題（28/34，卡上緣內距 44）的 cap-height —— 右欄整體下推 FIX.capAlign(29)。
   算式：44(版心) + 29 + 44(卡內距) + cap(28/34) = 44 + 44 + 24 + cap(42/50)。 */
const forkIPad = (t) => doc(t, `
<div class="g" style="position:relative;width:1194px;height:834px;background:${t.board};overflow:hidden">
  <div style="display:grid;grid-template-columns:460px minmax(0, 1fr);gap:${FIX.tap}px;padding:${FIX.tap}px ${FIX.padPadX}px;align-content:start">
    <div data-col="desc" style="display:flex;flex-direction:column;gap:${SP.xxl}px">
      <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px">
        ${accountRow(t)}
        <div style="display:flex;flex-direction:column;gap:${SP.s}px">
          <h1 data-cap="L" style="${TY.dPad};color:${t.ink};margin:0">接下來，<br>選一個開始</h1>
          <p style="${TY.bPad};color:${t.ink2};margin:0">加入家人已經開好的空間，或是自己開一個。</p>
        </div>
      </div>
      ${noteBox(t, I.people, FORK_NOTE, { size: TY.bPad })}
    </div>
    <div data-col="options" style="display:flex;flex-direction:column;gap:${SP.xxl}px;max-width:600px;padding-top:${FIX.capAlign}px">${forkOptions(t, true)}</div>
  </div>
</div>`);

/* ─────────────────────  建立家庭  ───────────────────── */

// 死帶換成即時預覽：打進去的名字，家人會在哪裡看到 —— 連同那支手寫字標。
const namePreview = (t, name) => `
  <div${S('flat')} style="${flat(t, { pad: '0', radius: 14 })};overflow:hidden">
    <div style="padding:${SP.m}px ${SP.l}px;background:${t.board3}">
      <span style="${TY.cap};color:${t.ink2};${press(t)}">家人打開 app 會看到</span>
    </div>
    <div style="height:${FIX.hair}px;background:${t.edge}"></div>
    <div style="padding:${FIX.gutter}px ${SP.l}px;display:flex;align-items:center;gap:${SP.m}px;color:${t.ink}">
      ${inkMark(INK.preview, t.ink)}
      <span style="${TY.cap};color:${t.ink2}">／</span>
      <span style="${TY.h};color:${t.ink};${press(t)};overflow-wrap:anywhere">${name}</span>
    </div>
  </div>`;

const createFamily = (t, { busy = false } = {}) => doc(t, phone(t, `
${head(t)}
${col(`
  ${titleBlock(t, '幫你們家取個名字', '之後隨時可以改。')}
  ${field(t, { label: '家庭名稱', value: '陳家', state: busy ? 'disabled' : 'focus', hint: '例如：陳家、外婆家、我們家' })}
  ${namePreview(t, '陳家')}
  ${noteBox(t, I.eye, '這是私密空間。沒有搜尋、沒有陌生人，只有拿到你邀請碼的人進得來。')}
  ${busy ? btn(t, '建立中…', { busy: true }) : btn(t, '建立家庭')}
  <span style="${TY.cap};color:${t.ink2}">建立之後你就是這個家的家長：可以邀請家人進來，也可以決定誰能上傳照片、誰只能看。</span>
`)}`));

/* ─────────────────────  輸入邀請碼 / 兩段式審核  ───────────────────── */

const joinCode = (t, { state = 'idle' } = {}) => {
  const err = state === 'expired'
    ? { msg: '這組邀請碼已經過期了。', body: '每組碼都有期限。請家人在 app 裡再產生一組新的給你。' }
    : state === 'usedup'
      ? { msg: '這組邀請碼的次數用完了。', body: '每組碼能用的次數有限，這是為了避免碼被轉傳出去。請家人再產生一組。' }
      : null;
  return doc(t, phone(t, `
${head(t)}
${col(`
  ${stepRail(t, 1, 2, '步驟 1，共 2 步')}
  ${titleBlock(t, '輸入邀請碼', '家人給你的 6 位數字，分成前三碼和後三碼。')}
  ${codeCells(t, ['7', '4', '2', '9', '3', '6'], { caret: err ? -1 : 5, error: !!err, sep: true })}
  ${err
    ? `<div style="display:flex;flex-direction:column;gap:${SP.s}px">
         ${errorLine(t, err.msg)}
         <span style="${TY.b};color:${t.ink2}">${err.body}</span>
       </div>`
    : `<span style="${TY.cap};color:${t.ink2}">念的時候是「七四二、九三六」。</span>`}
  ${err
    // 碼不能用的時候，「接下來會發生什麼」那張表整張收掉（不是收成一行）——
    // 錯誤句下面已經寫了該做的事，畫面最下面也還有一句；再擺一張框，
    // 只會把「錯誤句 → 下一步」這一群拆開。
    ? ''
    : table(t, [
      ['送出後', '家長會收到通知'],
      ['他按核准', '你才進得到家庭裡'],
      ['為什麼', '擋下拿到碼的陌生人'],
    ], { head: '接下來會發生什麼' })}
  ${btn(t, '送出申請')}
  <span style="${TY.cap};color:${t.ink2}">送出之後這個畫面會變成「等家長核准」。可以先關掉 app，核准了會通知你。</span>
`)}`, { h: h(state === 'expired' ? 'JoinExpired.dc.html' : state === 'usedup' ? 'JoinUsedUp.dc.html' : 'JoinCode.dc.html') }));
};

// 等待畫面的主體就是「還沒被填上的那扇窗」—— 母題直接拿來說明狀態。
const emptyWindow = (t) => `
  <div${S('win', 'photo')} style="${win(t, { pad: '0', radius: 14 })};height:140px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:${SP.m}px">
    <span style="display:flex;color:${t.ink2}">${I.clock}</span>
    <span style="${TY.b};color:${t.ink2}">核准之後，照片會出現在這裡</span>
  </div>`;

// 這張沒有返回鍵，但「申請已送出」佔的是返回鍵那一格 ——
// 所以它的 H1 跟其他無步驟條的畫面同一條起跑線（119）。
const pending = (t) => doc(t, phone(t, `
<div style="padding:${FIX.safeTop}px ${FIX.gutter}px 0">
  <div style="min-height:${FIX.tap}px;display:flex;align-items:center;gap:${SP.s}px;color:${t.sprout}">
    <span style="display:flex">${I.check}</span>
    <span style="${TY.bs};color:${t.sprout}">申請已送出</span>
  </div>
</div>
${col(`
  ${titleBlock(t, '等家長按下核准', '陳家的家長會收到通知。')}
  ${emptyWindow(t)}
  ${table(t, [
    ['要加入的家庭', '陳家'],
    ['送出時間', '今天 14:32'],
    ['你的身分', '家人（可以上傳照片）'],
  ])}
  <span style="${TY.cap};color:${t.ink2}">核准之前看不到家庭裡的任何東西——這是保護孩子照片的做法，不是出錯了。</span>
  ${btn(t, '看看核准了沒', { icon: I.refresh, tone: 'secondary' })}
  ${tapLink(t, '改用別組邀請碼', { center: true })}
`)}`));

/* ─────────────────────  邀請家人（Owner）  ───────────────────── */

const inviteHead = (t, title, sub) => `
  ${head(t, '陳家')}
  <div style="display:flex;flex-direction:column;gap:${SP.s}px;padding:${SP.l}px ${FIX.gutter}px 0">
    <h1 style="${TY.h};color:${t.ink};margin:0">${title}</h1>
    <p style="${TY.b};color:${t.ink2};margin:0">${sub}</p>
  </div>`;

const codeUse = (t) => table(t, [
  '產生一組 6 位數字。',
  '念給家人聽，或用訊息傳給他們。',
  '他們輸入之後，你按下核准才算進來。',
], { head: '號碼是這樣用的' });

// Email 的斷行機會給在 @ 與每一個「.」後面：不切在字中間，也不會掉一個孤兒字元下去。
const mail = (addr) => addr.replace(/([@.])/g, '$1<wbr>').replace(/<wbr>$/, '');

const requestCard = (t, { name = '王怡君', initial = '怡', email = 'yijun@gmail.com', when = '3 分鐘前用 742 936 送出' } = {}) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 18 })};display:flex;flex-direction:column;gap:${SP.l}px">
    <div style="display:flex;gap:${SP.m}px;align-items:center">
      <div${S('win', 'avatar')} style="flex:none;width:${FIX.avatar}px;height:${FIX.avatar}px;${win(t, { tone: 'board3', radius: '50%' })};display:flex;align-items:center;justify-content:center">
        <span style="${TY.c};color:${t.ink2}">${initial}</span>
      </div>
      <div style="display:flex;flex-direction:column;gap:${SP.xs}px;min-width:0">
        <span style="${TY.bs};color:${t.ink};${press(t)};overflow-wrap:break-word">${name}</span>
        <span style="${TY.cap};color:${t.ink2};overflow-wrap:break-word">${mail(email)}</span>
        <span style="${TY.cap};color:${t.ink2}">${when}</span>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.ink2}">讓他用什麼身分加入</span>
      <div style="display:flex;gap:${SP.s}px;align-items:stretch">
        ${choice(t, { title: '家人', sub: '看、留言、也能上傳', selected: true })}
        ${choice(t, { title: '親友', sub: '只能看和留言' })}
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:${SP.xxl}px">
      ${btn(t, '核准加入')}
      ${tapLink(t, '拒絕這個申請', { center: true })}
    </div>
  </div>`;

// 排隊的人收成一列：頭像、名字、Email、等多久、「查看」。
// 一次只攤開一張 —— 陶土色因此每畫面仍然只有一個，而且攤開的永遠是等最久的那位。
const requestRow = (t, { name, initial, email, waited }) => `
  <div${S('raise', 'row')} style="${raise(t, { fill: t.board3, lip: t.edge })};min-height:${FIX.tap}px;padding:${SP.m}px ${SP.l}px;display:flex;gap:${SP.m}px;align-items:center">
    <div${S('win', 'avatar')} style="flex:none;width:${FIX.tap}px;height:${FIX.tap}px;${win(t, { tone: 'board2', radius: '50%' })};display:flex;align-items:center;justify-content:center">
      <span style="${TY.l};color:${t.ink2}">${initial}</span>
    </div>
    <div style="display:flex;flex-direction:column;gap:${SP.xs}px;min-width:0;flex-grow:1">
      <span style="${TY.bs};color:${t.ink};overflow-wrap:break-word">${name}</span>
      <span style="${TY.cap};color:${t.ink2};overflow-wrap:break-word">${mail(email)}</span>
      <span style="${TY.cap};color:${t.ink2}">等了 ${waited}</span>
    </div>
    <span style="flex:none;display:flex;align-items:center;gap:${SP.xs}px;color:${t.ink};${TY.l}">查看${I.more}</span>
  </div>`;

/* 這張畫面的骨架在四個狀態裡是同一副：[票根] → [開關列] → [說明／叮嚀] → [動作]。
   開關列永遠在票根正下方 —— 它管的就是「誰能進來」，位置不隨狀態跑（第 3 輪 R4：
   關閉態不靠移位示警，靠酒紅唇邊＋警語列＋撤掉陶土並把主動作降級成「還是要傳給家人」）。 */
const inviteScreen = (t, { state = 'empty' } = {}) => {
  const on = state !== 'approvalOff';
  const codeArea = state === 'empty' ? ticketSlot(t)
    : state === 'busy' ? ticketSlot(t, { busy: true })
      : ticket(t);
  const tail = {
    empty: `
      ${codeUse(t)}
      ${btn(t, '產生邀請碼', { icon: I.plus })}`,
    busy: `
      ${codeUse(t)}
      ${btn(t, '產生中…', { busy: true })}`,
    ready: `
      <span style="${TY.cap};color:${t.ink2}">號碼給誰，就等於邀請誰。請只給你認得的家人。</span>
      ${btn(t, '傳給家人', { icon: I.send })}
      ${btn(t, '複製號碼', { icon: I.copy, tone: 'secondary' })}
      ${tapLink(t, '換一組新的號碼', { center: true })}`,
    // 沒有陶土色主按鈕：這個狀態沒有值得推薦的動作。開關列裡的警語已經把話說完，
    // 不再重複一次「號碼給誰就等於邀請誰」。
    approvalOff: `
      ${btn(t, '還是要傳給家人', { icon: I.send, tone: 'secondary' })}
      ${btn(t, '複製號碼', { icon: I.copy, tone: 'secondary' })}
      ${tapLink(t, '換一組新的號碼', { center: true })}`,
  }[state];
  const body = `${codeArea}\n${toggleRow(t, { on })}\n${tail}`;

  const titles = {
    empty: ['邀請家人', '產生一組號碼，念給家人聽或傳給他們。'],
    busy: ['邀請家人', '產生一組號碼，念給家人聽或傳給他們。'],
    ready: ['邀請家人', '號碼有期限，也有可用次數。'],
    approvalOff: ['邀請家人', '號碼有期限，也有可用次數。'],
  }[state];
  // 還沒產生的兩態多一張「號碼是這樣用的」明細表，內容放不下 844 —— 板長高＝這張會捲動。
  const board = { empty: 'InviteEmpty', busy: 'InviteGenerating', ready: 'InviteReady', approvalOff: 'InviteApprovalOff' }[state];

  return doc(t, phone(t, `${inviteHead(t, titles[0], titles[1])}
${col(body, { top: SP.xl })}`, { h: h(`${board}.dc.html`) }));
};

// 有人在等的時候，畫面的主詞是人，不是號碼：標題換成「有 N 個人想加入」，票根降成一行。
// 排序是等最久的在最上面 —— 攤開的那一張就是該先處理的那一張。
const inviteRequests = (t, { many = false } = {}) => {
  const queue = [
    { name: '林大衛', initial: '大', email: 'david.lin@example.com', waited: '一天', when: '昨天 21:40 用 508 213 送出' },
    { name: '王怡君', initial: '怡', email: 'yijun@gmail.com', waited: '9 小時', when: '今天 09:14 用 508 213 送出' },
    { name: 'Margaret Chen-Williamson', initial: 'M', email: 'margaret.chen.williamson@example.com', waited: '1 小時' },
    { name: '陳美惠（台中外婆家的阿嬤）', initial: '惠', email: 'meihui.chen.1952@example-mail.com.tw', waited: '2 分鐘' },
  ];
  const n = many ? queue.length : 1;
  const first = many ? queue[0] : {};
  return doc(t, phone(t, `${inviteHead(t, `有 ${n} 個人想加入`, many ? '等最久的排在最上面。看清楚是不是你認識的人，再按核准。' : '看清楚是不是你認識的人，再按核准。')}
${col(`
  ${requestCard(t, first)}
  ${many ? `<div style="display:flex;flex-direction:column;gap:${SP.m}px">
    <span style="${TY.l};color:${t.ink2}">後面還有 ${n - 1} 位在等</span>
    ${queue.slice(1).map((p) => requestRow(t, p)).join('')}
  </div>` : ''}
  ${rule(t)}
  ${ticketLine(t)}
  ${tapLink(t, '換一組新的號碼', { center: true })}
`, { top: SP.xl })}`, { h: many ? h('InviteRequestsMany.dc.html') : 844 }));
};

/* ─────────────────────  壓力測試  ───────────────────── */

// AX5 ≈ 310%：17pt→53pt。圖示在 AX3 以上一律拿掉 —— 放大的圖示會把按鈕撐爆。
const stressType = (t) => doc(t, `
<div class="g" data-col="phone" style="position:relative;width:390px;height:${h('StressType.dc.html')}px;background:${t.board};overflow:hidden;display:flex;flex-direction:column">
  <div style="padding:${FIX.safeTop}px ${FIX.gutter}px 0">
    <div style="min-height:${ax(17)}px;display:flex;align-items:center;gap:${SP.s}px;color:${t.ink}">
      <svg width="${ax(12)}" height="${ax(12)}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14.5 5 8 12l6.5 7"/></svg>
      <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600">返回</span>
    </div>
  </div>
  <div style="display:flex;flex-direction:column;gap:${SP.xxl}px;padding:${FIX.gutter}px ${FIX.gutter}px ${FIX.safeBottom}px;flex-grow:1">
    <div style="display:flex;flex-direction:column;gap:${SP.m}px">
      <div style="display:flex;gap:${SP.xs}px">
        <span style="width:44px;height:5px;border-radius:3px;background:${t.ink}"></span>
        <span style="width:44px;height:5px;border-radius:3px;background:${t.edge}"></span>
      </div>
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2}">步驟 1，共 2 步</span>
    </div>
    <h1 style="font-size:${ax(28)}px;line-height:${ax(34)}px;font-weight:700;letter-spacing:-.01em;color:${t.ink};margin:0">輸入你的 Email</h1>
    <p style="font-size:${ax(17)}px;line-height:${ax(25)}px;color:${t.ink2};margin:0">我們會寄一組 6 位數字給你，不用記密碼。</p>
    <div style="display:flex;flex-direction:column;gap:${SP.m}px">
      <span style="font-size:${ax(15)}px;line-height:${ax(21)}px;font-weight:600;color:${t.ink2}">Email</span>
      <div${S('win', 'field')} style="background:${t.board2};border:2px solid ${t.ink};border-radius:12px;box-shadow:inset 0 2px 0 ${t.bevelTop};min-height:${ax(56)}px;display:flex;align-items:center;padding:${SP.l}px">
        <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;color:${t.ink};overflow-wrap:break-word">${mail('ama@gmail.com')}</span>
      </div>
    </div>
    <div${S('raise', 'button')}${CTA} style="${raise(t, { fill: t.cta, lip: t.ctaDeep })};min-height:${ax(56)}px;display:flex;align-items:center;justify-content:center;padding:${SP.l}px;color:${t.onCta}">
      <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600;color:${t.onCta};text-align:center">傳送驗證碼</span>
    </div>
    <p style="font-size:${ax(13)}px;line-height:${ax(18)}px;color:${t.ink2};margin:0">信通常一分鐘內會到。沒看到的話，找找垃圾郵件。</p>
  </div>
</div>`);

/* 六格與票根在 AX5 的降版 —— Notes 上寫了兩條規則，這張板把它們畫出來：
   ① 六格改兩排三格（不橫向壓縮）
   ② 票根的 60pt 不跟著放大（60×3.1 = 186pt，一行放不下三碼）：
      鎖在 36pt 的 AX 推導值 112pt，並改成兩排三碼。 */
const stressCodeAX = (t) => {
  const cellH = ax(56), nAX = `font-family:${MONO};font-variant-numeric:tabular-nums;font-size:${ax(36)}px;line-height:${ax(40)}px;font-weight:600`;
  const cellAX = (d) => `<div${S('win', 'cell')}${MO('cells')} style="flex:1;background:${t.board2};border:${FIX.hair}px solid ${t.edge};border-radius:12px;box-shadow:inset 0 1.5px 0 ${t.bevelTop}, inset 0 5px 8px -4px ${t.bevelSoft}, inset 0 -1.5px 0 ${t.bevelBot};height:${cellH}px;display:flex;align-items:center;justify-content:center">
      <span style="${nAX};color:${t.ink}">${d}</span></div>`;
  const rowAX = (ds) => `<div style="display:flex;gap:${SP.s}px">${ds.map(cellAX).join('')}</div>`;
  return doc(t, `
<div class="g" data-col="phone" style="position:relative;width:390px;height:${h('StressCodeAX.dc.html')}px;background:${t.board};overflow:hidden;display:flex;flex-direction:column">
  <div style="padding:${FIX.safeTop}px ${FIX.gutter}px 0">
    <div style="min-height:${ax(17)}px;display:flex;align-items:center;gap:${SP.s}px;color:${t.ink}">
      <svg width="${ax(12)}" height="${ax(12)}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14.5 5 8 12l6.5 7"/></svg>
      <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600">返回</span>
    </div>
  </div>
  <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px;padding:${FIX.gutter}px ${FIX.gutter}px ${FIX.safeBottom}px;flex-grow:1">
    <h1 style="font-size:${ax(28)}px;line-height:${ax(34)}px;font-weight:700;letter-spacing:-.01em;color:${t.ink};margin:0">輸入邀請碼</h1>
    <div style="display:flex;flex-direction:column;gap:${SP.l}px">
      ${rowAX(['7', '4', '2'])}
      ${rowAX(['9', '3', '6'])}
    </div>
    <p style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};margin:0">念的時候是「七四二、九三六」。</p>
    <div${S('flat')}${MO('ticket')} style="${flat(t, { pad: '0', radius: 18 })};overflow:hidden">
      <div style="padding:${FIX.gutter}px;display:flex;flex-direction:column;align-items:center;gap:${SP.l}px">
        <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};letter-spacing:.16em;${press(t)}">邀 請 碼</span>
        <span style="${nAX};color:${t.ink};${press(t)}">742</span>
        <span style="${nAX};color:${t.ink};${press(t)}">936</span>
      </div>
      <div style="height:${FIX.hair}px;background:repeating-linear-gradient(90deg,${t.edge} 0 6px,transparent 6px 12px)"></div>
      <div style="padding:${SP.l}px ${FIX.gutter}px;display:flex;flex-direction:column;gap:${SP.s}px;background:${t.board3}">
        <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};${press(t)}">有效到 8 月 30 日</span>
        <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};${press(t)}">還可以用 3 次</span>
      </div>
    </div>
    <div${S('flat')} style="${flat(t, { pad: `${SP.l}px` })}">
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};${press(t)}">票根的 60pt 不跟著放大：60×3.1 = 186pt，一行排不下三碼。改鎖在分格那一階的推導值 ${ax(36)}pt，並拆成兩排。</span>
    </div>
  </div>
</div>`);
};

const stressContent = (t) => {
  const LONG_FAMILY = '陳家的小小世界（台中外婆家）';
  const LONG_MAIL = mail('chen.yi-chun.grandma1952@example-mail.com.tw');
  const c = (title, inner) => `
    <div style="display:flex;flex-direction:column;gap:${SP.m}px">
      <span style="${TY.l};color:${t.ink2}">${title}</span>
      <div class="g" data-col="phone" style="position:relative;width:390px;height:790px;background:${t.board};border:${FIX.hair}px solid ${t.edge};border-radius:18px;overflow:hidden;display:flex;flex-direction:column">${inner}</div>
    </div>`;
  return doc(t, `
<div class="g" style="position:relative;width:1290px;height:${h('StressContent.dc.html')}px;background:${t.board3};overflow:hidden;padding:${SP.xxl}px">
  <div style="display:flex;gap:${SP.xxl}px">
    ${c('長家庭名 + 即時預覽', `
      <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px;padding:${SP.xxl}px ${FIX.gutter}px;flex-grow:1">
        ${titleBlock(t, '幫你們家取個名字', '之後隨時可以改。')}
        ${field(t, { label: '家庭名稱', value: LONG_FAMILY, state: 'focus', hint: '14 字＋全形括號；再長會換行、欄位長高，不截斷。' })}
        ${namePreview(t, LONG_FAMILY)}
        ${btn(t, '建立家庭')}
      </div>`)}
    ${c('長 Email + 驗證碼', `
      <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px;padding:${SP.xxl}px ${FIX.gutter}px;flex-grow:1">
        <div style="display:flex;flex-direction:column;gap:${SP.s}px">
          <h1 style="${TY.h};color:${t.ink};margin:0">輸入信裡的 6 位數字</h1>
          <p style="${TY.b};color:${t.ink2};margin:0">已經寄到 <span style="color:${t.ink};font-weight:600;overflow-wrap:break-word">${LONG_MAIL}</span></p>
        </div>
        ${codeCells(t, ['4', '9', '2', '', '', ''], { caret: 3 })}
        ${tableLine(t, '找不到信？看看「垃圾郵件」或「促銷內容」那一夾。')}
        ${btn(t, '確認')}
      </div>`)}
    ${c('空欄位就按送出', `
      <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px;padding:${SP.xxl}px ${FIX.gutter}px;flex-grow:1">
        ${titleBlock(t, '輸入邀請碼', '家人給你的 6 位數字。')}
        ${codeCells(t, ['', '', '', '', '', ''], { caret: 0, error: true, sep: true })}
        ${errorLine(t, '還沒輸入號碼。請家人念給你聽，或看他傳來的訊息。')}
        ${tableLine(t, '送出之後家長會收到通知，他按下核准，你才進得到家庭裡。')}
        ${btn(t, '送出申請')}
      </div>`)}
  </div>
  <p style="${TY.b};color:${t.ink2};margin:${FIX.gutter}px 0 0;max-width:900px">三種真實雜訊：長家庭名（14 字＋全形括號，預覽跟著換行）、長 Email（44 字元，在 @ 後面斷行不切在字中間、也不掉孤兒字元）、空欄位就按送出（主按鈕不 disable）。三者都不截斷、不縮字、不擠壓按鈕。</p>
</div>`);
};

/* ─────────────────────  TOKENS 表  ───────────────────── */

const swatchRow = (t, hex, name, use, pairs) => `
  <div style="display:grid;grid-template-columns:64px 160px 1fr 240px;gap:${SP.l}px;align-items:center;padding:${SP.m}px 0;border-bottom:${FIX.hair}px solid ${t.edge}">
    <div style="height:44px;border-radius:10px;background:${hex};border:${FIX.hair}px solid ${t.edge}"></div>
    <div style="display:flex;flex-direction:column;gap:${SP.xs}px">
      <span style="${TY.l};color:${t.ink}">${name}</span>
      <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">${hex}</span>
    </div>
    <span style="${TY.cap};color:${t.ink2}">${use}</span>
    <span style="font-family:${MONO};${TY.cap};color:${t.ink}">${pairs}</span>
  </div>`;

const ruleCard = (t, title, lines) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
    <span style="${TY.l};color:${t.ink};${press(t)}">${title}</span>
    ${lines.map((l) => `<span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${l}</span>`).join('')}
  </div>`;

const tokensSheet = (measured) => {
  const t = T.light;
  const spec = (lines) => `<span style="font-family:${MONO};${TY.cap};color:${t.ink2}">${lines}</span>`;
  return doc(t, `
<div class="g" style="position:relative;width:980px;height:${h('Tokens.dc.html')}px;background:${t.board};overflow:hidden;padding:${FIX.padSheet}px">
  <div style="display:flex;flex-direction:column;gap:${SP.m}px;margin-bottom:${SP.xxl}px">
    <span style="${TY.cap};color:${t.ink2};letter-spacing:.14em">LITTLE SPROUT · M1 設計語言</span>
    <div style="display:flex;align-items:baseline;gap:${FIX.gutter}px">
      <h1 style="${TY.d};color:${t.ink};margin:0">卡紙開窗</h1>
      ${inkMark(INK.sheet, t.ink)}
    </div>
    <p style="${TY.b};color:${t.ink2};margin:0;max-width:640px">整個 app 是一塊暖色卡紙。<b style="color:${t.ink}">凹進去＝可以填東西進去</b>、<b style="color:${t.ink}">浮起來＝可以按</b>、<b style="color:${t.ink}">平印上去＝只能讀</b>。三種表面，一種一個意思。<b style="color:${t.ink}">例外只有下面列出來的那幾個 —— 沒印在這張板上的例外，就是 bug。</b></p>
    <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">實測資料 #${MEAS_HASH}（量於 ${M.measuredAt || '尚未量測'}）—— 這張板上每一句「實測」都出自這一份 measured.json。產物與量測不同版時管線 FAIL（G21），所以板上的數字不可能是上一版的。</span>
  </div>

  <div style="display:grid;grid-template-columns:repeat(3, minmax(0, 1fr));gap:${FIX.gutter}px;margin-bottom:${SP.xxl}px">
    <div${S('win', 'field')} style="${win(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.ink}">凹 · 可以填</span>
      ${spec(`border ${FIX.hair}px edge · radius 12<br>inset 0 1.5px 0 bevelTop<br>inset 0 4px 6px -3px bevelSoft<br>inset 0 -1.5px 0 bevelBot`)}
    </div>
    <div${S('raise', 'button')}${CTA} style="${raise(t, { fill: t.cta, lip: t.ctaDeep })};padding:${SP.l}px;color:${t.onCta};display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.onCta}">浮 · 可以按（兩層）</span>
      <span style="font-family:${MONO};${TY.cap};color:${t.onCta}">radius 14 · border-bottom ${FIX.lip}px ＋ 落影 0 1px 0 / 0 8px 16px -10px<br>沒有第三層：inset topLight 已移除</span>
    </div>
    <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.ink};${press(t)}">平印 · 只能讀</span>
      ${spec(`border ${FIX.hair}px edge · radius 12/14/18<br>沒有 inset、沒有 lift<br>字加 letterpress：text-shadow press`)}
    </div>
  </div>

  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${FIX.gutter}px;margin-bottom:${SP.xxl}px">
    ${ruleCard(t, '「凹＝可以填」的完整白名單（八個角色，沒有第九個）', [
      '<b>field</b> 輸入框 · <b>cell</b> 驗證碼格 · <b>photo</b> 照片位／等待窗 · <b>avatar</b> 頭像 · <b>codeslot</b> 還沒產生的號碼位',
      '<b>choiceSel</b> 身分選項「選中」——選中＝壓下去，是使用者剛剛填進去的答案。',
      '<b>switchOff</b> 開關「關」的軌道——把手還沒被推到底，是等著被填的凹槽。',
      '<b>seam</b> 卡紙壓過照片的接縫——那道 inset 是紙的厚度，整套語言的出處。',
      measured.insetLine,
    ])}
    ${ruleCard(t, '色的例外，逐條列出', [
      '<b>芽綠＝把關的機制正在生效</b>：① 加入流程的「申請已送出」（你的申請進了待核清單，等人放行）；② 審核開關 ON 的軌道（新成員要核准才能進來）。<b>第三個綠色就是 bug。</b>',
      '<b>酒紅擴張到「危險的設定」</b>：原本只有「輸入錯了」（2pt 線＋一行字）；審核關閉時開關列的 3pt 唇邊也換酒紅。同一畫面仍然最多兩處。',
      '<b>陶土每畫面最多一個</b>（算的是最外層的陶土區塊，卡片裡的圖示井算在卡片內）。審核關閉、等待核准這兩張沒有陶土——因為沒有值得推薦的動作。',
      '陶土、酒紅、芽綠<b>永遠不當文字色</b>（酒紅的錯誤句是例外，13–17pt 粗體，實測 AAA）。',
      measured.ctaLine,
    ])}
  </div>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.s}px">色彩 · 淺色（實測 WCAG 2.1 對比）</h2>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.s}px">文字只有兩級：ink 與 ink2。edge 是全稿唯一的線色。</p>
  ${swatchRow(t, t.board, '卡紙 board', '所有畫面的底。不是白，是有色卡紙。', measured.board)}
  ${swatchRow(t, t.board2, '窗底 board-2', '凹進去的地方：輸入框、驗證碼格。', measured.board2)}
  ${swatchRow(t, t.board3, '次要面 board-3', '次要按鈕、票根下緣、身分選項未選中、待核列。', measured.board3)}
  ${swatchRow(t, t.lit, '亮面 lit', '身分選項「選中」那一格 —— 選中是更亮，不是更暗。', measured.lit)}
  ${swatchRow(t, t.ink, '墨 ink', '標題、輸入值、主要文字、手寫字標。', measured.ink)}
  ${swatchRow(t, t.ink2, '淡墨 ink-2', '說明、標籤、註記、placeholder。只有兩級文字。', measured.ink2)}
  ${swatchRow(t, t.cta, '陶土 CTA', '主要按鈕底色。每個畫面最多一個。', measured.cta)}
  ${swatchRow(t, t.wine, '酒紅 wine', '錯誤，以及「危險的設定」。一張板最多兩處。', measured.wine)}
  ${swatchRow(t, t.sprout, '芽綠 sprout', '把關的機制正在生效。全稿兩個使用點（見上）。', measured.sprout)}
  ${swatchRow(t, t.edge, '切邊 edge', '開窗邊、分隔線、未走的步驟段。非文字，走 1.4.11 的 3:1。', measured.edge)}

  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${SP.xxl}px;margin-top:${FIX.gutter}px">
    <div>
      <h2 style="${TY.l};color:${t.ink};margin:0 0 ${SP.m}px">邊界案例（實測值）</h2>
      <div style="display:flex;flex-direction:column;gap:${SP.s}px;font-family:${MONO};${TY.cap};color:${t.ink2}">
        ${measured.edgecases.map((l) => `<span>${l}</span>`).join('')}
      </div>
      <p style="${TY.cap};color:${t.ink2};margin:${SP.m}px 0 0">全稿的透明度只剩一處：卡紙顆粒（${t.grain}）。<b style="color:${t.ink}">沒有任何文字帶 opacity；照片上沒有任何文字。</b></p>
    </div>
    <div>
      <h2 style="${TY.l};color:${t.ink};margin:0 0 ${SP.m}px">深色（四張板，四個母題都入鏡）</h2>
      <div style="display:flex;flex-direction:column;gap:${SP.s}px;font-family:${MONO};${TY.cap};color:${t.ink2}">
        ${measured.dark.map((l) => `<span>${l}</span>`).join('')}
      </div>
    </div>
  </div>

  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${SP.xxl}px;margin-top:${FIX.gutter}px">
    <div>
      <h2 style="${TY.l};color:${t.ink};margin:0 0 ${SP.m}px">間距 · 七階，沒有第八階</h2>
      <div style="display:flex;flex-direction:column;gap:${SP.s}px">
        ${[[4, '圖示與字、預覽列內'], [8, '標題→說明、格與格、欄位→錯誤線'], [12, '標籤→欄位、按鈕之間'], [16, '欄位→提示、待核列之間'], [24, '組與組之間、前三碼→後三碼'], [32, '段落之間、核准↔拒絕'], [44, '最小點擊']]
      .map(([n, use]) => `<div style="display:flex;align-items:center;gap:${SP.m}px">
             <span style="width:${n}px;height:12px;background:${t.cta};border-radius:2px;flex:none"></span>
             <span style="font-family:${MONO};${TY.cap};color:${t.ink};width:32px;flex:none">${n}</span>
             <span style="${TY.cap};color:${t.ink2}">${use}</span></div>`).join('')}
      </div>
      <p style="${TY.cap};color:${t.ink2};margin:${SP.m}px 0 0">${measured.gaps}</p>
    </div>
    <div>
      <h2 style="${TY.l};color:${t.ink};margin:0 0 ${SP.m}px">固定常數 —— 不是間距階，是量出來的實體尺寸</h2>
      <div style="display:flex;flex-direction:column;gap:${SP.xs}px;font-family:${MONO};${TY.cap};color:${t.ink2}">
        ${[
      [`safeTop ${FIX.safeTop} · safeBottom ${FIX.safeBottom}`, 'iOS 狀態列與 Home indicator'],
      [`tap ${FIX.tap} · button ${FIX.button} · cell ${FIX.cell} · avatar ${FIX.avatar}`, '控制項高度'],
      [`gutter ${FIX.gutter} · padSheet ${FIX.padSheet} · padPad ${FIX.padPad} · padPadX ${FIX.padPadX}`, '手機／交付板／iPad 直橫版心'],
      [`lip ${FIX.lip} · errBar ${FIX.errBar} · hair ${FIX.hair} · knob ${FIX.knob}`, '唇邊、錯誤線、切邊、開關把手'],
      [`codeLine ${FIX.codeLine} · btnMax ${FIX.btnMax}`, '票根數字帶高（空票根同高）、iPad 按鈕寬上限'],
      [`capAlign ${FIX.capAlign} · navOpt ${FIX.navOpt}`, 'iPad 跨欄 cap 對齊補償、返回鍵外推'],
      [`seam ${FIX.seam} · seamPhone ${FIX.seamPhone}`, '卡紙壓過照片的重疊（iPad／手機）'],
    ].map(([k, v]) => `<div style="display:flex;gap:${SP.m}px"><span style="color:${t.ink};min-width:300px">${k}</span><span>${v}</span></div>`).join('')}
      </div>
      <p style="${TY.cap};color:${t.ink2};margin:${SP.m}px 0 0">${measured.pads}</p>
    </div>
  </div>

  <div style="margin-top:${FIX.gutter}px">
    <h2 style="${TY.l};color:${t.ink};margin:0 0 ${SP.m}px">字級 · 十階（6 文字 + 2 數字 + 2 iPad），誠實列出</h2>
    <div style="display:flex;flex-direction:column;gap:${SP.m}px">
      ${[
      [TY.d, '孩子的每一天', '34/40 700 · largeTitle · 只在歡迎頁（手機）'],
      [TY.h, '輸入你的 Email', '28/34 700 · title1 · 每畫面 1 個'],
      [TY.c, '有 3 個人想加入', '22/28 600 · title3 · 每畫面 ≤1（頭像字母、邀請碼的「、」共用此級）'],
      [TY.b, '家人給你的 6 位數字', '17/25 400 · body（600 是同一階的另一個字重）'],
      [TY.l, '家庭名稱', '15/21 600 · subheadline · 欄位標籤、待核列的「查看」'],
      [TY.cap, '有效到 8 月 30 日', '13/18 500 · footnote · 最小字級'],
      [TY.n2, '742 936', '36/40 600 mono · 分格輸入'],
    ].map(([sty, sample, note]) => `<div style="display:flex;align-items:baseline;gap:${SP.l}px">
          <span style="${sty};color:${t.ink}">${sample}</span>
          <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">${note}</span></div>`).join('')}
      <div style="display:flex;align-items:baseline;gap:${SP.l}px">
        <span style="${TY.n1};color:${t.ink}">742</span>
        <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">60/64 600 mono · 票根</span>
      </div>
      <div style="display:flex;align-items:baseline;gap:${SP.l}px">
        <span style="${TY.dHero};color:${t.ink}">iPad 歡迎</span>
        <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">60/68 700 · 與票根同一階，iPad 歡迎頁標題</span>
      </div>
      <div style="display:flex;align-items:baseline;gap:${SP.l}px">
        <span style="${TY.dPad};color:${t.ink}">iPad 標題</span>
        <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">42/50 700 ＋內文 19/28 400 —— iPad 只有這兩階往上加</span>
      </div>
    </div>
    <p style="${TY.cap};color:${t.ink2};margin:${SP.m}px 0 0">${measured.sizes}</p>
  </div>

  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${FIX.gutter}px;margin-top:${FIX.gutter}px">
    ${ruleCard(t, '量得出來的規則（每一條都有實測句，不是宣言）', [
      `<b>H1 起跑線</b>：${Object.keys(H1_GROUPS).length} 組畫面，每組內部同一條線，逐張量 cap-height（cap 比例 ${CAP}）。${measured.h1Line}`,
      `<b>呼吸帶 ①</b>：<b>內容首末之間，任何一段連續空白 ≤${RULE.pause}px（手機 iPad 同一條，沒有 iPad 例外）。</b>超過的必須掛 <code>data-pause="理由"</code>，掛不出理由的就是版面破了；管線掃到未掛牌的一律 FAIL。`,
      `<b>呼吸帶 ②</b>：<b>內容末端到板底不設上限，但主按鈕中心須落在畫面 ${RULE.btnPct}% 以內。</b>兩條規則是<b>分工</b>，不是同一條的寬嚴兩版：<b>①管內部</b> —— 用 spacer 把按鈕推到板底，必然在內容之間造出 >${RULE.pause}px 的空白，①就抓得到（拔掉掛牌會 FAIL，突變測過）；<b>②是「尾段不設上限」這個豁免的對價</b> —— 底部主按鈕貼安全區是 iOS 的正解（<code>safeAreaInset</code>，見 Notes），所以尾段放行，但只要用到這個豁免（尾段 >${RULE.pause}px），就要付 ${RULE.btnPct}% 這筆價。沒用到豁免的板不收費。${measured.voidLine}`,
      `<b>錯誤幾何不得與可按幾何重合</b>：錯誤線 ${FIX.errBar}pt、距離輸入面 ${SP.s}pt；可按的唇邊 ${FIX.lip}pt、貼著元件下緣。兩者不同寬、不同位置、最近距離 ≥${SP.xs}pt。${measured.errLine}`,
      `<b>${FIX.lip}pt 唇邊＝該表面的深一階</b>：陶土→ctaDeep、卡紙→edge、危險→wine。${measured.lipLine}`,
    ])}
    ${ruleCard(t, '手寫字標', [
      '全稿唯一的非系統線條。每一筆是「中線貝茲＋起筆寬／收筆寬／中段提按」推出來的填色外框，所以真的有粗細變化，不是圓頭 stroke 假裝的。',
      `三個使用點：歡迎頁（手機 ${INK.phone}、iPad ${INK.pad}）、信件明細的「寄件人」（${INK.mail}）、建立家庭的即時預覽（${INK.preview}）。畫面上看到的筆跡，信箱裡也會看到同一支。`,
      '它<b>不壓在照片上</b>（照片上的對比無法定義）—— 它在卡紙上，ink/board 實測 ' + measured.inkContrast + '。',
      'ios-dev：出成單一 SVG asset（兩個字一個檔），用 <code>Image(decorative:)</code>＋<code>accessibilityLabel("小芽")</code>；深色模式只換 fill。',
    ])}
  </div>
</div>`);
};

/* ─────────────────────  實作註記  ───────────────────── */

const note = (t, title, lines) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
    <span style="${TY.l};color:${t.ink};${press(t)}">${title}</span>
    <ul style="margin:0;padding-left:${SP.l}px;display:flex;flex-direction:column;gap:${SP.xs}px">
      ${lines.map((l) => `<li style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${l}</li>`).join('')}
    </ul>
  </div>`;

const notesSheet = () => {
  const t = T.light;
  return doc(t, `
<div class="g" style="position:relative;width:980px;height:${h('Notes.dc.html')}px;background:${t.board};overflow:hidden;padding:${FIX.padSheet}px">
  <div style="display:flex;flex-direction:column;gap:${SP.xs}px;margin-bottom:${FIX.gutter}px">
    <span style="${TY.cap};color:${t.ink2};letter-spacing:.14em">給 ios-dev · LS-17 / LS-18</span>
    <h1 style="${TY.h};color:${t.ink};margin:0">實作註記</h1>
  </div>
  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${SP.l}px">
    ${note(t, '三種表面 = 三個規則', [
    '凹（<code>win</code>）只給白名單上的八個角色：輸入框、驗證碼格、照片位／等待窗、頭像、還沒產生的號碼位、身分選項選中、開關關閉的軌道、卡紙接縫。<b>白名單印在 Tokens 板上。</b>',
    `浮（<code>raise</code>）<b>只有兩層</b>：${FIX.lip}pt 下緣唇邊 ＋ 落影。唇邊用 <code>.overlay(alignment:.bottom)</code> 畫，不要用 shadow 假裝。第 2 輪的 inset topLight 是第三層、也是「有 inset＝可以填」的無聲例外，已移除。`,
    `平印（<code>flat</code>）給「只能讀」的：票根、明細表、說明框、待核卡片。沒有 inset、沒有 lift，只有 ${FIX.hair}px edge 與字的 letterpress。`,
    'iOS 17 沒有 inner shadow API：用兩層 stroke（上緣深、下緣亮）或 <code>.stroke(gradient).blur().mask()</code>。',
  ])}
    ${note(t, '色彩落地', [
    '把 Tokens 板的 hex 建成 Asset Catalog color set，每一個都給 Any 與 Dark 兩個外觀值；View 裡只用語意名，例如 <code>Color.lsBoard</code>。',
    `陶土與酒紅<b>只當底色</b>（酒紅的錯誤句是唯一的文字用法）。任何「陶土色文字」都是 bug —— 它在卡紙上只有 ${cr(L.cta, L.board)}:1。`,
    '<b>文字一律不加 opacity。</b>placeholder 用實色 <code>lsInk2</code>；步驟條未走的段用實色 <code>lsEdge</code>。',
    '<b>芽綠＝把關的機制正在生效</b>：「申請已送出」（等人放行）與審核開關 ON 的軌道（要核准才能進來）。<b>第三個綠色就是 bug。</b>',
    `<b>${FIX.lip}pt 唇邊＝該表面的深一階</b>：陶土→<code>ctaDeep</code>、卡紙→<code>edge</code>、危險→<code>wine</code>。用 <code>.overlay(alignment:.bottom)</code> 畫，顏色跟著表面走，不要各自寫死。`,
  ])}
    ${note(t, 'Dynamic Type', [
    '全部用 <code>Font.largeTitle/title/title3/body/subheadline/footnote</code>，不要 <code>.system(size:)</code>。',
    `按鈕用 <code>minHeight: ${FIX.button}</code>，字級長大時按鈕跟著長。`,
    '<b>AX3 以上，按鈕裡的 icon 一律拿掉只留字</b> —— 放大的 icon 會把按鈕撐爆（見 AX5 壓力板）。',
    '<b>驗證碼六格在 AX3 以上改成兩排三格</b>（<code>ViewThatFits</code>），不要橫向壓縮。',
    `<b>票根的 60pt 不跟著放大</b>：60×3.1 = 186pt，一行排不下三碼。鎖在分格那一階的 AX 推導值 ${ax(36)}pt 並拆成兩排 —— 見 AX5 邀請碼板。`,
    '外層一律 <code>ScrollView</code>，底部按鈕用 <code>safeAreaInset(edge:.bottom)</code>。',
  ])}
    ${note(t, '點擊目標', [
    `<b>連結本身就是 ${FIX.tap}pt 命中盒</b>，不是外面包一層：<code>.padding(.horizontal,${SP.s}).frame(minHeight:${FIX.tap}).contentShape(Rectangle())</code>。`,
    `「使用條款」「隱私權政策」是<b>兩個獨立</b>的 ${FIX.tap}pt 盒，不是一段文字裡的兩段 range。「換帳號」同理。`,
    `拒絕／換號碼這類次要動作用<b>不滿版</b>的連結（<code>fixedSize</code>），跟主按鈕隔 ${SP.xxl}pt。`,
    '圖示一律配文字標籤，沒有純圖示按鈕 —— 包含返回鍵、包含待核列右邊的「查看 ›」。',
  ])}
    ${note(t, '狀態：空 / 載入 / 錯誤', [
    '<b>載入就地轉態</b>：按鈕原地換成 <code>ProgressView</code> ＋文案，底色換 cta-deep。不用全螢幕遮罩。',
    '<b>空狀態</b>是邀請動作：邀請家人空狀態直接指向「產生邀請碼」，而且把號碼的用途講完。',
    `<b>錯誤只有兩個紅</b>：輸入面下方 ${SP.s}pt 處一道<b>獨立的</b> ${FIX.errBar}pt 酒紅線 ＋ 一行酒紅訊息。它刻意不是 border-bottom —— ${FIX.lip}pt 貼邊的線是「可以按」的唇邊，兩者不可以撞衫。`,
    '<b>出錯時明細表收成一行</b>：讓「欄位 → 錯誤句 → 下一步」擠成一群，中間不卡一張三行的表。',
    '<b>驗證碼輸錯</b>：六格全部清空、焦點回第 1 格，訊息說明已經清空。主按鈕<b>不要</b> disable。',
    '過期與次數用盡是<b>兩段不同文案</b>，不可合併成「邀請碼無效」。',
  ])}
    ${note(t, '邀請碼', [
    '<b>一律 6 位純數字</b>，顯示與輸入都切 3＋3。理由：長輩會在電話裡念號碼，英數混合會有 0/O、1/l 誤聽。',
    '只有<b>兩種正典</b>：票根 60pt（顯示）、分格 36pt（輸入）。OTP 與邀請碼共用同一個分格元件。',
    '<b>輸入邀請碼那一版，兩組中間印一個「、」</b>：畫面上的分組就是嘴巴唸出來的分組（「七四二、九三六」）。OTP 那一版沒有這句話，所以只用 24pt 的組間距。',
    `期限與剩餘次數<b>永遠跟著號碼</b>（票根下緣那條）。<b>還沒產生的號碼位就是一張空票根</b>：外框、數字帶高（<code>codeLine ${FIX.codeLine}</code>）、騎縫線、下緣帶全部一樣，只有表面從平印換成凹（可以填）—— 所以四個狀態的高度一致，開關列不會跳位。`,
    '有人在等核准時，票根降成一行 —— 畫面的主詞是人，不是號碼。',
  ])}
    ${note(t, '兩段式審核（LS-18 使用者核定）', [
    '輸碼 → <code>request_join(code)</code> → 等待核准；核准前 RLS 一律查不到內容，UI 不要樂觀寫入。',
    'Owner 待核清單：<b>等最久的排最上面並攤開</b>，其餘收成一列（頭像＋名＋Email＋等多久＋「查看 ›」），點開才展開。一次只有一張攤開，所以陶土色每畫面仍然只有一個。',
    '身分選項是<b>可按的（浮起）</b>；選中＝下沉＋打勾＋<b>更亮</b>。選中不可以用「更暗」表示。',
    `核准是陶土主按鈕、拒絕是不滿版的墨色底線連結，<b>相隔 ≥${SP.xxl}pt 且不並排</b>。`,
    `<b>開關列固定在票根正下方</b>，四個狀態（空／產生中／已產生／審核關閉）同一條線 —— 它管的就是「誰能進來」，<b>不隨狀態移位</b>。空的號碼位與票根是同一個外框（凹／平印兩種表面），所以四態等高。`,
    `<b>審核開關關掉時</b>：整列的 ${FIX.lip}pt 唇邊換酒紅（不是再加一圈描邊——那會變成第三個紅）＋補一行「任何拿到號碼的人都能直接看到照片」＋<b>撤掉陶土主按鈕</b>，主動作降級成次要的「還是要傳給家人」。示警靠這三件事，不靠版面跳動。`,
  ])}
    ${note(t, 'iPad', [
    `登入是全螢幕流程，照片吃左邊 55%（657/1194）。內容欄<b>不垂直置中</b>，改三段式：字標貼上緣、標題組居中、按鈕與法律行貼欄底。兩段間隔各掛 <code>data-pause</code> 說明理由。按鈕<b>寬度上限 ${FIX.btnMax}pt</b>。`,
    `三岔路 iPad <b>不放照片</b>（照片在登入頁出場過了）：雙欄。說明欄<b>比照手機版，帳號列貼上緣</b>，往下 ${FIX.gutter} → H1 → ${SP.s} → 副標 → ${SP.xxl} → 說明框，<b>排完就停</b>（沒有 <code>space-between</code>），剩餘空白落在欄底。`,
    `兩欄的第一行字仍然視覺同高：左欄 H1（42/50）的 cap-height 對齊右欄首卡標題（28/34、卡內距 ${FIX.tap}）的 cap-height —— 右欄整體下推 <b>${FIX.capAlign}pt</b>（＝${FIX.tap}+${FIX.gutter} 的帳號列高度差與兩級字 cap 差的合計，管線逐張量）。`,
    '<b>iPad 內文一律 19pt 起跳</b>；iPad 歡迎頁標題用 60pt（與票根同一階，不是新階）。',
    '進到家庭之後才切 <code>NavigationSplitView</code>（M2）。',
  ])}
    ${note(t, '照片（未解決，需要人決定）', [
    '<b>歡迎頁的照片位是佔位圖，不是主視覺完稿。</b>畫面上<b>不再印任何規格註記</b>——攝影 brief 只在這張板上（第 2 輪：「把 backlog 當設計」）。',
    '要換成真實家庭照：至少兩個人、看得到臉（可局部或失焦）、主體落在三分線不在正中、有生活雜訊（鞋／玩具／碗）、<b>沒有人背對鏡頭走開</b>、<b>清晰</b>（模糊＝沒有內容）。',
    `比例 4:5、長邊 ≥1600、暖調逆光。卡紙上緣壓過照片 ${FIX.seamPhone}pt（iPad 是 ${FIX.seam}pt）並帶 ${FIX.hair}pt 切邊 —— 這個交界是整套語言的出處，不要拉平。`,
    `<b>焦點規格（各斷點自己一組值，不要共用一組）</b>：焦點寫成影像座標比例 <b>(${Math.round(PHOTO.fx * 100)}%, ${Math.round(PHOTO.fy * 100)}%)</b>，<code>object-position</code> 由它推。${measured.focusLine}`,
    `<b>alt 寫「看得到什麼」</b>（誰、在哪、在做什麼），不寫用途、不寫攝影指示 —— brief 不可以藏在 alt 裡。目前的 alt 描述的就是佔位圖本身：「${PHOTO_ALT}」。換上真照片時，alt 跟著改寫。`,
    '照片上<b>不放任何文字</b>（壓在照片上的對比無法定義）。歡迎頁的溫度來源改成手寫字標，它在卡紙上，對比量得出來。',
    '本管線（手寫 SVG 合成）試了 8 版都做不到可用的人臉品質，因此改用佔位圖。這是<b>刻意的取捨，不是遺漏</b>。',
  ])}
    ${note(t, 'Sign in with Apple', [
    '黑底白字、官方字串「透過 Apple 登入」、圓角 14 —— <b>顏色與字樣不可改</b>（HIG）。它是全稿唯一沒有唇邊的浮起表面，因為唇邊會改到它的外觀。',
    '本專案把 Email OTP 排在 Apple 之上：Email 是第一方登入，不是第三方社群登入。送審前請再確認當時的 Review Guidelines。',
    '<b>已固化的決定</b>：深色下 Apple 鍵依 HIG 為<b>白底</b>，視覺重量高於 Email 鍵；本專案<b>接受</b>這個反轉，<b>順序（Email 在上）是唯一的優先訊號</b>。不要為了扳回重量去改 Apple 鍵的色、加描邊、或把 Email 鍵放大。',
  ])}
  </div>
  <p style="${TY.cap};color:${t.ink2};margin:${FIX.gutter}px 0 0">尚未決定、需要人核可：① 歡迎頁照片素材（目前是佔位圖）；② Email 排在 Apple 之上（送審風險）；③ 邀請碼改純數字 6 碼（影響 <code>invites.code</code> 產生器與碰撞率，且與軌 A／LS-33 現行實作衝突）；④ 待核清單的身分選擇是否放在核准當下。</p>
</div>`);
};

/* ─────────────────────  對比實測（寫進 Tokens 板）  ───────────────────── */

const hex = (h) => { h = h.replace('#', ''); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
const lum = (c) => { const s = c.map((v) => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }); return .2126 * s[0] + .7152 * s[1] + .0722 * s[2]; };
const CR = (a, b) => { const l1 = lum(a), l2 = lum(b); const [hi, lo] = l1 > l2 ? [l1, l2] : [l2, l1]; return (hi + .05) / (lo + .05); };
const cr = (a, b) => CR(hex(a), hex(b)).toFixed(2);
const ratio = (a, b) => `${cr(a, b)}:1`;   // 註記裡的對比一律用這個，":1" 才不是手打的數字
const mix = (fg, bg, al) => fg.map((v, i) => v * al + bg[i] * (1 - al));
const crMix = (fg, bg, al) => CR(mix(hex(fg), hex(bg), al), hex(bg)).toFixed(2);
const tag = (v) => (v >= 7 ? 'AAA' : v >= 4.5 ? 'AA' : v >= 3 ? '3:1 過' : 'FAIL');

const L = T.light, D = T.dark;
const measured = {
  board: `ink ${cr(L.ink, L.board)} · ink2 ${cr(L.ink2, L.board)}`,
  board2: `ink ${cr(L.ink, L.board2)} · ink2 ${cr(L.ink2, L.board2)}`,
  board3: `ink ${cr(L.ink, L.board3)} · ink2 ${cr(L.ink2, L.board3)}`,
  lit: `ink ${cr(L.ink, L.lit)}（選中格只用 ink）`,
  ink: `on board ${cr(L.ink, L.board)}`,
  ink2: `board ${cr(L.ink2, L.board)} · b-2 ${cr(L.ink2, L.board2)} · b-3 ${cr(L.ink2, L.board3)}`,
  cta: `白字 ${cr(L.onCta, L.cta)} · 深唇 ${cr(L.onCta, L.ctaDeep)}`,
  wine: `board ${cr(L.wine, L.board)} · b-3 ${cr(L.wine, L.board3)}`,
  sprout: `board ${cr(L.sprout, L.board)} · 軌道對 b-3 ${cr(L.sprout, L.board3)} · 把手 ${cr(L.onSprout, L.sprout)}`,
  edge: `board ${cr(L.edge, L.board)} · b-2 ${cr(L.edge, L.board2)} · b-3 ${cr(L.edge, L.board3)}`,
  inkContrast: cr(L.ink, L.board),
  edgecases: [
    `placeholder 實色 ink2/board2 … ${cr(L.ink2, L.board2)} ${tag(+cr(L.ink2, L.board2))}（原 ink2@.72 = ${crMix(L.ink2, L.board2, .72)}）`,
    `步驟條未走段 實色 edge/board … ${cr(L.edge, L.board)} ${tag(+cr(L.edge, L.board))}（原 edge@.38 = ${crMix(L.edge, L.board, .38)}）`,
    `錯誤線 wine/board … ${cr(L.wine, L.board)}（非文字，門檻 3:1）`,
    `芽綠軌道 sprout/board3 … ${cr(L.sprout, L.board3)}（非文字，門檻 3:1）· 白把手/芽綠 ${cr(L.onSprout, L.sprout)}`,
    `選中身分格 ink/lit … ${cr(L.ink, L.lit)} AAA`,
    `平印表面 ink/board（無填色）… ${cr(L.ink, L.board)} AAA`,
  ],
  dark: [
    `board #211913 · board-2 #191310 · board-3 #2E2419 · lit #463726`,
    `ink #F4E8D7 ${cr(D.ink, D.board)} · ink2 #CBB69F ${cr(D.ink2, D.board)}`,
    `cta #E59468 ＋墨字 → ${cr(D.onCta, D.cta)}`,
    `wine ${cr(D.wine, D.board)} · sprout 軌道對 b-3 ${cr(D.sprout, D.board3)} · 把手 ${cr(D.onSprout, D.sprout)}`,
    `選中格 ink/lit ${cr(D.ink, D.lit)} · placeholder ink2/board2 ${cr(D.ink2, D.board2)}`,
    `光源反轉：letterpress 由「下緣亮」翻成「上緣暗」（press: ${D.press}）—— 四張深色板都畫得出來`,
    `深色最低文字組合 ${Math.min(+cr(D.onCta, D.cta), +cr(D.ink2, D.board), +cr(D.wine, D.board)).toFixed(2)}（AAA）`,
  ],
  gaps: '', sizes: '', pads: '', insetLine: '', ctaLine: '', h1Line: '', voidLine: '', errLine: '',
  lipLine: '', focusLine: '',
};

/* verify.mjs / measure.mjs 會重新掃描產出並回填實測句子；
   設計稿上印的每一句都是從 measured.json 讀的，不是手寫的。 */
const MJ = new URL('measured.json', import.meta.url);
const MEAS_RAW = existsSync(MJ) ? readFileSync(MJ, 'utf8') : '';
const M = MEAS_RAW ? JSON.parse(MEAS_RAW) : {};
/* 這一次 build 讀到的 measured.json 指紋。每一張產物都蓋上它（見 doc()），
   verify 的 G21 拿現行 measured.json 的指紋比對 —— 板上印的實測句是不是上一版，
   從此是 gate 判的，不是人記得跑第二輪。 */
const MEAS_HASH = MEAS_RAW ? hash12(MEAS_RAW) : 'no-measurement';
const say = (v, f) => (v === undefined ? '（尚未量測：node measure.mjs && node verify.mjs）' : f(v));

measured.gaps = say(M.gapCount, () => `實測（${M.measuredAt || '本次'}）：${M.count} 張板共 ${M.gapCount} 個 gap，全部落在這七階。`);
measured.sizes = say(M.sizesUsed, () => `實測：${M.count} 張板的 font-size 只出現這 ${M.sizesUsed.length} 階 [${M.sizesUsed}]，外加 AX 壓力板的 ×3.1 推導值 ${M.axDerived.length} 個。`);
measured.pads = say(M.padCount, () => `實測：${M.padCount} 個 padding/margin 值，全部落在七階或上表的常數（第 2 輪只掃 gap，放走 133 個）。`);
measured.insetLine = say(M.insetUse, () => `實測：${M.insetTotal} 個帶 inset 的使用點，全部落在這八個角色（第 2 輪只 grep helper 定義，實測 49 個非可填元件帶 inset）。`);
measured.ctaLine = say(M.ctaMax, () => `實測：${M.ctaBoards} 張流程板，最外層陶土區塊最多 ${M.ctaMax} 個／板。`);
measured.h1Line = say(M.h1 && M.h1.groups, () => `實測：${Object.entries(M.h1.groups).map(([g, v]) => `${g} ${v.n} 張同在 ${v.ys.join('／')}px`).join('；')}。排除 ${H1_EXCLUDED.length} 張（iPad 走跨欄基線、AX 壓力板、板中板、交付板）。`);
/* 措辭統一（第 4 輪 R10）：主按鈕的位置一律講「最低」＝畫面上最靠下的那一張＝百分比最大的那一張。
   measure.mjs 的 console、verify.mjs 的 G10、這一句，三處同一個詞。 */
measured.voidLine = say(M.maxVoid, () => `實測：手機最大 ${M.maxVoid}px（${M.maxVoidFile}）；iPad 欄內最大 ${M.maxVoidPad}px（${M.maxVoidPadFile}）；超過 ${RULE.pause} 的 ${M.pauses ? M.pauses.length : 0} 段全部掛了 data-pause，未掛牌的 ${M.pauseBad ? M.pauseBad.length : 0} 段。尾段空白最大 ${M.maxTrail}px（${M.maxTrailFile}）；主按鈕中心<b>位置最低</b>（＝百分比最大）的是 ${M.btnMaxPct}%（${M.btnMaxFile}），其中尾段 >${RULE.pause}px 的板位置最低 ${M.btnTailPct === null ? '無此板' : `${M.btnTailPct}%（${M.btnTailFile}）`}。`);
measured.errLine = say(M.errGap, () => `實測：${M.errCount} 道錯誤線，與最近的唇邊距離最小 ${M.errGap}px。`);
measured.lipLine = say(M.lips, () => {
  const n = (k) => M.lips[`${k}@${FIX.lip}`] || 0;
  const who = (re) => (M.lipNoneWho || []).filter((s) => re.test(s)).length;
  return `實測：${M.lipTotal} 個浮起面，唇邊 ctaDeep ${n('ctaDeep')}／edge ${n('edge')}／wine ${n('wine')}，寬度一律 ${FIX.lip}pt。`
    + `<b>兩個例外，都在這裡</b>：Apple 鍵 ${who(/:button$/)} 個沒有唇邊（HIG 外觀不可改）；審核開關 ON 的軌道 ${who(/:switch$/)} 個沒有唇邊（56×32 的膠囊，唇邊會壓到把手的行程）。`
    + `另外「載入中」的按鈕底與唇邊同色（ctaBusy），因為它這一刻按不動。`;
});
measured.focusLine = say(M.focus, () => M.focus.map((f) => `<b>${f.name} ${f.bw}×${f.bh}</b>：cover 後只裁${f.axis}（${f.crop}px），<code>object-position:${f.pos}</code>${f.clamped ? '（焦點超出可及範圍，已鎖到極值）' : ''}`).join('；') + '。另一軸寫什麼都沒有作用，不要照抄兩軸數字。');

/* ─────────────────────────  EMIT  ───────────────────────── */

const files = {
  'Main.dc.html': welcome(L),
  'WelcomeDark.dc.html': welcome(D),
  'WelcomeSending.dc.html': welcome(L, { busy: true }),
  'WelcomeIPad.dc.html': welcomeIPad(L),
  'Email.dc.html': emailScreen(L),
  'EmailError.dc.html': emailScreen(L, { error: true }),
  'Otp.dc.html': otpScreen(L),
  'OtpError.dc.html': otpScreen(L, { error: true }),
  'OtpErrorDark.dc.html': otpScreen(D, { error: true }),
  'Fork.dc.html': fork(L),
  'ForkIPad.dc.html': forkIPad(L),
  'CreateFamily.dc.html': createFamily(L),
  'CreateFamilySending.dc.html': createFamily(L, { busy: true }),
  'JoinCode.dc.html': joinCode(L),
  'JoinCodeDark.dc.html': joinCode(D),
  'JoinExpired.dc.html': joinCode(L, { state: 'expired' }),
  'JoinUsedUp.dc.html': joinCode(L, { state: 'usedup' }),
  'Pending.dc.html': pending(L),
  'InviteEmpty.dc.html': inviteScreen(L, { state: 'empty' }),
  'InviteGenerating.dc.html': inviteScreen(L, { state: 'busy' }),
  'InviteReady.dc.html': inviteScreen(L, { state: 'ready' }),
  'InviteApprovalOff.dc.html': inviteScreen(L, { state: 'approvalOff' }),
  'InviteApprovalOffDark.dc.html': inviteScreen(D, { state: 'approvalOff' }),
  'InviteRequests.dc.html': inviteRequests(L),
  'InviteRequestsMany.dc.html': inviteRequests(L, { many: true }),
  'StressType.dc.html': stressType(L),
  'StressCodeAX.dc.html': stressCodeAX(L),
  'StressContent.dc.html': stressContent(L),
  'Tokens.dc.html': tokensSheet(measured),
  'Notes.dc.html': notesSheet(),
};

for (const [name, src] of Object.entries(files)) writeFileSync(new URL(name, import.meta.url), src);

/* ─────────────────────────  CANVAS  ───────────────────────── */

const P = 390, PH = 844, GX = 110, GY = 190;
const row = (y, items) => {
  let x = 0; const out = [];
  for (const [file, w, hh] of items) { out.push({ file, x, y, w, h: hh || h(file) }); x += w + GX; }
  return out;
};

const artboards = [
  ...row(0, [['Main.dc.html', P], ['WelcomeDark.dc.html', P], ['WelcomeSending.dc.html', P], ['WelcomeIPad.dc.html', 1194, 834]]),
  ...row(PH + GY, [['Email.dc.html', P], ['EmailError.dc.html', P], ['Otp.dc.html', P], ['OtpError.dc.html', P], ['OtpErrorDark.dc.html', P]]),
  ...row(2 * (PH + GY) + 40, [['Fork.dc.html', P], ['ForkIPad.dc.html', 1194, 834], ['CreateFamily.dc.html', P], ['CreateFamilySending.dc.html', P]]),
  ...row(3 * (PH + GY) + 40, [['JoinCode.dc.html', P], ['JoinCodeDark.dc.html', P], ['JoinExpired.dc.html', P], ['JoinUsedUp.dc.html', P], ['Pending.dc.html', P]]),
  ...row(4 * (PH + GY) + 80, [['InviteEmpty.dc.html', P], ['InviteGenerating.dc.html', P], ['InviteReady.dc.html', P], ['InviteApprovalOff.dc.html', P], ['InviteApprovalOffDark.dc.html', P]]),
  ...row(5 * (PH + GY) + 80, [['InviteRequests.dc.html', P], ['InviteRequestsMany.dc.html', P]]),
].map((a) => ({ ...a, page: 'page-1' }));

const sheets = [
  { file: 'StressType.dc.html', x: 0, y: 0, w: P, h: h('StressType.dc.html'), page: 'page-2' },
  { file: 'StressCodeAX.dc.html', x: P + GX, y: 0, w: P, h: h('StressCodeAX.dc.html'), page: 'page-2' },
  { file: 'StressContent.dc.html', x: 2 * (P + GX), y: 0, w: 1290, h: h('StressContent.dc.html'), page: 'page-2' },
  { file: 'Tokens.dc.html', x: 2 * (P + GX), y: h('StressContent.dc.html') + GY, w: 980, h: h('Tokens.dc.html'), page: 'page-2' },
  { file: 'Notes.dc.html', x: 2 * (P + GX) + 980 + GX, y: h('StressContent.dc.html') + GY, w: 980, h: h('Notes.dc.html'), page: 'page-2' },
];

/* ── 畫布上的註記（第 4 輪 R8）──────────────────────────────────
   註記是 ios-dev 在畫布上第一眼看到的規格，第 3 輪它們沒跟著對帳，四則帶假話
   （capAlign 印 27／已否決的「開關移到最上面」／過期的呼吸帶單句／板高 1140）。
   現在規格數字一律內插，來源就是建畫面用的那一份：FIX／RULE／TY／INK／PHOTO／
   h() 板高／measured.json。<b>禁止手打規格數字</b>——歷史敘述（「第 2 輪是四個」）
   用中文數字，阿拉伯數字一律出自 ${}，由 verify 的 G20 掃描斷言。 */
const A = (v, f) => (v === undefined || v === null ? '（尚未量測）' : f(v));
const ty2 = (s) => `${/font-size:(\d+)px/.exec(s)[1]}/${/line-height:(\d+)px/.exec(s)[1]}`;
const fs1 = (s) => /font-size:(\d+)px/.exec(s)[1];
const padCol = (file, col) => (M.voids || []).find((v) => v.file === file && v.col === col);
const capPair = (M.h1 && M.h1.padPair) || [];

const canvas = {
  artboards: [...artboards, ...sheets],
  annotations: [
    {
      id: 'motif', x: 0, y: -320, w: 640, page: 'page-1',
      text: `母題：卡紙開窗。三種表面，一種一個意思 —— 凹進去＝可以填東西進去；浮起來＝可以按（兩層：${FIX.lip}pt 唇邊＋落影，沒有第三層 inset）；平印上去＝只能讀。凹的白名單有 ${A(M.insetUse, (u) => Object.keys(u).length)} 個角色（實測 ${A(M.insetTotal, (n) => n)} 個使用點全部落在裡面），全部印在 Tokens 板上；沒印在那張板上的例外就是 bug。`,
    },
    {
      id: 'ink-note', x: 700, y: -320, w: 620, page: 'page-1',
      text: `手寫字標「小芽」是全稿唯一的非系統線條，也是歡迎頁的溫度來源 —— 不是暖色底、不是粗體字。每一筆是中線貝茲＋起筆／收筆寬＋中段提按推出來的填色外框。三個使用點，字高各自不同：歡迎頁（手機 ${INK.phone}pt／iPad ${INK.pad}pt）、信件明細的「寄件人」（${INK.mail}pt）、建立家庭的即時預覽（${INK.preview}pt）—— 你在畫面上看到的筆跡，信箱裡會看到同一支。它刻意不壓在照片上（照片上的對比無法定義），在卡紙上實測 ${ratio(L.ink, L.board)}。`,
    },
    {
      id: 'photo-note', x: 1400, y: -320, w: 600, page: 'page-1',
      text: `照片位（未定稿，需要人決定）：歡迎頁上的是佔位圖，畫面上不再印任何規格註記 —— 攝影 brief 只在 Notes 板。焦點寫成影像座標比例 (${Math.round(PHOTO.fx * 100)}%, ${Math.round(PHOTO.fy * 100)}%)，object-position 由各斷點自己換算：${A(M.focus, (f) => f.map((x) => `${x.name} ${x.bw}×${x.bh} 只裁${x.axis} ${x.crop}px → ${x.pos}`).join('；'))}（另一軸寫什麼都沒有作用）。卡紙上緣壓過照片 ${FIX.seamPhone}pt、iPad ${FIX.seam}pt。要換的真照片條件：清晰（模糊＝沒有內容）、至少兩個人、看得到臉、主體落在三分線、有生活雜訊、沒有人背對鏡頭走開。合成人臉做不到可用品質，所以用佔位圖 —— 刻意的取捨，不是遺漏。`,
    },
    {
      id: 'void-note', x: 0, y: PH + GY - 300, w: 620, page: 'page-1',
      text: `呼吸帶是兩條規則，分工不是寬嚴兩版。①內容首末之間，任何一段連續無字無圖的縱向區間 ≤${RULE.pause}px —— 手機 iPad 同一條，沒有 iPad 例外；超過的必須掛 data-pause 寫出理由，掛不出理由就是版面破了（本稿 ${A(M.pauses, (p) => p.length)} 段掛牌、${A(M.pauseBad, (p) => p.length)} 段未掛牌，未掛牌一律 FAIL）。②內容末端到板底不設上限 —— 底部主按鈕貼安全區是 iOS 的正解（safeAreaInset）—— 但用到這個豁免的板（尾段 >${RULE.pause}px）要付對價：主按鈕中心得落在畫面 ${RULE.btnPct}% 以內。設計稿一律不畫假鍵盤、也不畫假狀態列。`,
    },
    {
      id: 'err-note', x: 700, y: PH + GY - 300, w: 620, page: 'page-1',
      text: `錯誤的幾何刻意脫離「可以按」的幾何：錯誤是一道獨立的 ${FIX.errBar}pt 酒紅線，離輸入面 ${SP.s}pt；可以按的唇邊是 ${FIX.lip}pt、貼著元件下緣。第 2 輪這兩者同寬同位置 —— 出錯的欄位長得像按鈕。全稿 ${A(M.errCount, (n) => n)} 道錯誤線出自同一個元件，實測與最近的唇邊距離最小 ${A(M.errGap, (g) => g)}px、重合 ${A(M.errOverlap, (n) => n)} 處。出錯時明細表收成一行，讓「欄位→錯誤句→下一步」擠成一群。`,
    },
    {
      id: 'ipad-note', x: 490, y: 2 * (PH + GY) + 40 - 300, w: 700, page: 'page-1',
      text: `iPad 兩板不再垂直置中：改三段式（上錨／中／下錨）。三岔路兩欄的第一行字同高 —— 左欄 H1（${ty2(TY.dPad)}）的 cap-height 對齊右欄首卡標題（${ty2(TY.h)}）的 cap-height，右欄整體下推 capAlign ${FIX.capAlign}pt，實測兩欄差 ${A(capPair.length === 2 ? capPair : null, (p) => Math.abs(p[0].y - p[1].y).toFixed(1))}px。兩欄「不齊底」是刻意的：說明欄排完就停，欄底剩 ${A(padCol('ForkIPad', 'desc'), (v) => v.trail)}px；選項欄剩 ${A(padCol('ForkIPad', 'options'), (v) => v.trail)}px —— 齊底不是目標，欄內不留大洞才是。死帶改成分欄量測：全幅量測會被欄位底色遮蔽，量不到欄內的空白（iPad 欄內最大 ${A(M.maxVoidPad, (n) => n)}px，${A(M.maxVoidPadFile, (s) => s)}，已掛 data-pause）。`,
    },
    {
      id: 'approval-note', x: 0, y: 4 * (PH + GY) + 80 - 300, w: 700, page: 'page-1',
      text: `兩段式審核。審核開關 ON 的軌道是芽綠（綠＝門禁開著、目前安全）—— 這是芽綠在全稿的第二個也是最後一個使用點，例外印在 Tokens 板。關掉時開關不移位：五張板（空／產生中／已產生／審核關閉／深色）的開關列都固定在票根正下方 y=${A(M.toggles, (g) => [...new Set(g.map((x) => x.top))].join('／'))} —— 空號碼位與票根是同一個外框，四態等高，所以位置是結構保證的，不是事後對齊。示警改用三件不移動版面的事：整列 ${FIX.lip}pt 唇邊換酒紅、補一行後果、撤掉陶土色主按鈕（沒有值得推薦的動作），「傳給家人」降成次要的「還是要傳給家人」。讓長輩重新找一次開關才是更糟的設計。`,
    },
    {
      id: 'queue-note', x: 0, y: 5 * (PH + GY) + 80 - 300, w: 700, page: 'page-1',
      text: `待核清單：等最久的排最上面並攤開，其餘收成一列（頭像＋名＋Email＋等多久＋「查看 ›」）。一次只有一張攤開 —— 陶土色因此每畫面仍然只有一個（第 2 輪是四個），而且順序天然就是「先處理等最久的」。這張板高 ${h('InviteRequestsMany.dc.html')}px：內容連同安全區放不下 ${PH} 才長高（＝這張會捲動），其餘待核板一律 ${PH}。`,
    },
    {
      id: 'ax-note', x: 0, y: -280, w: 480, page: 'page-2',
      text: `AX5（${Math.round(AX * 100)}%）：內文 ${fs1(TY.b)}pt → ${ax(+fs1(TY.b))}pt。版面不重排、只長高。按鈕裡的 icon 在 AX3 以上一律拿掉只留字；長 Email 在 @ 後面斷行，不切在字中間也不掉孤兒字元。`,
    },
    {
      id: 'axcode-note', x: P + GX, y: -280, w: 480, page: 'page-2',
      text: `邀請碼在 AX5：六格改兩排三格（不橫向壓縮）；票根的 ${fs1(TY.n1)}pt 不跟著放大 —— ${fs1(TY.n1)}×${AX} = ${ax(+fs1(TY.n1))}pt，一行排不下三碼，鎖在分格那一階（${fs1(TY.n2)}pt）的推導值 ${ax(+fs1(TY.n2))}pt 並拆成兩排。Notes 上寫了這兩條規則，這張板把它們畫出來。`,
    },
  ],
  pages: [
    { id: 'page-1', name: 'M1 流程' },
    { id: 'page-2', name: '壓力測試與交付' },
  ],
  launch: { view: 'canvas', page: 'page-1' },
};

writeFileSync(new URL('canvas.json', import.meta.url), JSON.stringify(canvas, null, 2));
console.log(`wrote ${Object.keys(files).length} artboards + canvas.json`);
