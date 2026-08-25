// 萌芽日記 Little Sprout — M1 (LS-17 登入 / LS-18 家庭) design canvas.
// tokens.mjs 是唯一 token 來源 -> 31 .dc.html artboards。Run: node build.mjs
import { writeFileSync, readFileSync, existsSync } from 'node:fs';
import {
  T, SP, FIX, TY, FONT, MONO, CAP, H1_GROUPS, H1_EXCLUDED, RULE, EXPIRED_RULE, AX, ax, AX4, ax4, hash12,
  GRAD_WHY, NO_GRAD_WHY, PERF_WHY, GRAD_KEYS, STUB_KEYS, LIGHT_KEYS, TIME_KEYS, CONTRAST, gradCss,
  PERF, perfMask, perfLip, PERF_TILE, JITTER, PHOTO_STOP, PHOTO_DIM, SCALE_DE, EXEMPT,
  TRACK, TEMP, TEMP_TOL, HUE_MIN, LIGHT_DH, TIME_DH, STUB_KNEE, STUB_AT_KNEE, STUB_USES, USES_TOTAL,
  lch, lchHex, dHue, dE, stubOf, hueDE, HUE_DE_MIN, INSET_KEYS, measStamp,
} from './tokens.mjs';
import { inkMark, sealMark, VB, cancelMark, CANCEL_COV } from './brush.mjs';
import * as Icon from './icon.mjs';
import * as Ink from './ink.mjs';

/* 字間白 vs 字內白（第 8 輪 D7-02／G33⑤）：板上那句話印的三個數，
   與 verify 的 G33⑤ 下判斷用的是**同一支** icon.mjs 的 counterStats。 */
const INK_GAP = Icon.counterStats({ d: Ink.LOCKUP.d, vb: Ink.LOCKUP.vb });

/* ── 給自驗管線的標記 ──────────────────────────────────
   verify/measure 不用猜元件是什麼，直接讀這些屬性 ——
   第 2 輪的三盞燈接錯線，就是因為檢查靠 grep 猜。 */
/* 「凹」的兩族在**一張表**上定義，S() 與 win() 都從這裡讀 ——
   標記與實際畫出來的深度因此不可能各說各話（G5 分兩條斷言驗它）。 */
const INSET_FAM = { field: 'fillable', cell: 'fillable', codeslot: 'fillable', tray: 'fillable', switchTrack: 'fillable',
  photo: 'mount', avatar: 'mount' };
const S = (kind, role = '') => ` data-s="${kind}"${role ? ` data-role="${role}"` : ''}${kind === 'win' && INSET_FAM[role] ? ` data-inset="${INSET_FAM[role]}"` : ''}`;
const MO = (motif) => ` data-m="${motif}"`;
const CTA = ' data-cta="1"';

/* 字標的五個尺寸只有這一份。Tokens 板印的也是這裡的值 ——
   規格與畫面同源，不可能再各說各話。
   h＝手寫「萌芽」的字高；sub＝系統字「日記」的字級（一律取自十階字級表）；
   gap＝兩者的間距（一律取自七階間距）。最小的兩個使用點從 20 提到 26：
   「萌」十四筆，20pt 高時筆與筆的空隙不到 1pt —— 對長輩就是一團墨。 */
const INK = {
  phone: { h: 51, sub: 17, gap: SP.m },
  pad: { h: 140, sub: 28, gap: SP.xl },
  sheet: { h: 34, sub: 13, gap: SP.s },
  preview: { h: 26, sub: 13, gap: SP.s },
  mail: { h: 26, sub: 13, gap: SP.s },
};
const BRAND = '萌芽日記';

/* 邀請碼：6 位英數，切 3＋3（對齊後端 LS-33 已上線的產生器）。
   全稿只有這一份樣本碼，畫面、票根、待核卡、AX 板都從這裡取 ——
   verify 的 G7 會逐張比對「畫面上的碼」與「唸法那一句」是同一組。
   字母都用大寫，而且樣本刻意避開 0/O、1/I/L：這組碼是要在電話裡唸給長輩聽的。 */
const CODE = 'K7M 2QD';
const CODE2 = 'R4T 8VN';
const SAY = `念的時候分兩組：「${CODE.split(' ')[0]}」、「${CODE.split(' ')[1]}」。`;

/* 待核清單的內容只有這一份 —— 畫面畫的、票根褪到第幾階、畫布註記上寫的人數，
   全部從這裡數出來。own＝這個人是用現在這組碼送出的（送出當下就用掉一次）。 */
const QUEUE = [
  { name: '林大衛', initial: '大', email: 'david.lin@example.com', waited: '一天', when: `昨天 21:40 用 ${CODE2} 送出`, own: false },
  { name: '王怡君', initial: '怡', email: 'yijun@gmail.com', waited: '9 小時', when: `今天 09:14 用 ${CODE2} 送出`, own: false },
  { name: 'Margaret Chen-Williamson', initial: 'M', email: 'margaret.chen.williamson@example.com', waited: '1 小時', own: true },
  { name: '陳美惠（台中外婆家的阿嬤）', initial: '惠', email: 'meihui.chen.1952@example-mail.com.tw', waited: '2 分鐘', own: true },
];
const QUEUE_OWN = QUEUE.filter((p) => p.own).length;

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

   這一稿三種表面各多一個判準，出處是同一個光源假設（淺色從上、深色從下）：
     凹  → 漸層上暗下亮（光被開窗上緣擋住）
     浮  → 漸層上亮下暗（凸面朝上受光）
     平印 → **沒有漸層**（只能讀的東西不接光）—— 沒有漸層就是它的識別
   例外只有一個，印在 Tokens 板上：票根的號碼帶有漸層，但那是**褪色**不是光。

   凹的白名單有八個角色，每一個都印在 Tokens 板上。verify 掃的是
   「使用點的 computed box-shadow」，不是 helper 定義 —— 第 2 輪就是掃錯地方。
------------------------------------------------------------------ */

/* 「凹」分兩族（第 2 輪 R5：白名單一路漂移，因為八個角色其實不是同一件事）：
     inset-fillable  這個洞是**空的**，等著被填 —— 輸入框、驗證碼格、空票根的號碼位、
                     登入托盤、開關的軌道。深一階：邊 1.5、內影 offset 4／blur 6。
     inset-mount     這個洞**已經有東西鑲在裡面**了 —— 照片窗、頭像、卡紙壓照片的接縫。
                     淺一階：邊 1／內影 offset 2.5／blur 4。鑲好的東西是齊平的，
                     不該還看得到一圈深槽。
   G5 因此拆成兩條斷言（各自的白名單），而且驗「fillable 的實測深度 > mount 的」——
   兩族不是兩個標籤，是兩個量得出來的深度。

   光的方向由 t.dir 決定，而且只由它決定（G24）：
     · bevelTop 永遠畫在上緣、bevelBot 永遠畫在下緣 —— 位置是位置；
     · 誰亮誰暗由**顏色**翻（淺色上暗下亮、深色上亮下暗）；
     · 柔影的 y 位移帶 dir 的正負號（淺色影子落在上緣、深色落在下緣）。
   第 2 輪深色的 bevelTop/bevelBot 沒有翻，所以同一個元件上有兩個互相牴觸的光源。

   outline:false ＝ 不畫四邊描邊。紙上壓出來的凹槽沒有輪廓線 —— 它的邊界是那道
   內影本身。第 2 輪 win() 一律畫 1px 四邊等寬描邊，依這一稿自己的幾何判準
   （四邊等寬＝描邊）那是在凹槽上加了一圈它不該有的線，凹被描邊蓋過去。
   輸入框與號碼位保留描邊：它們是**印在紙上的框**（表格線），不是純粹的凹槽。 */
const INSET_DEPTH = { fillable: { edge: 1.5, off: 4, blur: 6, spread: -3 }, mount: { edge: 1, off: 2.5, blur: 4, spread: -2 } };
const insetShadow = (t, fam = 'fillable') => {
  const d = INSET_DEPTH[fam];
  return `inset 0 ${d.edge}px 0 ${t.bevelTop}, inset 0 ${t.dir * d.off}px ${d.blur}px ${d.spread}px ${t.bevelSoft}, inset 0 -${d.edge}px 0 ${t.bevelBot}`;
};
const win = (t, { role = '', pad = '0', tone = 'board2', stroke = null, radius = 12, extra = '', outline = true, fill = null } = {}) =>
  `background:${fill || gradCss(t, tone === 'board3' ? 'win3' : 'win')};${outline ? `border:${FIX.hair}px solid ${stroke || t.edge};` : ''}border-radius:${typeof radius === 'number' ? `${radius}px` : radius};` +
  `box-shadow:${insetShadow(t, INSET_FAM[role] || 'fillable')};padding:${pad}${extra ? `;${extra}` : ''}`;

// 浮起只有兩層：3pt 唇邊（實體的邊）+ 落影。第 2 輪的 inset topLight 是第三層，
// 它讓「有 inset = 可以填」這條規則出現無聲的例外 —— 拿掉，規則就是真的。
// 底色一律走 gradCss()：浮起面的漸層方向與凹相反，兩者是同一個光源的兩面。
const raise = (t, { g, lip, radius = 14, extra = '' } = {}) =>
  `background:${gradCss(t, g)};border-radius:${radius}px;border-bottom:${FIX.lip}px solid ${lip};box-shadow:${t.lift}${extra ? `;${extra}` : ''}`;

// 平印：沒有 inset、沒有 lift、**沒有漸層**。tone 給的是實色。
const flat = (t, { pad = '0', radius = 12, tone = null, extra = '' } = {}) =>
  `${tone ? `background:${t[tone]};` : ''}border:${FIX.hair}px solid ${t.edge};border-radius:${radius}px;padding:${pad}${extra ? `;${extra}` : ''}`;

/* 摺邊（fold）：紙壓在照片上，那道裁邊。它**不是凹**（凹是洞），所以不在 inset 兩族裡 ——
   第 2 輪把它掛在 win/seam 底下，白名單因此多養了一個不是洞的角色。
   凹與凸的受光緣相反：洞裡看到的是**遠**壁受光，紙的裁邊是**近**光源那一緣受光。
   所以 fold 的上緣在淺色是亮的、在深色是暗的 —— 同一條規則，兩個結果。 */
const foldEdge = (t) => (t.dir > 0 ? t.bevelLit : t.bevelDark);
const noWt = (sty) => sty.replace(/;font-weight:\d+/, '');
const press = (t) => `text-shadow:${t.press}`;                  // 平印的字：壓進紙裡
const rule = (t) => `<div style="height:${FIX.hair}px;background:${t.edge}"></div>`;
// 騎縫線：唯一的方向例外，所以它自己掛牌（G23② 掃平印面上的漸層時，
// 只認 data-grad 標記過的 stub 與 perf 兩種；沒掛牌的一律 FAIL）。
/* 騎縫線（第 5 輪 D4-04：改成紙的形狀）。
   第 4 輪這裡是一條 1px 高、用橫向 repeating 背景漸層畫出來的虛線 ——
   一條**印在紙上**的虛線：撕開它不會有東西分開，AX5 下紙長大它不長大，
   而且它的畫材是 edge（我們用來畫「印上去的框」的那個顏色）。reviewer 判它是裝飾線。

   現在它是遮罩挖出來的洞（見 tokens.mjs 的 perfMask）：
     · 洞裡透出來的是台紙本身 —— 沒有任何一個像素是我們畫的
     · 齒距綁 ax()：AX 板上的紙變大，紙上的齒跟著變大
     · joined（票根，還沒撕）＝上下兩半各切自己那一緣的一半 → 合起來是完整的圓孔
       torn （托盤，撕下來的那一邊）＝只切一緣 → 半圓的扇貝邊
   perfCut() 回傳的是「屬性＋樣式片段」，貼在**要被切的那個元素**上。 */
/* 撕口 ＝ 遮罩挖掉的洞（不等距、不等大）＋ 沿著輪廓的 1px 斷面唇（第 6 輪 D5-06）。
   兩者都由同一個 edge 決定方向，唇的顏色由 dir 決定 —— 沒有第二個光源。 */
const perfCut = (kind, edge, pitch = PERF.pitch, th = null) =>
  ({ attr: ` data-perf="${kind}-${edge[0]}"`, css: `${perfMask(edge, pitch)};${perfLip(th || T.light, edge)}` });

/* ─────────────────────────  控制項  ───────────────────────── */

/* 載入中的按鈕不是另一個元件，是同一顆按鈕就地轉態 —— 所以走同一個函式：
   圖示位換成轉圈、底色換 ctaBusy、唇邊與底同色（＝這一刻按不動）。
   手刻第二份的話，兩個狀態會差幾個 px，畫面就會在轉態時抖一下。 */
/* 載入中不是另一顆按鈕，是同一顆就地轉態 —— 所以走同一個函式。
   轉態時做兩件事，兩件都是「按不動」的意思：
     ① 漸層整條拿掉，換成實色（按不動的東西不反光）
     ② 唇邊與底同色（那道唇邊就是「可以按」的那個實體邊）
   手刻第二份的話，兩個狀態會差幾個 px，畫面就會在轉態時抖一下。 */
const btn = (t, label, { icon = '', tone = 'primary', busy = false } = {}) => {
  const primary = tone === 'primary';
  const fill = primary ? t.ctaBusy : t.board3;
  const lip = busy ? fill : (primary ? t.ctaDeep : t.edge);
  const fg = primary ? t.onCta : t.ink;
  const mark = busy ? spinner(t, fg) : icon;
  const surface = busy
    ? `background:${fill};border-radius:14px;border-bottom:${FIX.lip}px solid ${lip};box-shadow:${t.lift}`
    : raise(t, { g: primary ? 'cta' : 'face', lip });
  return `<div${S('raise', 'button')}${primary ? CTA : ''} style="${surface};min-height:${FIX.button}px;display:flex;align-items:center;justify-content:center;gap:${SP.m}px;padding:0 ${SP.l}px;color:${fg}">
      ${mark ? `<span style="display:flex;flex:none">${mark}</span>` : ''}
      <span style="${TY.bs};color:${fg};text-align:center">${label}</span>
    </div>`;
};

/* 兩顆第三方品牌鍵。外觀由對方的規範決定 —— 實色底、指定的字色與描邊、標誌不可改色，
   所以它們是全稿唯二**沒有漸層、也沒有唇邊**的浮起面（理由印在 Tokens 板上）。
   我們只借幾何：同一個 ${FIX.button}pt 最小高、同一個 14 圓角、同一組間距、同一個命中盒。

   第 1 輪 R6 的裁定接受了：上一稿讓 Google 的描邊色兼差當唇邊（上緣 1px、下緣 3px），
   宣稱那是「融入」；實際上那是借人家的描邊色湊出我們的形，而且把 1px 的規範改成 3px
   本來就是改外觀。這一輪兩顆鍵都**完全不動**：Apple 沒有唇邊，Google 是規範指定的
   1px 均勻描邊。它們是怎麼被收編進這套語言的？不靠改它們 —— 靠**改它們坐的那個面**
   （下面的台紙托盤）。改自己的東西，不改別人的東西。

   第 1 輪 R7：AX5 的版本不是自己把標誌堆到字上面（那也是改外觀），
   是換成官方的**短標題**「登入」，版式一律維持橫排。 */
const APPLE_MARK = '<path d="M14.02 10.6c.02-2.2 1.8-3.26 1.88-3.31-1.02-1.5-2.62-1.7-3.18-1.72-1.35-.14-2.64.79-3.33.79-.69 0-1.75-.77-2.87-.75-1.48.02-2.84.86-3.6 2.18-1.53 2.66-.39 6.6 1.1 8.76.73 1.06 1.6 2.25 2.74 2.2 1.1-.04 1.51-.71 2.84-.71 1.32 0 1.7.71 2.86.69 1.18-.02 1.93-1.08 2.65-2.14.84-1.23 1.18-2.42 1.2-2.48-.03-.01-2.3-.88-2.29-3.51ZM11.85 4.16c.6-.74 1.01-1.76.9-2.78-.87.04-1.93.58-2.56 1.31-.56.65-1.06 1.69-.93 2.69.97.07 1.97-.49 2.59-1.22Z"/>';
/* ── 登入鍵組的標籤：三階，而且**三顆各有各的三階**（第 6 輪 D5-01）──────────
   第 5 輪這張表只寫給兩顆品牌鍵，我們自己那顆 Email 沒有進來 —— 於是它在 AX5
   跟著掉成「登入」，三顆鍵的第三顆變成一個沒有商標、沒有 aria-label、
   讀螢幕唸出來就是「登入」二字的按鈕。**身分歸零**。

   第三顆不換短標題的理由是量出來的，不是偏好：Apple 與 Google 的短標題是
   **它們的規範給的**（窄空間用「登入」，品牌詞由商標承擔）；我們沒有商標可以承擔，
   而且我們的鍵沒有標誌佔位，AX5 下留給標籤的寬度反而是三顆裡最寬的。
   「Email 登入」在那一階需要的寬度 vs 那顆鍵真正剩下的寬度，兩個數都印在 StressLoginAX 板上。

     階     Apple／Google                    Email（我們自己的）
     full   透過 X 登入                       用 Email 登入
     brand  X 登入（虛詞丟掉，品牌詞留著）      Email 登入
     short  登入（官方短標題＋aria-label）      Email 登入（放得下就不縮）

   無障礙名稱的規則（WCAG 2.5.3 Label in Name）：**可見文字必須是無障礙名稱的一部分**。
   所以 aria-label 只在 short 那一階出現（可見的只剩「登入」，名稱補上品牌詞成為
   「Apple 登入」——包含可見文字）；其餘兩階沒有 aria-label，可見文字自己就是名稱。
   第 5 輪三顆都掛著 `使用 X 帳號登入`，在 AX4（可見「Apple 登入」）反而**違反** 2.5.3 ——
   語音控制的人唸得出畫面上的字卻按不到那顆鍵。G32⑤ 逐顆驗這件事。 */
const SIGNIN_LABEL = {
  apple: { full: '透過 Apple 登入', brand: 'Apple 登入', short: '登入' },
  google: { full: '透過 Google 登入', brand: 'Google 登入', short: '登入' },
  email: { full: '用 Email 登入', brand: 'Email 登入', short: 'Email 登入' },
};
const signInLabel = (who, title) => SIGNIN_LABEL[who][title || 'full'];
/* short 那一階（也只有那一階）補無障礙名稱：品牌詞 ＋ 可見文字。 */
const signInAria = (who, title) => (title === 'short' && who !== 'email'
  ? ` aria-label="${who === 'apple' ? 'Apple' : 'Google'} ${signInLabel(who, title)}"` : '');
const btnApple = (t, size = null) => {
  const s = size || { label: TY.bs, mark: [20, 24], h: FIX.button };
  const pad = s.pad || SP.l;
  const title = s.title || 'full';
  return `<div${S('raise', 'button')} data-brand="apple" data-signin="apple" data-title="${title}" role="button"${signInAria('apple', title)} style="background:${t.appleBg};border-radius:14px;min-height:${s.h}px;display:flex;align-items:center;justify-content:center;gap:${SP.s}px;padding:0 ${pad}px;color:${t.appleFg}">
      <svg width="${s.mark[0]}" height="${s.mark[1]}" viewBox="0 0 17 20" fill="${t.appleFg}" aria-hidden="true" style="flex:none">${APPLE_MARK}</svg>
      <span data-signin-label="1" style="${s.label};color:${t.appleFg};text-align:center;white-space:nowrap">${signInLabel('apple', title)}</span>
    </div>`;
};

// 官方四色 G。它是商標不是裝飾性 icon，所以在 AX 放大時**不可以拿掉**，只能跟著長大。
const gMark = (n) => `<svg width="${n}" height="${n}" viewBox="0 0 48 48" aria-hidden="true" style="flex:none">
     <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5Z"/>
     <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65Z"/>
     <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19Z"/>
     <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48Z"/>
   </svg>`;

const btnGoogle = (t, size = null) => {
  const s = size || { label: TY.bs, mark: 20, h: FIX.button };
  const pad = s.pad || SP.l;
  const title = s.title || 'full';
  return `<div${S('raise', 'button')} data-brand="google" data-signin="google" data-title="${title}" role="button"${signInAria('google', title)} style="background:${t.googleBg};border-radius:14px;border:${FIX.hair}px solid ${t.googleLine};min-height:${s.h}px;display:flex;align-items:center;justify-content:center;gap:${SP.m}px;padding:0 ${pad}px">
      ${gMark(s.mark)}
      <span data-signin-label="1" style="${s.label};color:${t.googleFg};text-align:center;white-space:nowrap">${signInLabel('google', title)}</span>
    </div>`;
};

/* 第三顆：我們自己的。它**不是**品牌鍵（沒有 data-brand，所以 G25「品牌鍵不接光」
   不管它 —— 它本來就該接我們的光），但它**是**登入鍵組的一員（data-signin），
   所以 G32 的每一條都咬得到它。第 5 輪它兩樣都不是，於是誰都沒在看它。 */
const btnEmail = (t, size = null) => {
  const s = size || { label: TY.bs, mark: 20, h: FIX.button };
  const pad = s.pad || SP.m;
  const title = s.title || 'full';
  return `<div${S('raise', 'button')} data-signin="email" data-title="${title}" role="button" style="${raise(t, { g: 'face', lip: t.edge })};min-height:${s.h}px;display:flex;align-items:center;justify-content:center;gap:${SP.m}px;padding:0 ${pad}px;color:${t.ink}">
      ${title === 'full' ? `<span style="display:flex;flex:none">${I.mail}</span>` : ''}
      <span data-signin-label="1" style="${s.label};color:${t.ink};text-align:center;white-space:nowrap">${signInLabel('email', title)}</span>
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

const errBar = (t) => `<div data-err="bar"${MO('errbar')} style="height:${FIX.errBar}px;border-radius:1px;background:${t.pen}"></div>`;

const field = (t, { label, value = '', placeholder = '', state = 'idle', hint = '' }) => {
  const border = state === 'focus' ? `border:2px solid ${t.ink}` : `border:${FIX.hair}px solid ${t.edge}`;
  const tone = gradCss(t, state === 'disabled' ? 'win3' : 'win');
  const txt = value
    ? `<span style="${TY.b};color:${t.ink};overflow-wrap:anywhere">${value}</span>`
    : `<span style="${TY.b};color:${t.ink2}">${placeholder}</span>`;
  return `<div style="display:flex;flex-direction:column;gap:${SP.m}px">
      <span style="${TY.l};color:${t.ink2}">${label}</span>
      <div style="display:flex;flex-direction:column;gap:${SP.s}px">
        <div${S('win', 'field')} style="background:${tone};${border};border-radius:12px;box-shadow:${insetShadow(t)};min-height:${FIX.button}px;display:flex;align-items:center;padding:0 ${SP.l}px">${txt}</div>
        ${state === 'error' ? errBar(t) : ''}
      </div>
      ${hint ? `<span style="${TY.cap};color:${t.ink2}">${hint}</span>` : ''}
    </div>`;
};

const errorLine = (t, msg) => `<span style="${TY.bs};color:${t.pen}">${msg}</span>`;

/* 六位碼的第一種正典：3＋3 分格，36pt 等寬。信裡的驗證碼（純數字）與邀請碼（英數）
   共用同一個元件 —— 兩者長度相同、分組相同，長輩只要學一次。

   第 5 輪 D4-13：第 4 輪邀請碼那一版在兩組中間印了一個「、」（理由是「它要唸出來」）。
   撤掉。理由是這一稿自己的規則：**印刷品用間距分組，不用標點** ——
   票根上的兩組號碼中間一個字元都沒有（G7 已經在驗那件事），輸入格卻多一個頓號，
   等於同一個東西在同一條流程裡有兩種分組寫法。而且「唸出來」這件事本來就由
   下面那句唸法句承擔（「念的時候分兩組：…」），不需要在格子中間再放一個標點。
   兩種碼從此完全同一個版式：24（SP.xl）pt 的組間距，沒有標點。 */
const codeCells = (t, digits, { caret = -1, error = false } = {}) => {
  const cell = (d, i) => `<div${S('win', 'cell')}${MO('cells')} style="flex:1;background:${gradCss(t, 'win')};border:${i === caret ? 2 : FIX.hair}px solid ${i === caret ? t.ink : t.edge};border-radius:12px;box-shadow:${insetShadow(t)};height:${FIX.cell}px;display:flex;align-items:center;justify-content:center">
      <span style="${TY.n2};color:${t.ink}">${d || ''}</span></div>`;
  const group = (from) => `<div data-group="${from / 3 + 1}" style="display:flex;gap:${SP.s}px;flex:1">${digits.slice(from, from + 3).map((d, j) => cell(d, from + j)).join('')}</div>`;
  return `<div style="display:flex;flex-direction:column;gap:${SP.s}px">
      <div data-cellgroups="1" style="display:flex;gap:${SP.xl}px">${group(0)}${group(3)}</div>
      ${error ? errBar(t) : ''}
    </div>`;
};

/* ─────────────────────  平印：只能讀的東西  ───────────────────── */

/* ── 版式的三階寬度（第 5 輪 D4-06）────────────────────────────────
   第 4 輪的判定：「156 個區塊只有 6 種寬度、72% 是同一個 342px —— 材質做滿、空間沒做。
   歡迎頁的出血自己證明了破欄有效，然後一次都沒有再用。」

   所以版式自己也要有一個階，而且階要有意思，不是為了長得不一樣：
     出血 bleed（板寬）    只給**拿在手上的實體**：票根、以及托盤（從我們的紙上撕下來的那一塊）
     欄   col  （版心）    給**可以操作的東西**：輸入框、按鈕、選項卡、待核卡片
     旁註 note （版心−2×${'SP.xl'}）給**引用與說明**：明細表、說明框、提示句
   一句話：主體物件與幫助文字不得同寬、也不得同皮。
   旁註因此也撤掉了它的皮 —— 說明文字不是另一張紙，它就印在台紙上，
   靠一道 ${'FIX.hair'}px 的邊線與縮排表示身分（印刷品的旁註本來就是這樣做的）。 */
const NOTE_IN = SP.xl;
const noteW = ` data-w="note" style="margin-left:${NOTE_IN}px;margin-right:${NOTE_IN}px;`;

// 明細表：一格一格印在紙上。Pending、信件預覽、號碼用途都用同一個元件。
const table = (t, rows, { head = null, radius = 14 } = {}) => `
  <div${S('flat')}${noteW}${flat(t, { pad: `${SP.l}px`, radius })};display:flex;flex-direction:column;gap:${SP.m}px">
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
  <div${S('flat')}${noteW}${flat(t, { pad: `${SP.m}px ${SP.l}px` })}">
    <span style="${TY.b};color:${t.ink2};${press(t)}">${text}</span>
  </div>`;

/* 說明框（第 5 輪 D4-06：撤皮）。第 4 輪它是一張與主體同寬、同一種皮的平印卡 ——
   「主體物件與幫助文字同寬同皮」，讀者因此分不出哪一塊是要做的事、哪一塊是旁邊的解釋。
   現在它**沒有皮**：說明文字直接印在台紙上，靠縮排與一道邊線表示身分 ——
   印刷品的旁註本來就是這樣做的，而且這樣一來「平印的皮」重新只代表一件事：
   那是一張真的印刷品（票根、明細表、警語條），不是一段幫助文字。 */
/* 旁註（沒有圖示的那一種）：說明「怎麼用、接下來會發生什麼」的句子。
   與 noteBox 同一階、同一個處理（縮排＋左側邊線），差別只有它沒有圖示。
   **警告不用這一階**：後果的句子（「號碼給誰就等於邀請誰」）留在欄寬 ——
   旁註是「可以晚點再讀」的東西，警告不是。 */
const hint = (t, text, { size = TY.cap } = {}) => `
  <div data-w="note" style="margin-left:${NOTE_IN}px;margin-right:${NOTE_IN}px;padding:${SP.s}px 0 ${SP.s}px ${SP.m}px;border-left:${FIX.hair}px solid ${t.edge}">
    <span style="${size};color:${t.ink2};${press(t)}">${text}</span>
  </div>`;

const noteBox = (t, icon, text, { size = TY.b, inset = true } = {}) => `
  <div${inset ? ' data-w="note"' : ''} style="${inset ? `margin-left:${NOTE_IN}px;margin-right:${NOTE_IN}px;` : ''}padding:${SP.m}px 0 ${SP.m}px ${SP.m}px;border-left:${FIX.hair}px solid ${t.edge};display:flex;gap:${SP.m}px;align-items:flex-start">
    <span style="display:flex;flex:none;color:${t.ink2}">${icon}</span>
    <span style="${size};color:${t.ink2};${press(t)}">${text}</span>
  </div>`;

/* 六位碼的第二種正典：票根，60pt。下半永遠印著期限與剩餘次數 ——
   號碼不會單獨出現在任何地方。

   為什麼是票根：這張東西的原型是**照相館的取件存根**。上面一組號碼、下面一行期限與
   次數、中間一道騎縫線 —— 拿著存根才領得到照片，這正是邀請碼在做的事。

   還沒產生、產生中、已產生，是同一張票根的三個狀態：外框、數字帶高度（codeLine
   ＝60pt 的行高）、騎縫線、下緣帶完全一樣，所以三張畫面的高度一模一樣 ——
   開關列因此可以固定在票根正下方，不會因為狀態不同而跳位（第 3 輪 R4）。
   已產生＝平印（只能讀）；還沒產生＝凹（可以填的號碼位，白名單上的 codeslot）。 */
/* 票根是**出血**的（第 5 輪 D4-06）。第 4 輪整份稿子 156 個區塊只有 6 種寬度、
   72% 是同一個 342px —— reviewer 的判定是「材質做滿、空間沒做」。這一稿的版式有
   三階寬度（出血／欄／旁註），而票根拿的是最上面那一階：它是全 app 唯一一個
   「拿在手上的實體」，理當是唯一比版心寬的東西 —— 印刷品是從整張紙上裁下來的，
   不會乖乖坐在版心裡。出血因此不是排版效果，是這張票的物理：它跑出版心、
   左右兩緣被打孔機咬掉一口（那兩個半圓缺口現在真的在螢幕邊上）。
   左右不留圓角：紙從螢幕邊緣繼續延伸出去，圓角會把它變回一張卡片。 */
const ticketShell = (t, { surface, motif = '', label = '邀 請 碼', main, foot, fade = null, pitch = PERF.pitch }) => {
  const up = perfCut('joined', 'bottom', pitch, t), lo = perfCut('joined', 'top', pitch, t);
  return `
  <div${surface.mark}${motif} data-w="bleed" style="${surface.css};overflow:hidden;margin:0 -${FIX.gutter}px">
    <div${up.attr}${fade ? ` data-grad="${fade}" data-band="code"` : ''} style="${fade ? `background:${gradCss(t, fade)};` : ''}${up.css};padding:${SP.xl}px;display:flex;flex-direction:column;align-items:center;gap:${SP.m}px">
      <span style="${TY.cap};color:${t.ink2};letter-spacing:.16em;${press(t)}">${label}</span>
      <div style="height:${FIX.codeLine}px;display:flex;align-items:center;justify-content:center;gap:${SP.m}px">${main}</div>
    </div>
    <div${lo.attr} style="${lo.css};padding:${SP.m}px ${SP.xl}px;display:flex;flex-direction:column;gap:${SP.xs}px;background:${t.board3}">${foot}</div>
  </div>`;
};

/* ── 三格刻度：把「褪色」變成一張畫面裡讀得出來的東西（第 3 輪 R1）──────────
   第 2 輪的褪色階是真的：號碼帶是染料（會褪）、號碼是碳墨（不褪）。但 reviewer 量出
   它在真畫面上**幾乎沒有被使用** —— 六張產品板裡四張畫的是全尺寸的「3 次」，
   唯二畫出不同階的兩張把票根壓成 51px 的細帶。褪色是**比較**才成立的概念：
   一張畫面上只有一階，遮住說明文字就講不出來。

   所以票根自己帶三格刻度：三格 ＝ 三次。用掉的那一格褪成乾淨的紙（stub0），
   還沒用的維持剛印好的染料（stub3）。它不是圖例、不是進度條 —— 它就是這張票根
   本來就印在上面的次數欄，而且用的是**同一支褪色階的兩端**。
   結果是：任何一張有票根的畫面，單獨看都讀得出「三格用掉一格」。
   空票根（還沒產生號碼）的三格是**空白的**：沒印過的東西不會褪 ——
   這與「褪完了就沒有褪色的方向了」是同一句話的兩端。 */
/* 第 5 輪 D4-01：第 4 輪的三格刻度**沒有達成它的目的**。reviewer 遮住說明文字實測：
   五個狀態裡有三個狀態的刻度逐格顏色完全一樣（ΔE=0）—— 因為「還沒用的格」永遠畫
   stub3、「用掉的格」永遠畫 stub0，**號碼帶自己走到第幾階從來沒有出現在刻度上**。
   刻度只用了褪色階的兩端，中間兩階（正是「用過幾次」的資訊）不在刻度上。

   兩件事一起修，兩件都是這張票根本來就有的東西：
     ① 還沒用的格改畫**當前階**（與號碼帶同一支漸層）—— 刻度與帶子從此是同一件事
        的兩種說法（實測 ΔE→0），而不是一個圖例。
     ② 用掉的格蓋一道**朱筆銷記**：照相館在存根上劃掉用過的那一格。
        它走的是 brush.mjs 的 stroke() 模型（有起筆、收筆、提按的真筆跡），不是 CSS 畫的叉；
        但它**不是字標那支筆**——字標是蠟筆（孩子的手），這一道是照相館的人拿紅筆劃的。
        兩支筆本來就不該是同一支。
   結果：遮住文字，四個狀態的刻度逐格對位比，相鄰兩態至少有一格 ΔE ≥ SCALE_DE.adj，
   剛印好↔用完了三格**每一格**都 ≥ SCALE_DE.ends（G29 逐格量、逐態比）。 */
const SCALE_W = 34, SCALE_H = 20;
const stubScale = (t, { uses = null, big = false } = {}) => {
  // AX 板上紙變大，紙上印的格子跟著變大（與騎縫線的齒距同一條規則）
  const W = big ? ax(SCALE_W) : SCALE_W, H = big ? ax(SCALE_H) : SCALE_H, gap = big ? ax(SP.xs) : SP.xs;
  const cell = (i) => {
    const state = uses === null ? 'blank' : (i <= USES_TOTAL - uses ? 'spent' : 'left');
    const g = state === 'blank' ? null : (state === 'spent' ? stubOf(0) : stubOf(uses));
    return `<span data-cell="${state}"${g ? ` data-grad="${g}"` : ''} style="position:relative;width:${W}px;height:${H}px;border-radius:2px;border:${FIX.hair}px solid ${t.edge};background:${g ? gradCss(t, g) : 'transparent'}">${state === 'spent' ? cancelMark(t.pen) : ''}</span>`;
  };
  return `<span data-scale="${uses === null ? 'blank' : uses}" style="display:inline-flex;align-items:center;gap:${gap}px;flex:none">
      ${[1, 2, 3].map(cell).join('')}
    </span>`;
};

/* 號碼帶是全稿唯一帶「褪色」漸層的表面，而且**褪色階就是剩餘次數**：
   號碼帶是印上去的染料（會褪），號碼本身是碳墨（不會褪，四階實測全部 12:1 以上）。
   每被用掉一次就往「乾淨的紙」褪一階 —— 這是這一稿唯一只有「褪色相紙」這個概念
   才長得出來的東西：卡紙的語言裡，一張卡片不會因為被用過而變淡。
   下緣印的「還可以用 N 次」與 data-grad 的階數是同一個 uses，G7 逐板對帳。 */
const usesLine = (uses) => (uses > 0 ? `還可以用 ${uses} 次` : '這組號碼用完了');
const ticket = (t, { code = CODE, uses = USES_TOTAL } = {}) => ticketShell(t, {
  surface: { mark: S('flat'), css: flat(t, { pad: '0', radius: 0 }) },
  motif: MO('ticket'),
  fade: stubOf(uses),
  main: `<span style="display:flex;gap:${SP.xl}px;${TY.n1};color:${t.ink};${press(t)}">${code.split(' ').map((g) => `<span>${g}</span>`).join('')}</span>`,
  /* 刻度與那句話排在**同一條基線上**，中間只隔一個 ${SP.s}pt —— 三格與「還可以用 N 次」
     是同一件事的兩種說法，分兩行排的話眼睛不會把它們接起來（第一版就是分兩行，
     結果三格讀起來像三個沒有意義的小方塊）。 */
  foot: `<span style="display:inline-flex;align-items:center;gap:${SP.s}px">${stubScale(t, { uses })}<span style="${TY.bs};color:${t.ink};${press(t)};white-space:nowrap">${usesLine(uses)}</span></span>
         <span style="${TY.cap};color:${t.ink2};${press(t)}">${uses > 0 ? '有效到 8 月 30 日' : '產生新的一組就會換一個號碼'}</span>`,
});

// 空的票根：同一張票，只是還沒印上號碼。凹＝可以填。
// 它**沒有**褪色漸層 —— 沒印過的東西不會褪色。四態等高，差別只在表面。
const ticketSlot = (t, { busy = false } = {}) => ticketShell(t, {
  surface: { mark: S('win', 'codeslot'), css: win(t, { role: 'codeslot', pad: '0', radius: 0 }) },
  main: `${busy ? spinner(t, t.ink2) : `<span style="display:flex;color:${t.ink2}">${I.key}</span>`}
         <span style="${TY.bs};color:${t.ink}">${busy ? '正在產生號碼…' : '號碼會出現在這裡'}</span>`,
  foot: `<span style="display:inline-flex;align-items:center;gap:${SP.s}px">${stubScale(t)}<span style="${TY.bs};color:${t.ink2};white-space:nowrap">一組可以用 ${USES_TOTAL} 次</span></span>
         <span style="${TY.cap};color:${t.ink2}">期限和次數，產生之後印在這裡</span>`,
});

/* 第 2 輪這裡是 ticketLine()：有待核清單時票根降成一行 51px 的細帶。
   reviewer 的判定：這一稿唯二畫得出「不同褪色階」的兩張板，正好是把票根壓扁的那兩張 ——
   抬標的元素被壓成一條看不出階的細帶，褪色因此在真畫面上等於沒有發生。
   本輪撤掉細帶：**兩張待核板用的就是同一張票根**（號碼帶全高、三格刻度都在）。
   代價是這兩張板變長、要捲動 —— 接受，因為「有人在等」的畫面本來就是清單畫面；
   號碼帶是這張畫面上唯一會告訴你「還剩幾次」的東西，把它壓扁等於把它拿掉。 */

/* ─────────────────────  浮起：可以按的東西  ───────────────────── */

/* 審核開關：整列可按，所以是浮起的。
   ON 的軌道是芽綠 —— 綠＝門禁開著、目前是安全的。在粉的世界裡綠是補色，
   一出現就搶眼；正因為如此，全稿只給它兩個使用點，例外印在 Tokens 板上。
   OFF：唇邊換朱（不是再加一圈描邊 —— 那會變成第三個紅），軌道凹回去，
   並且補一張警語條 —— 條子的底是台紙最亮的那一階（lit），因為它是這張畫面
   此刻唯一該讀的一句。位置完全不動。 */
const toggleRow = (t, { on = true } = {}) => {
  /* 第 2 輪 reviewer 的判定：「OFF 把手對軌道 1.04:1 —— 全稿唯一會出事的可用性缺陷。」
     這一輪整顆重做，三件事：

     ① **軌道一直是同一個槽**。上一稿 ON 是浮起的（box-shadow: lift）、OFF 是凹的 ——
        同一個實體在兩個狀態裡從凸變成凹，物理上講不通。現在兩個狀態都是
        凹的軌道（inset-fillable 那一族，因為它就是「等著被填」的槽），
        差別只有**槽裡填什麼**：ON 填芽綠、OFF 空著（well 那支漸層）。
     ② **把手是同一個零件，所以永遠是同一個顏色**（四種組合都是白的）。
        這是照官方 kit 的解剖：Light/Dark × ON/OFF 四顆，把手全部是白的。
        上一稿 ON 用 onSprout、OFF 用 board3 —— 一顆會變色的把手是兩個零件。
     ③ **行程看得出來**：把手中心在兩端相差 ${FIX.switchW - FIX.switchKnob - FIX.knob * 2}px，
        而且 OFF 那一端露出來的槽是全畫面最深的東西（實測對比印在 Tokens 板上，
        硬門檻 3:1；ON 端露出來的是芽綠）。長輩不必辨認把手上的細節，
        只要看「亮的那一顆停在哪一邊、另一邊露出什麼顏色」。
     ON 的軌道刻意仍然沒有唇邊：唇邊是「可以按的實體下緣」，畫在膠囊軌道上會壓到把手行程。 */
  const knob = `<div data-role="knob" style="width:${FIX.switchKnob}px;height:${FIX.switchKnob}px;border-radius:50%;background:${t.knob}"></div>`;
  const track = (fill, justify) =>
    `<div${S('win', 'switchTrack')}${MO('switch')} data-on="${on ? 1 : 0}" style="flex:none;width:${FIX.switchW}px;height:${FIX.switchH}px;${win(t, { role: 'switchTrack', radius: '999px', outline: false, fill, pad: `${FIX.knob}px` })};display:flex;align-items:center;justify-content:${justify}">${knob}</div>`;
  const sw = on ? track(t.sprout, 'flex-end') : track(gradCss(t, 'well'), 'flex-start');
  return `<div${S('raise', 'toggleRow')} style="${raise(t, { g: 'face', lip: on ? t.edge : t.pen })};padding:${SP.l}px;display:flex;flex-direction:column;gap:${SP.m}px">
      <div style="display:flex;gap:${SP.l}px;align-items:flex-start">
        <div style="flex-grow:1;display:flex;flex-direction:column;gap:${SP.xs}px">
          <span style="${TY.bs};color:${t.ink}">新成員要我核准才能進來</span>
          <span style="${TY.cap};color:${t.ink2}">${on ? '關掉的話，只要輸入正確的碼就直接進家庭。' : '現在是關掉的。'}</span>
        </div>
        ${sw}
      </div>
      ${on ? '' : `<div${S('flat')} data-role="alertStrip" style="${flat(t, { pad: `${SP.m}px ${SP.l}px`, tone: 'lit' })}">
           <span style="${TY.bs};color:${t.pen};${press(t)}">任何拿到號碼的人都能直接看到照片。</span></div>`}
    </div>`;
};

/* ─────────────────────────  SHELL  ───────────────────────── */

const helmet = (t) => `<style>
    /* ── Little Sprout M1 tokens（值即實作值，ios-dev 直接抄）── */
    :root{
      --ls-board:${t.board}; --ls-board-2:${t.board2}; --ls-board-3:${t.board3}; --ls-lit:${t.lit};
      --ls-ink:${t.ink}; --ls-ink-2:${t.ink2};
      --ls-cta:${t.cta}; --ls-cta-deep:${t.ctaDeep}; --ls-cta-busy:${t.ctaBusy}; --ls-on-cta:${t.onCta};
      --ls-pen:${t.pen}; --ls-sprout:${t.sprout}; --ls-edge:${t.edge}; --ls-google-line:${t.googleLine};
      /* 漸層：兩端各自是 token，寫法只有一種（180deg，上→下）。 */
${GRAD_KEYS.map((k) => `      --ls-g-${k}:${gradCss(t, k)};`).join('\n')}
      /* 光從哪一邊來（+1 上、−1 下）。G24 讀它決定每一個表面該長什麼樣，
         所以「這一張板是哪一種光」不再靠檔名猜。 */
      --ls-dir:${t.dir};
      --ls-r-window:12px; --ls-r-control:14px; --ls-r-card:18px;
      --ls-sp-1:4px; --ls-sp-2:8px; --ls-sp-3:12px; --ls-sp-4:16px;
      --ls-sp-5:24px; --ls-sp-6:32px; --ls-tap-min:44px;
      /* 過期句規線（第 10 輪 D9-02）：粗細與垂直位置，見 tokens.mjs 的 EXPIRED_RULE。 */
      --ls-expired-rule-w:${EXPIRED_RULE.w}px; --ls-expired-rule-y:${EXPIRED_RULE.y}%;
    }
    *,*::before,*::after{box-sizing:border-box}
    body{margin:0;font-family:${FONT};-webkit-font-smoothing:antialiased;background:${t.board};color:${t.ink};text-wrap:pretty}
    a{color:${t.ink};text-decoration:underline} a:hover{color:${t.cta}}
    /* 紙的紋理：卡紙不是純色。全稿唯一用到透明度的地方。 */
    .g::after{content:"";position:absolute;inset:0;pointer-events:none;opacity:${t.grain};
      background-image:url("data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='140' height='140'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix type='saturate' values='0'/></filter><rect width='140' height='140' filter='url(%23n)'/></svg>");
      mix-blend-mode:multiply}
    /* 過期句劃掉：不用瀏覽器內建 line-through（落在 CJK 橫畫帶，見 tokens.mjs 的
       EXPIRED_RULE 註解）。**不能用 background-image 畫這條線**——量測 probe
       的對比／漸層清冊是逐元素走 backgroundColor／backgroundImage 祖先鏈算的
       （見 _probe.html 的 bgAt()／onGrad()），畫在 <s> 自己的背景上，這條規線
       會被誤判成「這段文字站在一支沒登記的漸層上」（G22③／G23②），而且背景
       原地疊在字底下會把對比直接量成規線色 vs 字色（第 10 輪初版踩過這個坑：
       AAA 從 7.12 掉成 2.68）。改成 ::after 疊在文字**上面**（正常流內容先畫、
       絕對定位的偽元素後畫，天生疊在最上層），regine 用純色 background（不是
       linear-gradient()，掃描才不會誤認），量測祖先鏈只看真的 DOM 元素，
       不會走到偽元素，兩條 gate 都不會被誤觸。粗細／位置一樣出自具名 token。 */
    s[data-expired]{text-decoration:none;color:${t.ink2};position:relative}
    s[data-expired]::after{content:"";position:absolute;left:0;right:0;top:var(--ls-expired-rule-y);height:var(--ls-expired-rule-w);background:${t.edge};pointer-events:none}
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
  `<div class="g" data-col="phone" data-grad="paper" style="position:relative;width:390px;height:${h}px;background:${gradCss(t, 'paper')};overflow:hidden;display:flex;flex-direction:column">${inner}</div>`;

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
  'InviteEmpty.dc.html': 920, 'InviteGenerating.dc.html': 920,
  'InviteApprovalOff.dc.html': 880, 'InviteApprovalOffDark.dc.html': 880,
  'InviteRequests.dc.html': 940, 'InviteRequestsMany.dc.html': 1420, 'StressType.dc.html': 1700,
  'StressCodeAX.dc.html': 2160, 'StressLoginAX.dc.html': 8420,
  'Tokens.dc.html': 9020, 'Notes.dc.html': 3820, 'StressContent.dc.html': 960, 'AppIcon.dc.html': 3660,
  'GlassSeam.dc.html': 2060,
};
const h = (f) => HH[f] || 844;

/* ─────────────────────  照片：焦點寫一次，各斷點自己算  ─────────────────────
   焦點是「影像座標的比例」，不是 object-position。object-position 由焦點＋框的比例算出來。
   換了真照片就要重推一次 —— 這一稿的素材是 1024×1536（2:3），比上一版的佔位圖更直，
   所以兩個斷點都變成「只裁縱向」，fx 這一軸在兩個斷點都沒有作用（實測印在 Notes 板上）。
   焦點取在祖母與嬰兒兩張臉的中間（影像座標 53% / 30%），不是取在單一張臉上 ——
   主體是「兩個人靠在一起」這件事。 */
const PHOTO = { w: 1024, h: 1536, fx: .53, fy: .30 };

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
// alt 寫「看得到什麼」：誰、在哪、在做什麼。攝影 brief 不藏在 alt 裡
// （那是給採購看的，不是給讀螢幕的人聽的）。換了照片，alt 跟著重寫。
const PHOTO_ALT = '一位祖母坐在床邊，把幾個月大的嬰兒抱在胸前，兩人臉頰靠在一起、都望著鏡頭；晨光從左邊的紗簾透進來，身後是木頭櫃子和摺好的粉色布巾';

/* ── 深色的照片：少一格光（第 5 輪 D4-03）────────────────────────────
   第 4 輪實測深色版與淺色版的照片逐像素平均差 ΔRGB −2.6 —— 等於沒有變暗。
   判定很準：「這一稿蓋了一個有光源、有時間的世界，唯獨照片不在裡面。」

   這一輪它進到那個世界裡，用的是攝影自己的單位：**夜裡少一格光**。
   為什麼不照台紙的比例（台紙 Y 0.771 → 0.0097，1.3%）：那會把照片變成一塊黑。
   相紙不是台紙 —— 它是這本相簿裡唯一自己就是影像的東西；把它降到紙的比例，
   等於為了語言的一致把主角關掉，而這個 app 的主角就是照片裡那兩張臉。
   一格是可以驗的：probe 逐像素量兩張板的照片，平均亮度比與 p99 比都必須落在
   0.5±0.04（實測 0.497／0.490）。誠實話印在 Tokens 板上：少一格之後，
   照片的白仍然比它裱在上面的紙亮十幾倍 —— 一格是「看得出來變暗」與
   「長輩仍然看得清楚祖母的臉」之間的取捨，不是物理的終點。 */
const photoLight = (t) => (t.dir > 0 ? '' : `;filter:brightness(${PHOTO_DIM})`);

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

/* 登入的三顆鍵，順序是使用者核定的：Apple → Google → Email。
   這一稿把「順序」與「視覺重量」對齊了 —— 上一稿是「順序是唯一的優先訊號」，
   因為主按鈕（陶土）在最上面卻不是第一優先，色與序打架。現在：
     · Apple 在最上，而且它在兩種模式下都自動是全頁最重的一塊（淺色純黑／深色純白）
     · Google 的重量由它自己的品牌規範決定，我們不去改它的色來扳回順序
     · Email 這一顆**從主按鈕降級成一般浮起面** —— 歡迎頁因此一顆濃玫瑰都沒有，
       色彩不再與順序打架。濃玫瑰留給流程裡真正只有一條路的畫面。
   三顆鍵同高（≥${FIX.button}pt）、同圓角、同間距，直排，AX 軸另有一張壓力板。

   第 1 輪 R5：這一頁最重的兩塊都是別人的品牌（Apple 對台紙 ΔE 81.7、Google 14.5，
   我們自己的 0）。改法不是把它們調暗，也不是把 Email 降成文字連結 ——
   是**在台紙上壓一個凹下去的托盤**，三顆鍵坐進去。第三方色塊因此從「浮在頁面上的
   異物」變成「貼在台紙上的東西」：它們仍然完全照自己的規範長，但那個洞是我們挖的。
   附帶治好深色的 Email 鍵：它原本坐在台紙上、ΔE 只有 2.5（在可辨識門檻邊緣），
   坐進托盤之後底下換成 win（凹）那一階，實測值印在 Tokens 板上。

   托盤是凹的，所以它進「凹＝可以填」的白名單（角色 tray）——「可以填」在這裡是
   字面上的意思：這個凹槽本來就是空的，登入方式是**放進去的東西**。
   它自己永遠不可按（可按的是坐在裡面的那三顆），這與白名單其他角色一致。 */
/* 第 2 輪 R5 的三選一，本輪表態：**選②——托盤上緣壓自家的材質（騎縫線）**。
   ① 托盤加深到 ΔE≥12：不做。理由是那個度量本身是錯的目標 —— Apple 的規範
      指定純黑／純白，Google 的規範指定白底四色標；跟它們比「誰的色塊比較重」
      是一場定義上贏不了的軍備競賽，而且要把托盤壓到 ΔE 12 得再生一階台紙色
      （第五階），托盤就從「挖出來的槽」變成「另一張卡」，反而更像三顆鍵坐在別人家。
   ③ 撤掉收編目標：不做。歡迎頁是全 app 唯一一次「我們是誰」有機會被說出來的地方。
   ② 做這個：托盤的上緣就是一條**騎縫線**（perf）—— 它是這一稿自己的材質，
      出處是票根（撕下來的那條邊）。它說的是：這個槽是從我們自己那張紙上撕下來的，
      三顆鍵是**放進我們的印刷品裡**的東西。收編靠的是自家的材質跨過邊界，
      不是靠自家的色塊比較大聲。同時 win() 這裡不畫四邊描邊（outline:false）——
      紙上壓出來的凹槽沒有輪廓線；有輪廓線的是印上去的框（表格、輸入格）。
      所以托盤現在只有三個邊界：上緣的騎縫線、左右與下緣那道內影。 */
/* 第 5 輪：托盤的上緣不再是「一條印上去的虛線」，是**撕開之後留下的扇貝邊**
   （perfCut 的 torn：只切自己的上緣，所以每一口都是半圓）。票根還沒撕，
   所以它的齒是完整的圓孔 —— 同一台打孔機，兩種狀態，這是可以被 gate 咬的區別。
   托盤也跟著票根出血：它是從我們自己那張紙上撕下來的一塊，不是版心裡的一張卡。 */
const signInStack = (t, { bleed = FIX.gutter } = {}) => {
  const cut = perfCut('torn', 'top', PERF.pitch, t);
  const out = bleed
    ? ` data-w="bleed" style="${win(t, { role: 'tray', pad: '0', radius: 0, outline: false })};${cut.css};margin:0 -${bleed}px;`
    : ` style="${win(t, { role: 'tray', pad: '0', outline: false })};${cut.css};`;
  return `
  <div${S('win', 'tray')}${cut.attr}${out}display:flex;flex-direction:column">
    <div style="padding:${SP.m}px ${bleed ? FIX.gutter : SP.m}px;display:flex;flex-direction:column;gap:${SP.m}px">
      ${btnApple(t)}
      ${btnGoogle(t)}
      ${btnEmail(t, { label: TY.bs, h: FIX.button, pad: SP.l, title: 'full' })}
    </div>
  </div>`;
};

const welcome = (t) => {
  const photoH = 340, overlap = FIX.seamPhone;
  return doc(t, `<div class="g" data-col="phone" data-grad="paper" style="position:relative;width:390px;height:844px;background:${gradCss(t, 'paper')};overflow:hidden">
  <div${S('win', 'photo')} style="position:absolute;top:0;left:0;width:390px;height:${photoH}px;overflow:hidden;box-shadow:${insetShadow(t, 'mount')}">
    <img src="family.jpg" alt="${PHOTO_ALT}" data-photo="${t.dir > 0 ? 'day' : 'night'}" style="width:100%;height:100%;object-fit:cover;object-position:${objPos(390, photoH)};display:block${photoLight(t)}">
  </div>
  <div data-grad="seam" aria-hidden="true" style="position:absolute;left:0;top:${photoH - overlap - SP.xxl}px;width:390px;height:${SP.xxl}px;background:${gradCss(t, 'seam')}"></div>
  <div class="g"${S('fold', 'seam')} data-grad="paper" style="position:absolute;left:0;top:${photoH - overlap}px;width:390px;height:${844 - photoH + overlap}px;background:${gradCss(t, 'paper')};border-radius:20px 20px 0 0;border-top:${FIX.hair}px solid ${t.edge};box-shadow:inset 0 2px 0 ${foldEdge(t)}">
    <div style="display:flex;flex-direction:column;height:100%;padding:${FIX.gutter}px ${FIX.gutter}px ${FIX.safeBottom}px;gap:${SP.xxl}px">
      <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px">
        ${inkMark(INK.phone, t.ink, t.ink2)}
        <div style="display:flex;flex-direction:column;gap:${SP.m}px">
          <h1 style="${TY.d};color:${t.ink};margin:0">孩子的每一天<br>只留給家人看</h1>
          <p style="${TY.b};color:${t.ink2};margin:0">照片、影片和日記，只有你邀請的人看得到。</p>
        </div>
      </div>
      <div style="display:flex;flex-direction:column;gap:${SP.s}px">
        ${signInStack(t)}
        ${consent(t)}
      </div>
    </div>
  </div>
</div>`);
};

/* iPad 1194x834 —— 照片吃左邊 55%。內容欄不再垂直置中，改三段式：
   字標貼上緣（信箋抬頭）、標題組、按鈕＋法律行貼欄底。呼吸帶均分。 */
const welcomeIPad = (t) => doc(t, `
<div class="g" data-grad="paper" style="position:relative;width:1194px;height:834px;background:${gradCss(t, 'paper')};overflow:hidden;display:flex">
  <div${S('win', 'photo')} data-col="photo" style="position:relative;width:657px;height:834px;overflow:hidden;flex:none">
    <img src="family.jpg" alt="${PHOTO_ALT}" data-photo="${t.dir > 0 ? 'day' : 'night'}" style="width:100%;height:100%;object-fit:cover;object-position:${objPos(657, 834)};display:block${photoLight(t)}">
  </div>
  <div class="g"${S('fold', 'seam')} data-col="content" data-light="geometry" data-grad="paper" style="position:relative;width:537px;height:834px;background:${gradCss(t, 'paper')};margin-left:-${FIX.seam}px;border-radius:24px 0 0 24px;border-left:${FIX.hair}px solid ${t.edge};box-shadow:-18px 0 30px -24px rgba(20,12,6,.75)">
    <div style="display:flex;flex-direction:column;justify-content:space-between;height:100%;padding:${FIX.padPad}px">
      ${inkMark(INK.pad, t.ink, t.ink2)}
      <div data-pause="iPad 三段式：字標貼上緣當信箋抬頭、標題組落在視線高度，中間這段空白是刻意的間隔" style="display:flex;flex-direction:column;gap:${SP.xl}px;max-width:425px">
        <h1 style="${TY.dHero};color:${t.ink};margin:0">孩子的每一天<br>只留給家人看</h1>
        <p style="${TY.bPad};color:${t.ink2};margin:0">照片、影片和日記，只有你邀請的人看得到。</p>
      </div>
      <div data-pause="iPad 三段式：動作區貼欄底（拇指在下緣），與標題組之間的空白是刻意的間隔" style="display:flex;flex-direction:column;gap:${SP.m}px;max-width:${FIX.btnMax}px">
        ${signInStack(t, { bleed: 0 })}
        ${consent(t)}
      </div>
    </div>
  </div>
</div>`);

/* ─────────────────────  EMAIL / OTP  ───────────────────── */

// 下半部不是留白，是「你會收到什麼」——長輩最常卡在「信在哪裡」。
// 寄件人那一格印的是手寫字標本人：畫面上看到的筆跡，信裡也會看到同一支。
const mailPreview = (t) => table(t, [
  ['寄件人', `<span style="display:inline-flex;vertical-align:-4px">${inkMark(INK.mail, t.ink, t.ink2)}</span>`],
  ['主旨', '你的登入數字'],
  ['數字在哪', '信打開的第一行，字很大'],
], { head: '你會收到一封這樣的信' });

/* 三個狀態：空白、格式錯誤、正在寄。
   第 1 輪 R8：上一稿把「正在傳送驗證信…」畫在**歡迎頁**上 —— 那一頁根本沒有信箱欄位，
   所以那是一個到不了的狀態（reviewer 的原話：不可能狀態）。載入態該待的地方是
   這一頁：信箱已經填好、按了「傳送驗證碼」，鍵就地轉態。板名也一起改成 EmailSending，
   因為板名就是「這是哪一個畫面的哪一個狀態」。 */
const emailScreen = (t, { error = false, busy = false } = {}) => doc(t, phone(t, `
${head(t)}
${col(`
  ${stepRail(t, 1, 2, '步驟 1，共 2 步')}
  ${titleBlock(t, '輸入你的 Email', '我們會寄一組 6 位數字給你，不用記密碼。')}
  ${error
    ? field(t, { label: 'Email', value: 'ama.gmail.com', state: 'error' })
    : busy
      ? field(t, { label: 'Email', value: 'ama@gmail.com', state: 'disabled', hint: '例如 ama@gmail.com' })
      : field(t, { label: 'Email', placeholder: '你的信箱', state: 'idle', hint: '例如 ama@gmail.com' })}
  ${error ? errorLine(t, '這個 Email 少了 @，請再看一次。') : ''}
  ${error
    ? tableLine(t, `信會由「${BRAND}」寄出，主旨是「你的登入數字」。`)
    : mailPreview(t)}
  ${busy ? btn(t, '正在傳送驗證信…', { busy: true }) : btn(t, '傳送驗證碼', { icon: I.send })}
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
      `寄件人是「${BRAND}」，主旨「你的登入數字」。`,
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
  <div${S('raise', 'choice')}${primary ? CTA : ''}${pad ? ' data-pause="iPad 選項卡：卡內距 44（卡面本身就是點擊面）＋卡間距 32，所以字到字之間必然超過 120px —— 那是卡片的厚度，不是版面的空洞"' : ''} style="${raise(t, { g: primary ? 'cta' : 'face', lip: primary ? t.ctaDeep : t.edge, radius: primary ? 18 : 14 })};padding:${pad ? `${FIX.tap}px ${SP.xxl}px` : (primary ? `${FIX.gutter}px ${SP.l}px` : `${SP.l}px`)};display:flex;gap:${SP.l}px;align-items:flex-start">
    <span style="flex:none;width:44px;height:44px;border-radius:50%;background:${primary ? t.ctaDeep : t.board2};display:flex;align-items:center;justify-content:center;color:${primary ? t.onCta : t.ink2}">${icon}</span>
    <div style="display:flex;flex-direction:column;gap:${SP.s}px;min-width:0">
      <span ${primary && pad ? 'data-cap="R"' : ''} style="${primary ? (pad ? TY.h : TY.c) : (pad ? TY.bPadS : TY.bs)};color:${primary ? t.onCta : t.ink}">${title}</span>
      <span style="${pad ? TY.bPad : TY.b};color:${primary ? t.onCta : t.ink2}">${sub}</span>
    </div>
  </div>`;

const FORK_NOTE = '選錯了也沒關係。之後還可以加入別的家庭，一個帳號可以同時待在好幾個家裡；你在每個家裡的身分也可以不一樣。';

const forkOptions = (t, pad = false) => `
  ${forkOption(t, { pad, primary: true, icon: I.key, title: '我有邀請碼', sub: '家人給你一組 6 個字母和數字。輸入之後，等他按下核准，你就進到家裡了。' })}
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
<div class="g" data-grad="paper" style="position:relative;width:1194px;height:834px;background:${gradCss(t, 'paper')};overflow:hidden">
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
      ${inkMark(INK.preview, t.ink, t.ink2)}
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
  ${titleBlock(t, '輸入邀請碼', '家人給你的 6 個字母和數字，分成前三碼和後三碼。')}
  ${codeCells(t, CODE.replace(' ', '').split(''), { caret: err ? -1 : 5, error: !!err })}
  ${err
    ? `<div style="display:flex;flex-direction:column;gap:${SP.s}px">
         ${errorLine(t, err.msg)}
         ${hint(t, err.body, { size: TY.b })}
       </div>`
    : `<span style="${TY.cap};color:${t.ink2}">${SAY}</span>`}
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
  ${hint(t, '送出之後這個畫面會變成「等家長核准」。可以先關掉 app，核准了會通知你。')}
`)}`, { h: h(state === 'expired' ? 'JoinExpired.dc.html' : state === 'usedup' ? 'JoinUsedUp.dc.html' : 'JoinCode.dc.html') }));
};

// 等待畫面的主體就是「還沒被填上的那扇窗」—— 母題直接拿來說明狀態。
const emptyWindow = (t) => `
  <div${S('win', 'photo')} style="${win(t, { role: 'photo', pad: '0', radius: 14 })};height:140px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:${SP.m}px">
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
    ['你的身分', '核准後由家長設定'],
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
  '產生一組 6 個字母和數字。',
  '念給家人聽，或用訊息傳給他們。',
  '他們輸入之後，你按下核准才算進來。',
], { head: '號碼是這樣用的' });

// Email 的斷行機會給在 @ 與每一個「.」後面：不切在字中間，也不會掉一個孤兒字元下去。
const mail = (addr) => addr.replace(/([@.])/g, '$1<wbr>').replace(/<wbr>$/, '');

/* 核准這一刻只判斷一件事：這個人是不是你認識的。
   身分（家人／親友）不在這裡選 —— 那是家長之後在成員設定裡指定的（使用者核定），
   把它塞進核准當下只會讓長輩在最需要專心的一步多做一個決定。 */
const requestCard = (t, { name = '王怡君', initial = '怡', email = 'yijun@gmail.com', when = `3 分鐘前用 ${CODE} 送出` } = {}) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 18 })};display:flex;flex-direction:column;gap:${SP.l}px">
    <div style="display:flex;gap:${SP.m}px;align-items:center">
      <div${S('win', 'avatar')} style="flex:none;width:${FIX.avatar}px;height:${FIX.avatar}px;${win(t, { role: 'avatar', tone: 'board3', radius: '50%' })};display:flex;align-items:center;justify-content:center">
        <span style="${TY.c};color:${t.ink2}">${initial}</span>
      </div>
      <div style="display:flex;flex-direction:column;gap:${SP.xs}px;min-width:0">
        <span style="${TY.bs};color:${t.ink};${press(t)};overflow-wrap:break-word">${name}</span>
        <span style="${TY.cap};color:${t.ink2};overflow-wrap:break-word">${mail(email)}</span>
        <span style="${TY.cap};color:${t.ink2}">${when}</span>
      </div>
    </div>
    ${noteBox(t, I.people, '核准之後，他就看得到家庭裡的照片。身分（家人或親友）之後在成員設定裡改，不用現在決定。', { size: TY.cap, inset: false })}
    <div style="display:flex;flex-direction:column;gap:${SP.xxl}px">
      ${btn(t, '核准加入')}
      ${tapLink(t, '拒絕這個申請', { center: true })}
    </div>
  </div>`;

// 排隊的人收成一列：頭像、名字、Email、等多久、「查看」。
// 一次只攤開一張 —— 陶土色因此每畫面仍然只有一個，而且攤開的永遠是等最久的那位。
const requestRow = (t, { name, initial, email, waited }) => `
  <div${S('raise', 'row')} style="${raise(t, { g: 'face', lip: t.edge })};min-height:${FIX.tap}px;padding:${SP.m}px ${SP.l}px;display:flex;gap:${SP.m}px;align-items:center">
    <div${S('win', 'avatar')} style="flex:none;width:${FIX.tap}px;height:${FIX.tap}px;${win(t, { role: 'avatar', tone: 'board2', radius: '50%' })};display:flex;align-items:center;justify-content:center">
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
      : ticket(t, { uses: state === 'spent' ? 0 : USES_TOTAL });
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
    /* 用完了。這**不是新畫面，是已產生的最後一個狀態** —— 版式與已產生完全一樣，
       票根的三個量（色相位移、明度差、彩度）一起歸零，三格刻度全部褪完。
       它是那句隱喻的收尾：**褪完了就沒有褪色的方向了**。
       動作也跟著轉：傳與複製都撤掉（傳出去的號碼進不來，那是假的可按物），
       主按鈕變成「產生新的號碼」—— 這一刻只有一條路。 */
    spent: `
      <span style="${TY.cap};color:${t.ink2}">三次都用掉了。號碼還讀得到（碳墨不會褪），但它已經帶不了人進來。</span>
      ${btn(t, '產生新的號碼', { icon: I.plus })}
      <span style="${TY.cap};color:${t.ink2}">新的一組一樣可以用 3 次。這一組從產生新的那一刻起就不能再用了。</span>`,
  }[state];
  const body = `${codeArea}\n${toggleRow(t, { on })}\n${tail}`;

  const titles = {
    empty: ['邀請家人', '產生一組號碼，念給家人聽或傳給他們。'],
    busy: ['邀請家人', '產生一組號碼，念給家人聽或傳給他們。'],
    ready: ['邀請家人', '號碼有期限，也有可用次數。'],
    approvalOff: ['邀請家人', '號碼有期限，也有可用次數。'],
    spent: ['邀請家人', '號碼有期限，也有可用次數。'],
  }[state];
  // 還沒產生的兩態多一張「號碼是這樣用的」明細表，內容放不下 844 —— 板長高＝這張會捲動。
  /* 深色板的板名是推出來的（第 5 輪 D4-02）。第 4 輪這裡寫死淺色板名，
     深色的兩張是靠「高度剛好一樣」矇過去的 —— 加一張深色板就會拿到錯的板高。 */
  const board = { empty: 'InviteEmpty', busy: 'InviteGenerating', ready: 'InviteReady', approvalOff: 'InviteApprovalOff', spent: 'InviteSpent' }[state]
    + (t.dir < 0 ? 'Dark' : '');

  return doc(t, phone(t, `${inviteHead(t, titles[0], titles[1])}
${col(body, { top: SP.xl })}`, { h: h(`${board}.dc.html`) }));
};

// 有人在等的時候，畫面的主詞是人，不是號碼：標題換成「有 N 個人想加入」，票根降成一行。
// 排序是等最久的在最上面 —— 攤開的那一張就是該先處理的那一張。
const inviteRequests = (t, { many = false } = {}) => {
  /* 第 1 輪 R2：這兩行原本是單引號，`${CODE2}` 六個字元原封不動印在板上，
     71 項 gate 沒有一項會叫。改成範本字串，並在 G16／G20 加一條產物掃描：
     產出的 HTML 裡出現 `${` 一律 FAIL（fail-closed，不是靠人眼看）。 */
  const queue = QUEUE;
  const n = many ? queue.length : 1;
  const first = many ? queue[0] : {};
  /* 剩餘次數不是裝飾：送出申請的當下就用掉一次（不是核准才算）。
     單人板：王怡君用的就是現在這組碼 → 用掉 1，剩 2。
     多人板：四個人裡有兩位是用上一組碼（R4T 8VN）送出的 —— 攤開的那張卡上寫著 ——
     所以這組碼用掉 2、剩 1。號碼帶就褪到第三階。 */
  const used = many ? queue.filter((p) => p.own).length : 1;
  const uses = USES_TOTAL - used;
  return doc(t, phone(t, `${inviteHead(t, `有 ${n} 個人想加入`, many ? '等最久的排在最上面。看清楚是不是你認識的人，再按核准。' : '看清楚是不是你認識的人，再按核准。')}
${col(`
  ${requestCard(t, first)}
  ${many ? `<div style="display:flex;flex-direction:column;gap:${SP.m}px">
    <span style="${TY.l};color:${t.ink2}">後面還有 ${n - 1} 位在等</span>
    ${queue.slice(1).map((p) => requestRow(t, p)).join('')}
  </div>` : ''}
  ${rule(t)}
  ${ticket(t, { uses })}
  ${tapLink(t, '換一組新的號碼', { center: true })}
`, { top: SP.xl })}`, { h: h(many ? 'InviteRequestsMany.dc.html' : 'InviteRequests.dc.html') }));
};

/* ─────────────────────  壓力測試  ───────────────────── */

// AX5 ≈ 310%：17pt→53pt。圖示在 AX3 以上一律拿掉 —— 放大的圖示會把按鈕撐爆。
const stressType = (t) => doc(t, `
<div class="g" data-col="phone" data-grad="paper" style="position:relative;width:390px;height:${h('StressType.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;display:flex;flex-direction:column">
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
      <div${S('win', 'field')} style="background:${gradCss(t, 'win')};border:2px solid ${t.ink};border-radius:12px;box-shadow:${insetShadow(t)};min-height:${ax(56)}px;display:flex;align-items:center;padding:${SP.l}px">
        <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;color:${t.ink};overflow-wrap:break-word">${mail('ama@gmail.com')}</span>
      </div>
    </div>
    <div${S('raise', 'button')}${CTA} style="${raise(t, { g: 'cta', lip: t.ctaDeep })};min-height:${ax(56)}px;display:flex;align-items:center;justify-content:center;padding:${SP.l}px;color:${t.onCta}">
      <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600;color:${t.onCta};text-align:center">傳送驗證碼</span>
    </div>
    ${hint(t, '信通常一分鐘內會到。沒看到的話，找找垃圾郵件。', { size: `font-size:${ax(13)}px;line-height:${ax(18)}px` })}
  </div>
</div>`);

/* 三顆登入鍵在 AX5 —— 順序改了、又多了一顆鍵，所以這個堆疊要自己有一張壓力板。
   看三件事：① 三顆鍵在 AX5 仍然直排、仍然同高、命中盒遠大於 ${FIX.tap}pt；
   ② <b>我們自己的 icon 拿掉、兩個品牌的標誌留著</b>（商標不是裝飾）；
   ③ 法律行的兩個 ${FIX.tap}pt 命中盒放大後仍然是兩個獨立的盒，不是一段文字。 */
/* AX5 的三顆登入鍵（第 1 輪 R7）。
   上一稿在這裡自己把 Apple 的標誌堆到字的上方（flex-direction:column）——
   一邊主張「HIG 連唇邊都算改外觀」，一邊親手改掉它的版式。這一輪改成官方的做法：
   **換短標題**（Apple 與 Google 的規範都提供「登入」這個短版，正是給窄空間用的），
   版式一律維持橫排。我們自己的那顆不換短標題 —— 對長輩把話說完比排整齊重要，
   所以「用 Email 登入」在 AX5 換行、變成三顆裡最高的一顆。
   第 2 輪這裡的結論是「三顆等高在 AX5 不再成立」，reviewer 駁回、裁 (a)：**三顆等高**。
   裁得對 —— 品牌規範給的高度是**最小值不是最大值**，讓 Apple／Google 跟著 Dynamic Type
   一起長高不算改它們的外觀（R6 的立場因此完全相容：我們不改它們的色、標誌、描邊、
   版式，只讓它們的最小高度被更長的鄰居撐開）。實作是 grid-auto-rows:1fr，
   不是手算高度 —— 手算的那一份會在下一次改字時過期。 */
const stressLoginAX = (t) => {
  /* 第 5 輪 D4-05：第 4 輪這張板只畫 AX5，而 AX5 下兩顆品牌鍵都只剩「登入」二字 ——
     reviewer 的判定是「等高達標但語意塌」。改法不是硬把長標籤塞進去（塞不下，
     下面是量出來的數字），是**把斷點畫出來**：AX4 是最後一階仍然說得完整句的字級。 */
  const stack = (px, title, label) => {
    const f = (n) => Math.round(n * px / 17);   // 這一階的字級推導（17pt body 是基準）
    const lab = `font-size:${f(17)}px;line-height:${f(25)}px;font-weight:600`;
    const cut = perfCut('torn', 'top', f(PERF.pitch), t);   // 齒距跟著這一階的紙一起長大
    return `<div${S('win', 'tray')}${cut.attr} data-w="bleed" data-ax="${label}" style="${win(t, { role: 'tray', pad: '0', radius: 0, outline: false })};${cut.css};margin:0 -${FIX.gutter}px;display:flex;flex-direction:column">
      <div style="padding:${SP.l}px ${FIX.gutter}px;display:grid;grid-auto-rows:1fr;gap:${SP.m}px">
        ${btnApple(t, { label: lab, mark: [f(20), f(24)], h: f(FIX.button), title, pad: SP.m })}
        ${btnGoogle(t, { label: lab, mark: f(20), h: f(FIX.button), title, pad: SP.m })}
        ${btnEmail(t, { label: lab, h: f(FIX.button), title, pad: SP.m })}
      </div>
    </div>`;
  };
  const axLink = (label) => `<span${S('raise', 'link')} style="align-self:flex-start;min-height:${FIX.tap}px;display:inline-flex;align-items:center;padding:0 ${SP.s}px;font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:600;color:${t.ink};text-decoration:underline;text-underline-offset:3px;text-decoration-thickness:1.5px">${label}</span>`;
  return doc(t, `
<div class="g" data-col="phone" data-grad="paper" style="position:relative;width:390px;height:${h('StressLoginAX.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;display:flex;flex-direction:column">
  <div style="display:flex;flex-direction:column;gap:${SP.xl}px;padding:${FIX.safeTop}px ${FIX.gutter}px ${FIX.safeBottom}px;flex-grow:1">
    <h1 style="font-size:${ax4(28)}px;line-height:${ax4(34)}px;font-weight:700;letter-spacing:-.01em;color:${t.ink};margin:0">選一種方式登入</h1>
    <span style="font-size:${ax4(15)}px;line-height:${ax4(21)}px;font-weight:600;color:${t.ink2}">AX4（${Math.round(AX4 * 100)}%）：說得完整句</span>
    ${stack(ax4(17), 'brand', 'AX4')}
    <span style="font-size:${ax4(15)}px;line-height:${ax4(21)}px;font-weight:600;color:${t.ink2}">AX5（${Math.round(AX * 100)}%）：換官方短標題</span>
    ${stack(ax(17), 'short', 'AX5')}
    <!-- 兩條示範行，一條放不下、一條放得下 —— 「換不換短標題」在這一階不是偏好，是算術。
         容器寬 ＝ 那顆鍵在 AX5 真正剩給標籤的寬度（自己的 padding／標誌／間距都扣掉了）。
         放不下的那條被裁掉，裁口上壓一道朱線；放得下的那條把剩下的餘裕畫成一段綠色的量尺。 -->
    <div style="display:flex;flex-direction:column;gap:${SP.xs}px">
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2}">同一階字級下「Google 登入」放不下的樣子（所以它換官方短標題）</span>
      <div data-fit="ax5-google" style="position:relative;width:${390 - FIX.gutter * 2 - SP.m * 2 - ax(20) - SP.m}px;overflow:hidden">
        <span data-fit-label="1" style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600;color:${t.ink};white-space:nowrap">Google 登入</span>
        <div aria-hidden="true" style="position:absolute;right:0;top:0;width:${FIX.errBar}px;height:100%;background:${t.pen}"></div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:${SP.xs}px">
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2}">同一階字級下「Email 登入」放得下的樣子（所以它<b style="color:${t.ink}">不縮</b>）</span>
      <div data-fit="ax5-email" style="position:relative;width:${390 - FIX.gutter * 2 - SP.m * 2}px;overflow:hidden;display:flex;align-items:center">
        <span data-fit-label="1" style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600;color:${t.ink};white-space:nowrap">Email 登入</span>
        <span aria-hidden="true" style="flex:1;height:${FIX.hair * 3}px;background:${t.sprout};margin-left:${SP.s}px"></span>
      </div>
    </div>
    <div style="display:flex;flex-wrap:wrap;align-items:center;gap:${SP.xs}px">
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2}">登入即表示你同意</span>
      ${axLink('使用條款')}
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2}">與</span>
      ${axLink('隱私權政策')}
    </div>
    <!-- 規格用表講，不用散文講：三顆 × 三階，一眼看得出「第三顆那一列不一樣」。 -->
    <table style="border-collapse:collapse;width:100%">
      <tr>${['', `一般字級`, `AX4（${Math.round(AX4 * 100)}%）`, `AX5（${Math.round(AX * 100)}%）`].map((x) => `<th style="text-align:left;padding:${SP.s}px ${SP.m}px ${SP.s}px 0;font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:600;color:${t.ink}">${x}</th>`).join('')}</tr>
      ${[['apple', 'Apple（借來的）'], ['google', 'Google（借來的）'], ['email', 'Email（我們自己的）']].map(([k, who]) => `
      <tr>${[who, ...['full', 'brand', 'short'].map((tt) => signInLabel(k, tt))].map((v, i) => `<td style="padding:${SP.s}px ${SP.m}px ${SP.s}px 0;border-top:${FIX.hair}px solid ${t.edge};font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:${i === 0 ? 600 : 400};color:${i === 0 ? t.ink : t.ink2}">${v}</td>`).join('')}</tr>`).join('')}
    </table>
    <div${S('flat')} style="${flat(t, { pad: `${SP.l}px` })}">
      <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};${press(t)}"><b style="color:${t.ink}">最後一列為什麼不一樣</b>：Apple 與 Google 的「登入」是<b style="color:${t.ink}">它們規範自己給的短標題</b>，品牌詞由商標承擔；我們沒有商標可以替我們說話，而且我們那顆沒有標誌佔位，剩給標籤的寬反而最寬。<b style="color:${t.ink}">所以第三顆不縮不是通融，是算術</b>：${measured.axFitLine}<br><br><b style="color:${t.ink}">第 5 輪這裡漏了第三顆</b>——那時它跟著掉成「登入」，一顆沒有商標、沒有無障礙名稱的按鈕，讀螢幕唸出來就是「登入」二字。<b style="color:${t.ink}">aria-label 只掛在 AX5 的兩顆品牌鍵上</b>，值是「品牌詞＋可見文字」（<code>Apple 登入</code>）；其餘一律不掛，可見文字自己就是名稱 —— 因為<b style="color:${t.ink}">可見的字必須在名稱裡</b>（WCAG 2.5.3，用語音控制的人唸的是他看得到的字）。第 5 輪三顆都掛 <code>使用 X 帳號登入</code>，在 AX4（畫面上寫「Apple 登入」）反而違反那一條。G32⑤ 逐顆比對。<br><br><b style="color:${t.ink}">沒有選的兩條路</b>：折行（長輩讀兩行按鈕比讀一個短標題更慢）、把標誌堆到字的上方（那是改別人的版式）。我們自己的信封 icon 在 AX3 以上拿掉只留字；兩個品牌的標誌留著並跟著長大 —— 那是商標不是裝飾。三顆等高由 <code>grid-auto-rows:1fr</code> 保證，命中盒的 ${FIX.tap}pt 是實體最小值不隨字級放大。</span>
    </div>
  </div>
</div>`);
};

/* 六格與票根在 AX5 的降版 —— Notes 上寫了兩條規則，這張板把它們畫出來：
   ① 六格改兩排三格（不橫向壓縮）
   ② 票根的 60pt 不跟著放大（60×3.1 = 186pt，一行放不下三碼）：
      鎖在 36pt 的 AX 推導值 112pt，並改成兩排三碼。 */
const stressCodeAX = (t) => {
  const cellH = ax(56), nAX = `font-family:${MONO};font-variant-numeric:tabular-nums;font-size:${ax(36)}px;line-height:${ax(40)}px;font-weight:600`;
  const cellAX = (d) => `<div${S('win', 'cell')}${MO('cells')} style="flex:1;background:${gradCss(t, 'win')};border:${FIX.hair}px solid ${t.edge};border-radius:12px;box-shadow:${insetShadow(t)};height:${cellH}px;display:flex;align-items:center;justify-content:center">
      <span style="${nAX};color:${t.ink}">${d}</span></div>`;
  const rowAX = (ds) => `<div style="display:flex;gap:${SP.s}px">${ds.map(cellAX).join('')}</div>`;
  return doc(t, `
<div class="g" data-col="phone" data-grad="paper" style="position:relative;width:390px;height:${h('StressCodeAX.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;display:flex;flex-direction:column">
  <div style="padding:${FIX.safeTop}px ${FIX.gutter}px 0">
    <div style="min-height:${ax(17)}px;display:flex;align-items:center;gap:${SP.s}px;color:${t.ink}">
      <svg width="${ax(12)}" height="${ax(12)}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14.5 5 8 12l6.5 7"/></svg>
      <span style="font-size:${ax(17)}px;line-height:${ax(25)}px;font-weight:600">返回</span>
    </div>
  </div>
  <div style="display:flex;flex-direction:column;gap:${FIX.gutter}px;padding:${FIX.gutter}px ${FIX.gutter}px ${FIX.safeBottom}px;flex-grow:1">
    <h1 style="font-size:${ax(28)}px;line-height:${ax(34)}px;font-weight:700;letter-spacing:-.01em;color:${t.ink};margin:0">輸入邀請碼</h1>
    <div style="display:flex;flex-direction:column;gap:${SP.l}px">
      ${rowAX(CODE.split(' ')[0].split(''))}
      ${rowAX(CODE.split(' ')[1].split(''))}
    </div>
    <p style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};margin:0">${SAY}</p>
    <div${S('flat')}${MO('ticket')} data-w="bleed" style="${flat(t, { pad: '0', radius: 0 })};overflow:hidden;margin:0 -${FIX.gutter}px">
      <div${perfCut('joined', 'bottom', ax(PERF.pitch), t).attr} data-grad="${stubOf(USES_TOTAL)}" style="background:${gradCss(t, stubOf(USES_TOTAL))};${perfCut('joined', 'bottom', ax(PERF.pitch), t).css};padding:${FIX.gutter}px;display:flex;flex-direction:column;align-items:center;gap:${SP.l}px">
        <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};letter-spacing:.16em;${press(t)}">邀 請 碼</span>
        <span style="${nAX};color:${t.ink};${press(t)}">${CODE.split(' ')[0]}</span>
        <span style="${nAX};color:${t.ink};${press(t)}">${CODE.split(' ')[1]}</span>
      </div>
      <div${perfCut('joined', 'top', ax(PERF.pitch), t).attr} style="${perfCut('joined', 'top', ax(PERF.pitch), t).css};padding:${SP.l}px ${FIX.gutter}px;display:flex;flex-direction:column;gap:${SP.s}px;background:${t.board3}">
        <span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};${press(t)}">有效到 8 月 30 日</span>
        <span style="display:inline-flex;align-items:center;gap:${SP.m}px">${stubScale(t, { uses: USES_TOTAL, big: true })}<span style="font-size:${ax(13)}px;line-height:${ax(18)}px;font-weight:500;color:${t.ink2};${press(t)};white-space:nowrap">還可以用 ${USES_TOTAL} 次</span></span>
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
      <div class="g" data-col="phone" data-grad="paper" style="position:relative;width:390px;height:790px;background:${gradCss(t, 'paper')};border:${FIX.hair}px solid ${t.edge};border-radius:18px;overflow:hidden;display:flex;flex-direction:column">${inner}</div>
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
        ${titleBlock(t, '輸入邀請碼', '家人給你的 6 個字母和數字。')}
        ${codeCells(t, ['', '', '', '', '', ''], { caret: 0, error: true })}
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

/* ── G23 的證據表：四階台紙與染料的 LCh，淺深兩欄並排 ──────────
   板上印的每一個數字都是 lch() 現算的（與 verify 的 G23 同一份函式），
   所以「板上印一套、gate 算另一套」在結構上不可能發生。 */
const lchCell = (th, k, base) => {
  const v = lch(th[k]);
  const d = k === 'board' ? null : dHue(v.h, lch(th[base]).h);
  const want = TEMP[k];
  return `<td style="padding:${SP.s}px ${SP.m}px;border-bottom:${FIX.hair}px solid ${T.light.edge};font-family:${MONO};${TY.cap};color:${T.light.ink2};white-space:nowrap">
      <span style="display:inline-block;width:14px;height:14px;border-radius:3px;background:${th[k]};border:${FIX.hair}px solid ${T.light.edge};vertical-align:-2px;margin-right:${SP.s}px"></span>
      ${th[k]} · L*${v.L.toFixed(1)} C*${v.C.toFixed(1)} h${v.h.toFixed(1)}
      ${d === null ? '<b style="color:' + T.light.ink + '">（錨點）</b>'
    : `<b style="color:${Math.abs(d - want) <= TEMP_TOL ? T.light.ink : T.light.pen}">　Δh ${d > 0 ? '+' : ''}${d.toFixed(1)}°</b>`}
    </td>`;
};
const lchTable = (t) => {
  const rows = [
    ['board', '台紙本體', '色相的錨點。'],
    ['board2', '窗底（凹）', `陰影偏<b style="color:${t.ink}">冷</b>，宣告 ${TEMP.board2}°`],
    ['board3', '次要面（手澤）', `翻最多的地方先黃，偏<b style="color:${t.ink}">暖</b>，宣告 +${TEMP.board3}°`],
    ['lit', '亮面（新紙）', `還沒被翻過，宣告 +${TEMP.lit}°`],
    ['cta', '濃玫瑰（染料）', `染料比它印上去的紙<b style="color:${t.ink}">冷</b>，宣告 ${TEMP.cta}°`],
  ];
  return `<table style="width:100%;border-collapse:collapse;margin-bottom:${SP.m}px">
    <tr>${['', '淺色', '深色', '這一階是什麼'].map((s, i) => `<th style="text-align:left;padding:${SP.s}px ${SP.m}px;border-bottom:${FIX.hair}px solid ${t.edge};${TY.l};color:${t.ink};white-space:nowrap">${s || '　'}</th>`).join('')}</tr>
    ${rows.map(([k, name, why]) => `<tr>
      <td style="padding:${SP.s}px ${SP.m}px;border-bottom:${FIX.hair}px solid ${t.edge};${TY.l};color:${t.ink};white-space:nowrap">${name}<br><span style="font-family:${MONO};${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${k}</span></td>
      ${lchCell(T.light, k, 'board')}${lchCell(T.dark, k, 'board')}
      <td style="padding:${SP.s}px ${SP.m}px;border-bottom:${FIX.hair}px solid ${t.edge};${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${why}</td>
    </tr>`).join('')}
  </table>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.m}px"><b style="color:${t.ink}">階梯（G23③，兩個模式各自成立、方向相反，而且原因是物理的）</b>：淺色的 C* 隨著老化<b style="color:${t.ink}">上升</b>（lit ${lch(T.light.lit).C.toFixed(1)} → board ${lch(T.light.board).C.toFixed(1)} → board-2 ${lch(T.light.board2).C.toFixed(1)} → board-3 ${lch(T.light.board3).C.toFixed(1)}）—— 紙會<b style="color:${t.ink}">染上</b>顏色。深色做不到同一條：L* 太低時彩度有上限（畫不出 L*${lch(T.dark.board2).L.toFixed(1)} 又 C*12 的顏色），所以深色的 C* 與 L* <b style="color:${t.ink}">同向</b>（${lch(T.dark.board2).C.toFixed(1)} → ${lch(T.dark.board).C.toFixed(1)} → ${lch(T.dark.board3).C.toFixed(1)} → ${lch(T.dark.lit).C.toFixed(1)}）。<b style="color:${t.ink}">這個差異不是被容忍的，是被斷言的</b>：G23③ 兩條方向相反的階梯各自要成立，任何一條倒過來都 FAIL。另外 L* 有兩條跨模式不變式：亮面永遠比台紙亮、<b style="color:${t.ink}">凹永遠比台紙暗（洞就是洞，不隨光源翻面）</b>；次要面與台紙的距離 ≥5 L*，但方向兩個模式相反 —— 它是浮起面，隨光源翻。</p>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.m}px"><b style="color:${t.ink}">「濃玫瑰＝同一支粉還沒褪色的樣子」的推導（第 1 輪 R3：不接受留著不證明）</b>。從染料 <code>cta ${t.cta}</code> 到台紙 <code>board ${t.board}</code>，三步，每一步都是量出來的：<b style="color:${t.ink}">① 染料流失</b> C* ${lch(t.cta).C.toFixed(1)} → ${lch(t.board).C.toFixed(1)}（−${(lch(t.cta).C - lch(t.board).C).toFixed(1)}）；<b style="color:${t.ink}">② 變薄變亮</b> L* ${lch(t.cta).L.toFixed(1)} → ${lch(t.board).L.toFixed(1)}（+${(lch(t.board).L - lch(t.cta).L).toFixed(1)}）；<b style="color:${t.ink}">③ 紙自己泛黃</b> h ${lch(t.cta).h.toFixed(1)}° → ${lch(t.board).h.toFixed(1)}°（+${dHue(lch(t.board).h, lch(t.cta).h).toFixed(1)}°）。<b style="color:${t.ink}">第 ③ 步是關鍵，也是上一輪被抓的那個洞</b>：色相位移不是染料變了色，是<b style="color:${t.ink}">底下那張紙變黃了</b>——染料只會變少不會變色相。可以否證：如果泛黃是紙的性質，那麼四階台紙<b style="color:${t.ink}">每一階</b>都要帶著同一個方向的位移，而不是只有 board 有。實測四階相對染料是 +${dHue(lch(t.board2).h, lch(t.cta).h).toFixed(1)}° / +${dHue(lch(t.board).h, lch(t.cta).h).toFixed(1)}° / +${dHue(lch(t.board3).h, lch(t.cta).h).toFixed(1)}° / +${dHue(lch(t.lit).h, lch(t.cta).h).toFixed(1)}°，四階全部同號，深色亦然（G23① 的 cta 那一列就在驗這件事）。</p>`;
};

/* ── 號碼帶的褪色階：這一稿唯一「只有褪色相紙才長得出來」的東西 ────
   卡紙的語言裡，一張卡片不會因為被用過而變淡。 */
const stubLadder = (t) => {
  const q = (k) => {
    const s = T.light.grad[k];
    return { dh: Math.abs(dHue(lch(s[0][0]).h, lch(s[2][0]).h)), dl: Math.abs(lch(s[0][0]).L - lch(s[2][0]).L), c: (lch(s[0][0]).C + lch(s[2][0]).C) / 2, e: dE(s[0][0], s[2][0]) };
  };
  const where = { 3: '已產生／審核關閉／AX 票根', 2: '有 1 個人在等（單人板）', 1: '有 4 個人在等（多人板）', 0: '只在這張規格板上' };
  return `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.m}px;margin-bottom:${SP.xxl}px">
    <span style="${TY.l};color:${t.ink};${press(t)}">號碼帶的褪色階 ＝ 還可以用幾次</span>
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">票根是照相館的取件存根。<b style="color:${t.ink}">號碼帶是印上去的染料（會褪），號碼本身是碳墨（不會褪）</b>—— 這正是整個 app 的粉的出處（彩色沖印的青染料先死）。所以這組碼<b style="color:${t.ink}">每被用掉一次，號碼帶就往「乾淨的紙」褪一階，而號碼永遠讀得到</b>。送出申請的當下就算用掉一次（不是核准才算），所以待核清單裡用這組碼送出的人數＋剩餘次數 ＝ ${USES_TOTAL}；有人是用上一組碼進來的，攤開的那張待核卡上寫著他用的是哪一組。<b style="color:${t.ink}">卡紙做不出這件事</b>：一張卡片不會因為被用過而變淡；一張相紙會。</span>
    ${STUB_USES.map((n) => {
    const v = q(stubOf(n));
    return `<div style="display:grid;grid-template-columns:150px 96px 1fr;gap:${SP.l}px;align-items:center">
        <div data-grad="${stubOf(n)}" style="height:${FIX.tap}px;border-radius:8px;background:${gradCss(t, stubOf(n))};border:${FIX.hair}px solid ${t.edge};display:flex;align-items:center;justify-content:center">
          <span style="font-family:${MONO};${TY.cap};color:${t.ink};${press(t)}">${CODE}</span>
        </div>
        <span style="${TY.l};color:${t.ink};white-space:nowrap">還可以用 ${n} 次</span>
        <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">Δh ${v.dh.toFixed(1)}° · ΔL* ${v.dl.toFixed(2)} · C* ${v.c.toFixed(2)} · 兩端 ΔE ${v.e.toFixed(2)}　<span style="${noWt(TY.cap)};font-family:${FONT}">${where[n]}</span></span>
      </div>`;
  }).join('')}
    <!-- 第 5 輪 D4-01／D4-07①：四個狀態的三格刻度，**兩個模式各畫一次**。
         第 4 輪深色只有「剛印好」那一格有樣本，所以 G29 的相鄰態 ΔE 在深色下
         根本沒有東西可以比 —— 母體宣告（MG1）會把那種空格判成 FAIL，
         而補樣本的正確位置就是規格板：它本來就是拿來把階排出來看的。 -->
    <div style="display:flex;flex-direction:column;gap:${SP.s}px;margin-top:${SP.s}px">
      <span style="${TY.l};color:${t.ink};${press(t)}">三格刻度的四個狀態（左：淺色／右：深色）</span>
      <div style="display:flex;gap:${SP.xxl}px;flex-wrap:wrap">
        ${[T.light, T.dark].map((th) => `<div${th.dir < 0 ? ' data-mode="dark"' : ''} style="display:flex;flex-direction:column;gap:${SP.s}px;padding:${SP.m}px;border-radius:10px;background:${th.board}">
          ${STUB_USES.map((n) => `<span style="display:inline-flex;align-items:center;gap:${SP.s}px">${stubScale(th, { uses: n })}<span style="${TY.cap};color:${th.ink}">${usesLine(n)}</span></span>`).join('')}
        </div>`).join('')}
      </div>
      <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}"><b style="color:${t.ink}">還沒用的格畫的是當前階</b>（與號碼帶同一支漸層，實測 ΔE ${'0'}），<b style="color:${t.ink}">用掉的格褪到底並蓋一道朱筆銷記</b>（照相館在存根上劃掉用過的那一格；那一道是有提按的真筆跡，不是 CSS 的叉——但它是紅筆不是蠟筆，與字標<b>刻意</b>不同支）。G29 逐格對位比，而<b style="color:${t.ink}">兩個門檻取的統計量刻意不一樣</b>：<b style="color:${t.ink}">相鄰兩態取三格裡的最大值</b>（≥${SCALE_DE.adj}）—— 相鄰只要求「<b style="color:${t.ink}">至少有一格變了</b>」，因為從剩 3 次到剩 2 次本來就只有一格會被劃掉；<b style="color:${t.ink}">剛印好↔用完了取最小值</b>（≥${SCALE_DE.ends}）—— 兩極端要求「<b style="color:${t.ink}">每一格都變了</b>」，因為三次全部用掉之後三格都該被劃掉。同一個 ΔE，兩個統計量，兩件不同的事。門檻本身是推導的：${SCALE_DE.band} ＝ 一個 JND（人眼剛好分得出來）、${SCALE_DE.adj} ＝ 三個 JND、${SCALE_DE.ends} ＝ 相鄰的兩倍。</span>
    </div>
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}"><b style="color:${t.ink}">三個量一起單調衰減，這是 G23④ 的斷言，不是描述</b>：褪到最後（用完了）色相位移、明度差、彩度同時趨近於零 ——<b style="color:${t.ink}">褪完了就沒有褪色的方向了</b>。這與「還沒印上號碼的空票根沒有這條漸層（沒印過的東西不會褪色）」是同一句話的兩端。第 1 輪 R4 抓的「全稿最大振幅在最惰性的面上」也在這裡結案：兩端 ΔE 雖然仍是 ${q('stub3').e.toFixed(2)}，但它是<b style="color:${t.ink}">邊緣加權</b>的 —— 膝點（${STUB_KNEE}%）到底部只剩 ${dE(T.light.grad.stub3[1][0], T.light.grad.stub3[2][0]).toFixed(2)} ΔE，號碼就坐在那一段上。</span>
  </div>`;
};

const ruleCard = (t, title, lines) => `
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
    <span style="${TY.l};color:${t.ink};${press(t)}">${title}</span>
    ${lines.map((l) => `<span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${l}</span>`).join('')}
  </div>`;

const tokensSheet = (measured) => {
  const t = T.light;
  const spec = (lines) => `<span style="font-family:${MONO};${TY.cap};color:${t.ink2}">${lines}</span>`;
  return doc(t, `
<div class="g" data-grad="paper" style="position:relative;width:980px;height:${h('Tokens.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;padding:${FIX.padSheet}px">
  <div style="display:flex;flex-direction:column;gap:${SP.m}px;margin-bottom:${SP.xxl}px">
    <span style="${TY.cap};color:${t.ink2};letter-spacing:.14em">LITTLE SPROUT · M1 設計語言</span>
    <div style="display:flex;align-items:baseline;gap:${FIX.gutter}px">
      <h1 style="${TY.d};color:${t.ink};margin:0">相簿台紙</h1>
      ${inkMark(INK.sheet, t.ink, t.ink2)}
    </div>
    <p style="${TY.b};color:${t.ink2};margin:0;max-width:660px">整個 app 是一張<b style="color:${t.ink}">相簿的台紙</b>。<b style="color:${t.ink}">凹進去＝可以填東西進去</b>、<b style="color:${t.ink}">浮起來＝可以按</b>、<b style="color:${t.ink}">平印上去＝只能讀</b>。三種表面，一種一個意思。<b style="color:${t.ink}">例外只有下面列出來的那幾個 —— 沒印在這張板上的例外，就是 bug。</b></p>
    <p style="${TY.b};color:${t.ink2};margin:0;max-width:660px"><b style="color:${t.ink}">為什麼是粉。</b>彩色沖印的青色染料衰退得最快，所以家裡那本相簿與它的台紙，會一年一年往洋紅偏過去 —— 粉不是一層濾鏡，是<b style="color:${t.ink}">家庭記憶會變成的顏色</b>。四階台紙因此不是同一支粉的四個明度，而是四種老化狀態：<b style="color:${t.ink}">lit</b> 還沒被翻過的新紙、<b style="color:${t.ink}">board</b> 台紙本體、<b style="color:${t.ink}">board-2</b> 凹處的陰影（偏冷）、<b style="color:${t.ink}">board-3</b> 翻動最多、有手澤的那一面（偏暖）。主按鈕的濃玫瑰則是<b style="color:${t.ink}">同一支粉還沒褪色時的樣子</b>。</p>
    <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">實測資料 #${MEAS_HASH}（量於 ${M.measuredAt || '尚未量測'}）—— 這張板上每一句「實測」都出自這一份 measured.json。產物與量測不同版時管線 FAIL（G21），所以板上的數字不可能是上一版的。</span>
  </div>

  <div style="display:grid;grid-template-columns:repeat(3, minmax(0, 1fr));gap:${FIX.gutter}px;margin-bottom:${SP.xxl}px">
    <div${S('win', 'field')} style="${win(t, { role: 'field', pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.ink}">凹 · 可以填</span>
      ${spec(`border ${FIX.hair}px edge · radius 12<br>漸層 win：<b style="color:${t.ink}">上暗下亮</b>（光被開窗上緣擋住）<br>inset 0 1.5px 0 bevelTop / 0 4px 6px -3px bevelSoft / 0 -1.5px 0 bevelBot`)}
    </div>
    <div${S('raise', 'button')}${CTA} style="${raise(t, { g: 'cta', lip: t.ctaDeep })};padding:${SP.l}px;color:${t.onCta};display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.onCta}">浮 · 可以按（兩層）</span>
      <span style="font-family:${MONO};${TY.cap};color:${t.onCta}">radius 14 · border-bottom ${FIX.lip}px ＋ 落影 0 1px 0 / 0 8px 16px -10px<br>漸層 face／cta：<b>上亮下暗</b>（凸面朝上受光）<br>沒有第三層：inset topLight 已移除</span>
    </div>
    <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};display:flex;flex-direction:column;gap:${SP.s}px">
      <span style="${TY.l};color:${t.ink};${press(t)}">平印 · 只能讀</span>
      ${spec(`border ${FIX.hair}px edge · radius 12/14/18<br><b style="color:${t.ink}">沒有漸層</b>（只能讀的東西不接光）<br>沒有 inset、沒有 lift；字加 letterpress：text-shadow press`)}
    </div>
  </div>

  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${FIX.gutter}px;margin-bottom:${SP.xxl}px">
    ${ruleCard(t, `「凹」分兩族（第 3 輪；第 2 輪是一張八個角色的白名單，一路漂移）`, [
      `第 2 輪 reviewer 的判定：「凹＝可以填」的白名單養到八個角色，因為那八個<b>其實不是同一件事</b>。本輪拆兩族，各有自己的白名單、自己的深度，G5 分兩條斷言，而且第三條驗「兩族的實測深度真的不同」——不然「兩族」只是兩個標籤。`,
      `<b>inset-fillable（這個洞是空的，等著被填）</b>：${INSET_KEYS.fillable.map((k) => `<code>${k}</code>`).join(' · ')}。深一階：上下緣 ${INSET_DEPTH.fillable.edge}px、內影 offset ${INSET_DEPTH.fillable.off}／blur ${INSET_DEPTH.fillable.blur}。`,
      `<b>inset-mount（這個洞已經有東西鑲在裡面）</b>：${INSET_KEYS.mount.map((k) => `<code>${k}</code>`).join(' · ')}。淺一階：上下緣 ${INSET_DEPTH.mount.edge}px、內影 offset ${INSET_DEPTH.mount.off}／blur ${INSET_DEPTH.mount.blur}。鑲好的東西是齊平的，不該還看得到一圈深槽。`,
      `<b>離開白名單的兩個</b>：<code>seam</code>（台紙壓過照片的裁邊）不是洞，是紙躺在上面 —— 改成第四種表面 <code>fold</code>（摺邊），只有一道零模糊的受光邊；<code>switchOff</code> 併進 <code>switchTrack</code>：軌道在 ON／OFF 都是<b>同一個凹槽</b>，差別只有槽裡填什麼（第 2 輪 ON 是浮起的、OFF 是凹的 —— 同一個實體在兩個狀態裡從凸變凹，物理上講不通）。`,
      `<b>tray</b> 登入鍵的台紙托盤（第 2 輪新增）——歡迎頁最重的兩塊是別人的品牌（Apple 對台紙 ΔE ${dE(L.appleBg, L.board).toFixed(1)}、Google ${dE(L.googleBg, L.board).toFixed(1)}，我們自己的 0）。<b>改法不是把它們調暗，是在台紙上挖一個凹槽讓它們坐進去</b>：改自己的東西，不改別人的東西。<b style="color:${t.ink}">第 3 輪兩件事</b>：① 托盤<b>不畫四邊描邊</b>（紙上壓出來的凹槽沒有輪廓線 —— 依這一稿自己的幾何判準「四邊等寬＝描邊」，第 2 輪那圈 1px 描邊蓋過了凹本身）；② R5 三選一表態，見下一張卡。`,
      measured.insetLine,
    ])}
    ${ruleCard(t, 'R5 三選一：托盤要怎麼把三顆別人的鍵收編進來（表態＝②）', [
      `<b>① 托盤加深到 ΔE ≥ 12 —— 不做。</b>那個度量本身是錯的目標：Apple 的規範指定純黑／純白、Google 指定白底四色標，跟它們比「誰的色塊比較重」是<b>定義上贏不了</b>的軍備競賽；而且要壓到 ΔE 12 得再生一階台紙色（第五階），托盤就從「挖出來的槽」變成「另一張卡」，反而更像三顆鍵坐在別人家。`,
      `<b>③ 撤掉收編目標 —— 不做。</b>歡迎頁是全 app 唯一一次「我們是誰」有機會被說出來的地方。`,
      `<b>② 托盤上緣壓自家材質 —— 做這個。</b>托盤的上緣就是一條<b>騎縫線</b>（perf），它是這一稿自己的材質、出處是票根（撕下來的那條邊）。它說的是：<b>這個槽是從我們自己那張紙上撕下來的，三顆鍵是放進我們的印刷品裡的東西</b>。收編靠的是自家的材質跨過邊界，不是自家的色塊比較大聲。加上 outline:false，托盤現在只有三個邊界：上緣的騎縫線、左右與下緣那道內影。`,
      `實測：三顆鍵與托盤面的 ΔE ${measured.trayLine}`,
    ])}
    ${ruleCard(t, '色的例外，逐條列出', [
      '<b>芽綠＝把關的機制正在生效</b>：① 加入流程的「申請已送出」；② 審核開關 ON 的軌道。<b>在粉的世界裡綠是補色，一出現就搶眼 —— 正因為如此，全稿只給它這兩個使用點。第三個綠色就是 bug。</b>',
      '<b>朱（紅筆）＝改錯與危險</b>：長輩認得的那支紅筆。① 輸入錯了（2pt 線＋一行字）；② 審核關閉時開關列的 3pt 唇邊與警語條。同一畫面最多兩處。<b>它刻意不是主按鈕那支粉</b>：一個是橘紅、一個是玫瑰，而且錯誤永遠是線與字、主按鈕永遠是實心塊。',
      '<b>濃玫瑰每畫面最多一個</b>（算的是最外層的區塊）。<b>歡迎頁一個都沒有</b>——三顆登入鍵的優先序由順序與品牌規範決定，不由我們的色決定；審核關閉、等待核准也沒有——沒有值得推薦的動作。',
      '<b>亮面 lit 只有一個使用點</b>：審核關閉時的警語條。它是台紙最亮的一階，給「此刻唯一該讀的那一句」。',
      '濃玫瑰、朱、芽綠<b>永遠不當長文字色</b>（朱的錯誤句與警語是例外，13–17pt 粗體，實測 AAA）。',
      measured.ctaLine,
    ])}
  </div>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.s}px">色彩 · 淺色（實測 WCAG 2.1 對比，以漸層最不利點計）</h2>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.s}px">文字只有兩級：ink 與 ink2。edge 是全稿唯一的線色。色票畫的是每一階的實色值；帶漸層的表面另見下一張「漸層清冊」。</p>
  ${swatchRow(t, t.board, '台紙 board', '所有畫面的底。褪過色的相簿台紙，不是白。', measured.board)}
  ${swatchRow(t, t.board2, '窗底 board-2', '凹進去的地方：輸入框、六格。偏冷 —— 陰影是冷的。', measured.board2)}
  ${swatchRow(t, t.board3, '次要面 board-3', '次要按鈕、票根下緣、待核列、開關列。偏暖 —— 翻最多的地方有手澤。', measured.board3)}
  ${swatchRow(t, t.lit, '亮面 lit', '審核關閉時的警語條 —— 此刻唯一該讀的那一句。', measured.lit)}
  ${swatchRow(t, t.ink, '墨 ink', '標題、輸入值、主要文字、手寫字標。', measured.ink)}
  ${swatchRow(t, t.ink2, '淡墨 ink-2', '說明、標籤、註記、placeholder。只有兩級文字。', measured.ink2)}
  ${swatchRow(t, t.cta, '濃玫瑰 CTA', '主要按鈕底色 —— 同一支粉還沒褪色時的樣子。每畫面最多一個。', measured.cta)}
  ${swatchRow(t, t.pen, '朱 pen', '改錯與危險：錯誤線、錯誤句、警語條、關閉時的唇邊。一張板最多兩處。', measured.pen)}
  ${swatchRow(t, t.sprout, '芽綠 sprout', '把關的機制正在生效。粉的補色，所以全稿只有兩個使用點。', measured.sprout)}
  ${swatchRow(t, t.edge, '切邊 edge', '開窗邊、分隔線、未走的步驟段。非文字，走 1.4.11 的 3:1。', measured.edge)}
  ${swatchRow(t, t.googleLine, '品牌描邊 googleLine', 'Google 鍵自己規範的描邊色。第 2 輪讓它兼差當唇邊，第 1 輪 R6 裁定那是巧合不是融入 —— 本輪兩顆品牌鍵完全不動（G25 逐個子樹掃）。', measured.brand)}
  ${swatchRow(t, t.knob, '把手 knob', '系統開關的把手。四種組合（淺／深 × ON／OFF）都是同一個顏色 —— 它是同一個零件。解剖照官方 kit。', measured.knob)}

  <h2 style="${TY.c};color:${t.ink};margin:${SP.xxl}px 0 ${SP.s}px">溫度是量出來的 · 四階台紙的 LCh（G23 逐項斷言）</h2>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.m}px">「凹處偏冷、手澤偏暖」以前只是一句話。這一輪它是一組常數：<b style="color:${t.ink}">相對台紙本體的色相角，淺色與深色共用同一組 TEMP，容差 ±${TEMP_TOL}°</b>。第 1 輪的深色四階色相全落 6.5° 之內 —— 正是設計自己說它不是的那個東西（一個色相的四個明度）。修法是「固定 L*、只轉色相」：L* 與 WCAG 的相對亮度一一對應，所以變的只有溫度 —— 但<b style="color:${t.ink}">「對比一位元都沒動」這句話字面上是假的</b>（第 2 輪板上就是這樣寫的）：sRGB 是 8 bit，固定 L* 轉色相之後每個通道會各自進位一次，<b style="color:${t.ink}">實測整批對比變動 ${LIT_DELTA.rot}:1 以內</b>。同一段裡的「−18.95°」也要限定範圍：<b style="color:${t.ink}">那個數只對實體 token 成立</b>（board／board2／board3／lit／cta），漸層端點各自順著自己那一支的光走，兩端跨距最大到 ${LIT_DELTA.gradSpan}°。<b style="color:${t.ink}">本輪 lit 換色是另一筆帳</b>：為了讓最亮那一階真的有溫度（見下一段），lit 的 L* 從 96.6 降到 ${lch(t.lit).L.toFixed(2)}，用到 lit 的每一組配對<b style="color:${t.ink}">對比實測最多變動 ${LIT_DELTA.lit}:1</b>，最低的一組仍是 ${LIT_DELTA.worst}（AAA 門檻 ${asRatio(CONTRAST.aaa)}）。用 CIELAB（D65／sRGB），算式與 gate 是同一份函式。</p>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.m}px"><b style="color:${t.ink}">第 3 輪：門檻從角度改成 ΔE。</b>角度在低彩度上等於沒有溫度 —— 淺色 lit 第 2 輪宣告 +6.0°、實測 +6.05°，這一項一路綠燈，可是它的 C* 只有 4.2，那 6° <b style="color:${t.ink}">單獨貢獻的 ΔE 只有 0.51</b>，在 JND（≈1）之下：「四階台紙有溫度層次」這句話在最亮的那一階上是量得出來的假。所以 G23① 現在驗的是「固定 L* 與 C*、把色相轉回台紙本體，兩者的 ΔE ≥ ${HUE_DE_MIN}」，而 lit 真的把溫度做出來了（TEMP +6.0 → +${TEMP.lit}、色 #FEF3F0 → ${t.lit}、實測 ΔE ${hueDE(t, 'lit').toFixed(2)}）。順帶治好第二個病：第 2 輪 lit +6.05° 與 board3 +6.71° 幾乎同溫，四階其實只有三種溫度。</p>
  ${lchTable(t)}

  <h2 style="${TY.c};color:${t.ink};margin:${SP.xxl}px 0 ${SP.s}px">漸層 · ${GRAD_KEYS.length} 種，每一種都要有物理上的理由</h2>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.m}px">全稿只有<b style="color:${t.ink}">一個光源假設</b>（淺色從上、深色從下）與<b style="color:${t.ink}">一個時間假設</b>（見光的那一邊先褪）。寫法只有一種：<code>linear-gradient(180deg, 上 0%, 下 100%)</code> —— <b style="color:${t.ink}">斜的漸層量不出「字底下最不利的那一點」，所以斜的漸層一律不准壓字，管線直接 FAIL</b>。${measured.gradLine}</p>
  <p style="${TY.cap};color:${t.ink2};margin:0 0 ${SP.m}px"><b style="color:${t.ink}">光與時間分家（G23④，本輪新增）。</b>第 1 輪 reviewer 的裁定：平印面上唯一的漸層（號碼帶）不能只是「一支振幅比較大的光」，否則「時間」這個豁免就是自圓其說。所以現在有兩條量得出來的分界：<b style="color:${t.ink}">① 光只改明度</b>——win／win3／face／cta 兩端色相差 ≤${LIGHT_DH}°（實測最大 ${Math.max(...LIGHT_KEYS.map((k) => Math.abs(dHue(lch(T.light.grad[k][0][0]).h, lch(T.light.grad[k].at(-1)[0]).h)))).toFixed(1)}°）；<b style="color:${t.ink}">時間會改色相</b>——台紙泛黃 ${Math.abs(dHue(lch(T.light.grad.paper[0][0]).h, lch(T.light.grad.paper[1][0]).h)).toFixed(1)}°、剛印好的號碼帶 ${Math.abs(dHue(lch(T.light.grad.stub3[0][0]).h, lch(T.light.grad.stub3[2][0]).h)).toFixed(1)}°，門檻 ≥${TIME_DH}°。<b style="color:${t.ink}">② 光是等速的、時間不是</b>——除了號碼帶，全部是兩個色停（0%／100%）；號碼帶是<b style="color:${t.ink}">三個色停</b>，${STUB_KNEE}% 之內就褪完（膝點吃掉 ${Math.round(STUB_AT_KNEE * 100)}% 的變化），剩下 ${100 - STUB_KNEE}% 幾乎沒動。那是「只有露在外面的那一段見得到光」的形狀，不是光的形狀 —— 也因此小字（「邀 請 碼」）落在會褪的那一段，號碼落在褪不動的那一段。</p>
  <div style="display:flex;flex-direction:column;gap:${SP.s}px;margin-bottom:${SP.m}px">
    ${GRAD_KEYS.map((k) => `<div style="display:grid;grid-template-columns:120px 260px 1fr;gap:${SP.l}px;align-items:start;padding:${SP.m}px 0;border-bottom:${FIX.hair}px solid ${t.edge}">
        <div data-grad="${k}" style="height:${FIX.tap}px;border-radius:10px;background:${gradCss(t, k)};border:${FIX.hair}px solid ${t.edge}"></div>
        <div style="display:flex;flex-direction:column;gap:${SP.xs}px">
          <span style="${TY.l};color:${t.ink}">${k}${TIME_KEYS.includes(k) ? '　<span style="color:' + t.ink2 + '">時間</span>' : LIGHT_KEYS.includes(k) ? '　<span style="color:' + t.ink2 + '">光</span>' : ''}</span>
          <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">${T.light.grad[k].map(([c, p]) => `${c} ${p}%`).join(' → ')}<br>深色 ${T.dark.grad[k].map(([c, p]) => `${c} ${p}%`).join(' → ')}</span>
        </div>
        <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${GRAD_WHY[k]}</span>
      </div>`).join('')}
    <!-- 第 5 輪：騎縫線離開漸層清冊（它現在是遮罩挖出來的洞，不是背景）。
         這一格畫的是實物：左邊完整圓孔（票根，還沒撕）、右邊半圓扇貝邊（托盤，撕下來的那一邊）。 -->
    <div style="display:grid;grid-template-columns:120px 260px 1fr;gap:${SP.l}px;align-items:start;padding:${SP.m}px 0;border-bottom:${FIX.hair}px solid ${t.edge}">
      <div style="display:flex;flex-direction:column;gap:${SP.xs}px">
        <div style="display:flex;flex-direction:column">
          <div style="height:${SP.l}px;background:${t.board3};${perfMask('bottom')}"></div>
          <div style="height:${SP.l}px;background:${t.board3};${perfMask('top')}"></div>
        </div>
        <div style="height:${SP.xl}px;background:${t.board3};${perfMask('top')}"></div>
      </div>
      <div style="display:flex;flex-direction:column;gap:${SP.xs}px">
        <span style="${TY.l};color:${t.ink}">perf（不是漸層）</span>
        <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">mask r=${PERF.r} pitch=${PERF.pitch}<br>缺口 r=${PERF.notch}／AX 齒距 ${ax(PERF.pitch)}</span>
      </div>
      <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${PERF_WHY}</span>
    </div>
  </div>
  ${stubLadder(t)}
  <div style="display:grid;grid-template-columns:repeat(3, minmax(0, 1fr));gap:${FIX.gutter}px;margin-bottom:${SP.xxl}px">
    ${Object.entries(NO_GRAD_WHY).map(([k, v]) => ruleCard(t, `刻意沒有漸層：${k}`, [v])).join('')}
  </div>

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
      <!-- 待使用者裁決的那一顆：上呈的是色票不是 hex（第 2 輪 reviewer 裁「准」，但要求把對照畫出來） -->
      <div${S('flat')} style="${flat(t, { pad: `${SP.m}px`, radius: 12 })};margin-top:${SP.m}px;display:flex;flex-direction:column;gap:${SP.s}px">
        <span style="${TY.l};color:${t.ink};${press(t)}">深色主按鈕的那一支粉（送使用者看的是這三塊色，不是 hex）</span>
        <div style="display:flex;gap:${SP.s}px;align-items:stretch">
          ${[[L.cta, '淺色主按鈕', '同一支粉還沒褪色的樣子'], [D.ctaBusy, '深色·第 2 輪原案', '直接把淺色那支提亮'], [D.cta, '深色·本案', '同 L*C*，只把色相轉冷']].map(([hex, name, why]) => `
            <div style="flex:1;display:flex;flex-direction:column;gap:${SP.xs}px">
              <div style="height:56px;border-radius:8px;background:${hex};border:${FIX.hair}px solid ${t.edge}"></div>
              <span style="${TY.cap};color:${t.ink};${press(t)}">${name}</span>
              <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">${why}</span>
            </div>`).join('')}
        </div>
        <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}">為什麼要動：染料必須比它印上去的那張泛黃的紙<b style="color:${t.ink}">冷</b>（TEMP.cta = ${TEMP.cta}°，兩個模式共用同一個常數）。深色第 2 輪那一支相對深色台紙是<b style="color:${t.ink}">暖</b>的，等於在深色裡把整個「褪色」的方向講反。本案固定 L* ${lch(D.cta).L.toFixed(1)} 與 C* ${lch(D.cta).C.toFixed(1)}、只把色相轉到 ${dHue(lch(D.cta).h, lch(D.board).h).toFixed(1)}°，所以按鈕上的墨字對比沒有動（漸層上端 ${cr(D.onCta, gc(D, 'cta', 0))}／下端 ${cr(D.onCta, gc(D, 'cta', -1))}，都是 AAA）。<b style="color:${t.ink}">這是在使用者核定的「粉」上動刀，所以列出來等裁決。</b></span>
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
      [`lip ${FIX.lip} · errBar ${FIX.errBar} · hair ${FIX.hair} · knob ${FIX.knob}`, '唇邊、錯誤線、切邊、開關把手的間隙（knob 是推導值：(switchH−switchKnob)÷2）'],
      [`switchW ${FIX.switchW} · switchH ${FIX.switchH} · switchKnob ${FIX.switchKnob}`, '系統開關的解剖 —— 照 Apple 官方 design kit（iOS 27）；第 1 輪自己畫的是 56×32／26，長得像但不是系統那一個'],
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
      [TY.b, '家人給你的 6 個字母和數字', '17/25 400 · body（600 是同一階的另一個字重）'],
      [TY.l, '家庭名稱', '15/21 600 · subheadline · 欄位標籤、待核列的「查看」'],
      [TY.cap, '有效到 8 月 30 日', '13/18 500 · footnote · 最小字級'],
      [TY.n2, CODE, '36/40 600 mono · 分格輸入'],
    ].map(([sty, sample, note]) => `<div style="display:flex;align-items:baseline;gap:${SP.l}px">
          <span style="${sty};color:${t.ink}">${sample}</span>
          <span style="font-family:${MONO};${TY.cap};color:${t.ink2}">${note}</span></div>`).join('')}
      <div style="display:flex;align-items:baseline;gap:${SP.l}px">
        <span style="${TY.n1};color:${t.ink}">${CODE.split(' ')[0]}</span>
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
      `<b>${FIX.lip}pt 唇邊＝該表面的深一階</b>：濃玫瑰→ctaDeep、台紙→edge、朱→pen。唇邊的判準是<b>幾何的</b>：下緣比上緣厚才算唇邊，四邊等寬的是描邊 —— 所以品牌鍵那條 ${FIX.hair}px 規範描邊<b>不會</b>被算成唇邊（第 1 輪 R6）。${measured.lipLine}`,
      `<b>漸層以「字底下最不利的那一點」計對比</b>：不是取兩端平均，也不是取元素中心 —— 逐個文字節點量它覆蓋到的那一段漸層，取其中對比最低的一點，門檻 ${CONTRAST.aaa}:1。<b>量不了就不准壓字</b>：只有 180deg 的線性漸層量得出這個點，其他方向一律 FAIL。顆粒層（紙的雜訊）另外以「最暗的那一格」重算一次，下限 ${CONTRAST.grain}:1。${measured.gradLine}`,
    ])}
    ${ruleCard(t, `字標「${BRAND}」＝手寫「萌芽」＋系統字「日記」`, [
      `手寫的那兩個字是全稿唯一的非系統線條，第 6 輪起是<b>一隻手用蠟筆寫在紙上的真跡</b>（描成向量，配方與來源雜湊在 ink.mjs／trace.py，G33 驗）。第 1–5 輪它是程式生成的貝茲筆跡 —— 工藝上站得住（提按、收鋒、配平過的光學密度），使用者的判決是「很醜」：那不是規格層的問題，是 glyph 品質層的否決，所以換的是<b>字樣本身</b>，規則一條都沒換。蠟筆的崩邊顆粒刻意留著（描摹容差 ${Ink.TRACE.eps} 原圖像素；再平滑一階就開始像麥克筆）。兩字的字距、下沉與參差<b>不是我們排的</b> —— 是寫的人自己那樣寫的；我們量過才決定不動它：<b>字間的白 ${INK_GAP.gap.toFixed(1)} 個字身單位，比左字最大的反白 ${INK_GAP.left.toFixed(1)}、右字 ${INK_GAP.right.toFixed(1)} 都窄</b>（窄 ${((1 - INK_GAP.gap / Math.min(INK_GAP.left, INK_GAP.right)) * 100).toFixed(1)}%），所以它讀成一個詞而不是兩個字。這三個數是從 path 自己算的（even-odd 光柵化、${INK_GAP.n} 個反白），不是目測 —— 換字樣就會重算，G33⑤ 驗它。`,
      `<b>為什麼四個字不全部手寫</b>：「萌」十四筆、「記」十筆。信件明細那一格的字標只有 ${INK.mail.h}pt 高，四字全手寫的話每一筆不到 1.3pt、筆與筆的空隙不到 1pt —— 對長輩就是一團墨。所以 lockup 分兩層：<b>手寫的是名字的意思（萌芽），系統字的是東西的種類（日記）</b>。險只冒在一個地方；而且「日記」是真的文字，會跟著 Dynamic Type 長大。`,
      `五個使用點，手寫字高／系統字級／間距：歡迎頁手機 ${INK.phone.h}／${INK.phone.sub}／${INK.phone.gap}、iPad ${INK.pad.h}／${INK.pad.sub}／${INK.pad.gap}、這張規格板 ${INK.sheet.h}／${INK.sheet.sub}／${INK.sheet.gap}、信件明細的「寄件人」${INK.mail.h}／${INK.mail.sub}／${INK.mail.gap}、建立家庭的即時預覽 ${INK.preview.h}／${INK.preview.sub}／${INK.preview.gap}。最小的兩個從 20 提到 ${INK.mail.h}，理由同上。畫面上看到的筆跡，信箱裡也會看到同一支。`,
      '它<b>不壓在照片上</b>（照片上的對比無法定義）—— 它在台紙上，ink/board 實測 ' + measured.inkContrast + '。',
      `ios-dev：手寫那塊出成單一 SVG asset（兩個字一個檔）＋<code>Image(decorative:)</code>；「日記」是 <code>Text</code>（<code>.tracking</code> 0.16em、weight 500）。整組包一層 <code>.accessibilityElement(children: .ignore)</code>＋<code>.accessibilityLabel("${BRAND}")</code> —— 讀螢幕的人聽到產品全名一次，不是「萌芽」加「日記」兩次。深色模式只換 fill。`,
    ])}
  </div>
</div>`);
};

/* ─────────────────────  APP ICON ＋ LOGO（第 2 輪新增交付）─────────────────────

   題目：褪色相紙的語言怎麼進 1024 見方。

   **決定：圖示＝字標的落款印，只取「芽」一個字，印在台紙上。**
   三個理由，每一個都可以否證：
     ① 它是我們唯一抄不走的資產。字標的筆跡是這個 app 的識別；圖示是它的印章版。
     ② 60pt 站得住。四個字裡「萌」十四筆、「記」十筆、「日」四筆、「芽」八筆 ——
        在 60pt（＝ 120px @2x、扣掉安全區約 88px 見方）之內，十四筆會糊成一團墨。
        取「芽」不是取巧：它同時就是英文名 Little Sprout 的意思。
     ③ 它承接概念而不是複製畫面。台紙的 paper 漸層（上緣先泛黃）是背景層，
        墨是前景層 —— 分層正好對上 Liquid Glass 的分層圖示：系統要的就是
        「一張底、一個前景形狀」，我們的語言本來就是這樣長的。

   刻意**不做**的三件事（沒印出來的例外就是 bug）：
     · 不放票根：票根是「邀請」這件事的物件，不是整個 app 的物件。
     · 不放照片：圖示裡放照片會變成相框 app，而且照片是使用者的，不是我們的。
     · 不放四個字：見理由②。

   分層與網格照官方 App Icon Template（iOS/iPadOS 27）：1024 見方、系統套 squircle 遮罩，
   內容留在中央安全圓內；最終生產走 Xcode 的 Icon Composer（我們交兩層 SVG／PNG）。 */
const ICON = Icon.ICON, SEAL_FRAC = Icon.SEAL_FRAC, CARVED = Icon.SEAL;
/* 使用者裁決（第 6 輪中途）：字形 icon 的概念整個被否決。日期與後續寫成常數，
   因為 canvas.json 的註記模板不准手打阿拉伯數字（G20③）—— 一切數字都要有出處。 */
const ICON_VETO = {
  when: '2026-08-23',
  next: '外部 icon 素材正在另外生成中，下一輪整合；在那之前這張板不重做、也不換字樣（換字樣只會做出一顆一樣被否決的東西）。',
};
/* 三種外觀的前景與底。Tinted 的底是**官方的中灰玻璃**：Apple design kit（iOS 27）
   匯出的 kit-AppIcons 第三排（Tinted 那一排），整排像素的眾數就是 rgb(128,128,128)。
   第 2 輪拿純黑當 Tinted 的驗收底 —— 黑底會讓任何白色前景都好看，等於沒有驗。 */
/* 有漸層的底，對比一律量在**最不利的那一端**（與 G22② 同一條規則的圖示版）。 */
const worstEnd = (fg, stops) => stops.map(([c]) => c).reduce((a, b) => (Icon.contrast(Icon.rgbOf(fg), Icon.rgbOf(b)) < Icon.contrast(Icon.rgbOf(fg), Icon.rgbOf(a)) ? b : a));
const APPEAR = () => ({
  淺色: { fg: T.light.ink, bg: gradCss(T.light, 'paper'), cmp: worstEnd(T.light.ink, T.light.grad.paper), note: '底＝台紙的 paper 漸層（上緣先泛黃），墨＝ink。對比量在漸層最不利的那一端。' },
  深色: { fg: T.dark.ink, bg: gradCss(T.dark, 'paper'), cmp: worstEnd(T.dark.ink, T.dark.grad.paper), note: '同一支墨翻成 ink；底走深色的 paper 漸層。光源翻面在這裡也成立。' },
  Tinted: { fg: Icon.TINT_FG, bg: Icon.TINT_BASE, cmp: Icon.TINT_BASE, note: `底＝官方中灰玻璃 ${Icon.TINT_BASE}（取樣自 kit-AppIcons 第三排）。系統只吃前景層的形狀，所以前景必須自己站得住。` },
});
const iconArt = (look) => `<div style="position:relative;width:${ICON}px;height:${ICON}px;background:${look.bg};display:flex;align-items:center;justify-content:center">
      <div style="position:relative;width:${Math.round(ICON * SEAL_FRAC)}px;display:flex;align-items:center;justify-content:center">${seal(look.fg)}</div>
    </div>`;
// 落款印：只取「芽」，同一支 brush.mjs 的模型與筆序，換的是刀（CARVE 的筆寬映射）。
const seal = (color) => sealMark(Math.round(ICON * SEAL_FRAC), color, CARVED);

const iconTile = (t, label, inner, { px = 220, note = '' } = {}) => `
  <div style="display:flex;flex-direction:column;gap:${SP.s}px;align-items:flex-start">
    <div style="width:${px}px;height:${px}px;border-radius:${Math.round(px * .2237)}px;overflow:hidden;border:${FIX.hair}px solid ${t.edge};position:relative">
      <div style="width:${ICON}px;height:${ICON}px;transform:scale(${px / ICON});transform-origin:0 0">${inner}</div>
    </div>
    <span style="${TY.l};color:${t.ink}">${label}</span>
    ${note ? `<span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2};max-width:${px}px">${note}</span>` : ''}
  </div>`;

const iconSheet = () => {
  const t = T.light;
  const strokes = { 萌: 14, 芽: 8, 日: 4, 記: 10 };
  const look = APPEAR();
  const carved = Icon.strokeStats(Icon.SEAL), written = Icon.strokeStats(Icon.WRITTEN);
  const R26 = Icon.RULE;
  const tag26 = (okv) => `<b style="color:${okv ? t.sprout : t.pen}">${okv ? '✓' : '✗'}</b>`;
  /* 驗收表：三種外觀 × 四個實際尺寸 × @2x/@3x，每一格三個數（＋一個自己加嚴的）。
     這些數不是在板上手打的 —— 是 icon.mjs 把 1024 母稿真的光柵化之後算出來的，
     verify 的 G26 讀同一支函式。板上印的與 gate 判的因此不可能是兩份。 */
  const cell26 = (name, pt, sc) => {
    const m = Icon.measureAt(pt, sc, { fg: look[name].fg, bg: look[name].cmp });
    const okS = m.minStrokeDev >= R26.minStrokeDev, okC = m.coverage >= R26.coverage;
    const okK = m.contrast >= R26.contrast, okG = m.counterDev >= R26.counterDev;
    return `<td style="padding:${SP.s}px ${SP.m}px;border-top:${FIX.hair}px solid ${t.edge};${TY.cap};color:${t.ink2};white-space:nowrap">
        ${tag26(okS)} ${m.minStrokeDev.toFixed(2)}px · ${tag26(okC)} ${(m.coverage * 100).toFixed(1)}% · ${tag26(okK)} ${m.contrast.toFixed(2)}:1 · ${tag26(okG)} ${m.counterDev.toFixed(0)}px</td>`;
  };
  return doc(t, `
<div class="g" data-grad="paper" data-veto="icon-concept" style="position:relative;width:1290px;height:${h('AppIcon.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;padding:${FIX.padSheet}px">
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};border-left:${FIX.errBar}px solid ${t.pen};margin-bottom:${SP.xl}px">
    <span style="${TY.l};color:${t.ink}">這張板的概念已被否決（${ICON_VETO.when}）——底下的內容原地保留，不是現行方案</span><br>
    <span data-expired-note="板頂的否決橫幅：底下每一句「同一支筆」都已經被劃掉，這一段是宣告它們過期的那句話本身，所以它自己不劃" style="${noWt(TY.cap)};font-weight:400;color:${t.ink2};${press(t)}">使用者否決的是<b style="color:${t.ink}">「app icon ＝ 一個字」這件事本身</b>，不是這個字的筆觸、也不是它的尺寸 —— 所以換一支筆、換一個字、把它畫粗都不是修法。${ICON_VETO.next}<br><br><b style="color:${t.ink}">板上已經過期的一句話，先講在這裡</b>：底下凡是寫著「與字標<b style="color:${t.ink}">同一支筆</b>」的段落，在字標於本輪換成蠟筆之後<b style="color:${t.ink}">字面已經不成立</b> —— 這張板上的落款印是第 3 輪那支程式生成的刀。凍結的意思就是「它停在被否決的那一版」，不是「它還對」。<br><br>板上其餘每一段（分層意圖、三種外觀、驗收排、G26 的四條規格、Tinted 的中灰玻璃底）<b style="color:${t.ink}">留著是因為它們與「用哪一個圖形」無關</b>：那些是「任何一個圖示都要通過的檢查」，換素材之後照樣要跑一次。<b style="color:${t.ink}">G26／G26b／G26c 三族在這張板上暫停</b>，登記在具名豁免簿裡（<code>data-veto="icon-concept"</code> → G26），理由與恢復條件都寫在那一筆上：外部素材到位、這張板重做，就把那一筆刪掉，三族自動恢復。<b style="color:${t.ink}">刪不掉就是還沒重做</b> —— 這是豁免簿的等式在守的事（MG2）。</span>
  </div>
  <div style="display:flex;flex-direction:column;gap:${SP.m}px;margin-bottom:${SP.xxl}px">
    <span style="${TY.cap};color:${t.ink2};letter-spacing:.14em">LITTLE SPROUT · ${BRAND} · APP ICON ＋ LOGO（第 3 輪：重筆＋G26 驗收）</span>
    <h1 style="${TY.d};color:${t.ink};margin:0">落款印</h1>
    <p style="${TY.b};color:${t.ink2};margin:0;max-width:820px">Logo（字標）是<b style="color:${t.ink}">手寫「萌芽」＋系統字「日記」</b>，用在畫面裡、信件裡、任何有空間把全名說完的地方。<b style="color:${t.ink}">App icon 是它的落款印</b>：<s data-expired="字標第 6 輪換成蠟筆、而這張板上的落款印還是第 3 輪程式生成的刀：這句話的字面已經不成立，留著是否決紀錄">同一支筆、同一張紙，只取一個字。</s> 兩者的關係跟印章與署名一樣 —— 不是兩套設計，是同一套的長版與短版。</p>
    <p style="${TY.b};color:${t.ink2};margin:0;max-width:820px"><b style="color:${t.ink}">為什麼是「芽」不是「萌」</b>：${Object.entries(strokes).map(([c, n]) => `${c} ${n} 筆`).join('、')}。App icon 在主畫面是 60pt，扣掉安全區約 ${Math.round(60 * .88)}pt 見方 —— 十四筆的「萌」在那個尺寸會糊成一團墨（下面第三排是實際大小，自己看）。「芽」八筆，而且它就是英文名 Little Sprout 的意思。取筆畫少的那一個不是取巧，是<b style="color:${t.ink}">在小尺寸還讀得出來</b>這條長輩優先的硬約束。</p>
  </div>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.m}px">1024 母稿：系統從一份設計生出三種外觀</h2>
  <div style="display:flex;gap:${FIX.gutter}px;flex-wrap:wrap;margin-bottom:${SP.xxl}px">
    ${Object.entries(look).map(([k, v]) => iconTile(t, k, iconArt(v), { note: v.note })).join('')}
  </div>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.m}px">分層（照官方 App Icon Template：1024 見方、系統套 squircle、內容留在中央安全圓內）</h2>
  <div style="display:flex;gap:${FIX.gutter}px;flex-wrap:wrap;margin-bottom:${SP.xxl}px">
    ${iconTile(t, '背景層 background', `<div style="width:${ICON}px;height:${ICON}px;background:${gradCss(t, 'paper')}"></div>`, { px: 180, note: '一張紙。不放形狀、不放漸層以外的東西 —— Liquid Glass 會在它上面加自己的材質與高光，我們不搶。' })}
    ${iconTile(t, '前景層 foreground', `<div style="width:${ICON}px;height:${ICON}px;background:#00000000;display:flex;align-items:center;justify-content:center"><div style="width:${Math.round(ICON * SEAL_FRAC)}px">${seal(t.ink)}</div></div>`, { px: 180, note: '只有墨跡，透明底。它同時就是單色版的遮罩，所以形狀要自己站得住。' })}
    ${iconTile(t, '合成（系統遮罩後）', iconArt(look['淺色']), { px: 180, note: `墨跡的外框寬佔畫布 ${Math.round(SEAL_FRAC * 100)}%、垂直置中（第 2 輪是 52%）。四邊留白仍大於安全圓 —— 圓角吃不到任何一筆。` })}
  </div>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.m}px">刻的比寫的粗：為什麼 icon 用另一支筆</h2>
  <div style="display:flex;gap:${FIX.gutter}px;align-items:flex-start;margin-bottom:${SP.xxl}px">
    ${iconTile(t, `第 2 輪：寫的那支筆（中位 ${written.median.toFixed(0)}px／最細 ${written.min.toFixed(0)}px）`, `<div style="position:relative;width:${ICON}px;height:${ICON}px;background:${gradCss(t, 'paper')};display:flex;align-items:center;justify-content:center"><div style="width:${Math.round(ICON * .52)}px">${sealMark(Math.round(ICON * .52), t.ink)}</div></div>`, { px: 200, note: `20pt@2x 時最細筆畫只有 ${(written.min * 40 / ICON).toFixed(2)} 裝置像素、墨覆蓋 7.63% —— 物理上讀不出來。` })}
    ${iconTile(t, `第 3 輪：刻的那支筆（中位 ${carved.median.toFixed(0)}px／最細 ${carved.min.toFixed(0)}px）`, iconArt(look['淺色']), { px: 200, note: `同一個「芽」、同一組八筆、同一個筆序、同一支 stroke() 模型；換的是刀（筆寬映射 ×${(carved.median / written.median).toFixed(2)}、提按幅度 ×${Icon.CARVE.swell}）與章法（重新分白）。` })}
    <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};flex:1;min-width:0">
      <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2};${press(t)}"><b style="color:${t.ink}">落款印與落款題字本來就不是同一支工具</b>。題字是筆：有提按、有飛白、細處可以到一根毫。印是刀：刃有固定寬度，所以筆畫粗、提按小、收筆是切的不是拖的。第 2 輪把字標的筆直接縮小去當圖示，等於拿寫的當刻的 —— 那是這一稿自己開的藥（「小尺寸還讀得出來」）沒有自己吃。<br><br><b style="color:${t.ink}">誠實話</b>：刻的版本<b style="color:${t.ink}">中線與寫的版本不同</b>。粗了之後寫的那個間架會糊掉（草字頭的兩豎會被長橫吃掉、短撇會黏上長橫），所以重新分白 —— 那正是篆刻在做的事。<s data-expired="字標第 6 輪換成蠟筆、而這張板上的落款印還是第 3 輪程式生成的刀：這句話的字面已經不成立，留著是否決紀錄">不變的是同一個字、同一組八筆、同一個筆序、同一支筆的模型。</s> <b style="color:${t.ink}">第 4 輪這句話只是自我宣告</b>（底下那張 ${Object.keys(look).length}×${Icon.SIZES.length}×${Icon.SCALES.length} 格的表量的是可讀性，不是「同不同一個字」），所以本輪把它拆成八個可以被否證的數 —— 見下一張表。</span>
    </div>
  </div>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.s}px">逐筆中線：「重排」與「同一個字」各自是一個數</h2>
  <p style="${TY.b};color:${t.ink2};margin:0 0 ${SP.m}px;max-width:1000px">八筆逐一比對<b style="color:${t.ink}">寫的中線</b>與<b style="color:${t.ink}">刻的中線</b>（單位：字身，整個字是 100×100）。<b style="color:${t.ink}">位移</b>證明重排真的發生（全是 0 就代表只是加粗）；<b style="color:${t.ink}">角度</b>與<b style="color:${t.ink}">長度比</b>證明沒有把一筆改成另一支筆；<b style="color:${t.ink}">身分</b>是這張表的重點 —— 每一筆離自己的對應筆，比離最近的其他筆再近 ${Math.round((1 - Icon.CARVE_RULE.nearest) * 100)}%（比值 ≤${Icon.CARVE_RULE.nearest}），所以重排沒有把任何一筆搬成別的一筆。門檻的出處印在 icon.mjs 裡，G26b 判的是同一份數。</p>
  <table style="border-collapse:collapse;width:100%;margin-bottom:${SP.xxl}px">
    <tr>${['筆序（同寫的順序）', `位移（≤${Icon.CARVE_RULE.moveMax}）`, `角度差（≤${Icon.CARVE_RULE.tiltMax}°）`, `長度比（${Icon.CARVE_RULE.lenLo}–${Icon.CARVE_RULE.lenHi}）`, `身分比值（≤${Icon.CARVE_RULE.nearest}）`].map((x) => `<th style="text-align:left;padding:${SP.s}px ${SP.m}px;${TY.l};color:${t.ink}">${x}</th>`).join('')}</tr>
    ${Icon.centerlineDev().map((r) => `<tr>${[`第 ${r.i} 筆`, r.move.toFixed(2), `${r.tilt.toFixed(2)}°`, r.len.toFixed(3), r.nearest.toFixed(3)].map((v) => `<td style="padding:${SP.s}px ${SP.m}px;border-top:${FIX.hair}px solid ${t.edge};${TY.cap};color:${t.ink2};white-space:nowrap">${v}</td>`).join('')}</tr>`).join('')}
  </table>

  <h2 style="${TY.c};color:${t.ink};margin:0 0 ${SP.s}px">實際大小 × 三種外觀 —— 這一排是驗收，不是展示</h2>
  <p style="${TY.b};color:${t.ink2};margin:0 0 ${SP.m}px;max-width:1000px">四個尺寸（${Icon.SIZES.map(([px, u]) => `${u} ${px}`).join('、')}）各畫三種外觀。<b style="color:${t.ink}">第 2 輪只畫了淺色一排＋深色一顆，而且 Tinted 拿純黑當底</b>——黑底會讓任何白色前景都好看。</p>
  ${Object.entries(look).map(([k, v]) => `
  <div style="display:flex;gap:${FIX.gutter}px;align-items:flex-end;margin-bottom:${SP.l}px">
    <span style="${TY.l};color:${t.ink};width:120px;flex:none">${k}</span>
    ${Icon.SIZES.map(([px, use]) => `
      <div style="display:flex;flex-direction:column;gap:${SP.s}px;align-items:center">
        <div data-icon-acc="${px}" style="width:${px}px;height:${px}px;border-radius:${Math.round(px * .2237)}px;overflow:hidden;border:${FIX.hair}px solid ${t.edge}">
          <div style="width:${ICON}px;height:${ICON}px;transform:scale(${px / ICON});transform-origin:0 0">${iconArt(v)}</div>
        </div>
        <span style="${TY.cap};color:${t.ink2}">${use} ${px}</span>
      </div>`).join('')}
  </div>`).join('')}

  <h2 style="${TY.c};color:${t.ink};margin:${SP.xxl}px 0 ${SP.s}px">G26 驗收表：三條裁定的規格 ＋ 一條自己加嚴的</h2>
  <p style="${TY.b};color:${t.ink2};margin:0 0 ${SP.m}px;max-width:1000px">每一格四個數，依序是 <b style="color:${t.ink}">①最細筆畫（≥${R26.minStrokeDev} 裝置像素）· ②墨覆蓋率（≥${(R26.coverage * 100).toFixed(0)}%）· ③前景對比（≥${R26.contrast}:1）· ④反白 p05（≥${R26.counterDev} 裝置像素，自己加嚴的）</b>。①②④ 是把 1024 母稿真的光柵化（4×4 超取樣）之後算的，不是估的；④ 取第 5 百分位不取最小值，因為兩筆交會處的白會收成楔形，「恰好 1 像素」在任何解析度都必然存在 —— 最小值量的是交點不是反白。<br><b style="color:${t.ink}">這張表最薄的一格要講清楚</b>：全表最壞的前景對比是 Tinted 的 ${Icon.contrast(Icon.rgbOf(Icon.TINT_FG), Icon.rgbOf(Icon.TINT_BASE)).toFixed(2)}:1，門檻 ${R26.contrast}:1 —— <b style="color:${t.ink}">餘裕只有 ${(Icon.contrast(Icon.rgbOf(Icon.TINT_FG), Icon.rgbOf(Icon.TINT_BASE)) - R26.contrast).toFixed(2)}</b>。它<b style="color:${t.ink}">不隨尺寸變</b>，因為它是白對官方中灰玻璃這兩個顏色決定的：Tinted 模式下前景色與底色都由系統給，我們一個像素都改不動（G26 另有一條斷言：這一格在 ${Icon.SIZES.length}×${Icon.SCALES.length} 個尺寸上必須完全相同，證明它是顏色的性質不是尺寸的性質）。我們在 Tinted 這一排真正能改、也真的被驗的是<b style="color:${t.ink}">形狀</b>：墨覆蓋 ${(Icon.measureAt(20, 2, { fg: Icon.TINT_FG, bg: Icon.TINT_BASE }).coverage * 100).toFixed(1)}%、20pt@2x 最細筆畫 ${Icon.measureAt(20, 2, { fg: Icon.TINT_FG, bg: Icon.TINT_BASE }).minStrokeDev.toFixed(2)} 裝置像素。</p>
  <table style="border-collapse:collapse;width:100%;margin-bottom:${SP.xxl}px">
    <tr><th style="text-align:left;padding:${SP.s}px ${SP.m}px;${TY.l};color:${t.ink}">尺寸</th>${Object.keys(look).map((k) => `<th style="text-align:left;padding:${SP.s}px ${SP.m}px;${TY.l};color:${t.ink}">${k}</th>`).join('')}</tr>
    ${Icon.SIZES.flatMap(([px, use]) => Icon.SCALES.map((sc) => `
    <tr><td style="padding:${SP.s}px ${SP.m}px;border-top:${FIX.hair}px solid ${t.edge};${TY.cap};color:${t.ink};white-space:nowrap">${use} ${px}pt @${sc}x（${px * sc} 裝置像素）</td>${Object.keys(look).map((k) => cell26(k, px, sc)).join('')}</tr>`)).join('')}
  </table>

  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${FIX.gutter}px">
    ${ruleCard(t, 'Logo 與 App icon 的關係（一句話：長版與短版）', [
      `<b>Logo（字標）</b>＝手寫「萌芽」＋系統字「日記」。用在歡迎頁、iPad 抬頭、信件寄件人、建立家庭預覽、規格板 —— 五個使用點的字高都印在 Tokens 板上。`,
      `<b>App icon（落款印）</b>＝<s data-expired="字標第 6 輪換成蠟筆、而這張板上的落款印還是第 3 輪程式生成的刀：這句話的字面已經不成立，留著是否決紀錄">同一支筆的「芽」印在台紙上</s>。它不出現在畫面裡（畫面裡出現的一律是字標全名），只出現在系統的圖示位。`,
      '<b>不做兩套</b>：icon 不是把字標塞進方框（四個字在 60pt 讀不出來），字標也不是把 icon 加字（印章放大會失去筆跡的細節）。它們共用同一份 brush 幾何，換的只有取字與尺寸。',
      '<b>App Store 1024 用哪一個</b>：用 icon（落款印）。商店頁的名稱欄已經寫著全名，圖示再寫一次是重複。',
    ])}
    ${ruleCard(t, 'ios-dev／生產（本輪是概念稿，尚未出檔）', [
      '兩層各出一份：<code>background</code>（1024 純漸層，PNG 或 SVG）、<code>foreground</code>（1024 透明底墨跡 SVG）。用 <b>Xcode 的 Icon Composer</b> 合成，讓系統自己生 Light／Dark／Clear 三種外觀 —— 不要手動出三張 PNG。',
      '<b>不要自己畫 squircle、不要自己加圓角、不要自己加陰影或高光</b>：遮罩與 Liquid Glass 的材質是系統的事。我們只交一張紙與一團墨。',
      `墨跡的外框寬 ＝ 畫布的 ${Math.round(SEAL_FRAC * 100)}%、垂直置中（落款印自己的 viewBox ${CARVED.vb.w.toFixed(0)}:${CARVED.vb.h.toFixed(0)}，字標長版是 ${VB.w.toFixed(0)}:${VB.h.toFixed(0)}）。這兩個 bbox 都是推出來的，不是手量的。`,
      `<b>本輪尚未交付的</b>：實際 PNG／SVG 檔、Icon Composer 專案、watchOS／macOS 的變體、App Store 1024 的最終出檔。這一張板是概念與版式的定稿依據，下一輪補檔。<b>不需要再等的是幾何</b>：刻的那支筆的筆寬映射（${Icon.CARVE.lo}→${Icon.CARVE.hi}、提按 ×${Icon.CARVE.swell}）與 ${Math.round(SEAL_FRAC * 100)}% 的置中已經定案，出檔照著 icon.mjs 產就好。`,
    ])}
  </div>

  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};margin-top:${FIX.gutter}px">
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2};${press(t)}"><b style="color:${t.ink}">這張板的 gate 適用範圍（豁免要明講，不然就是靜默跳過）</b>：適用 —— G1 間距、G2 字級、G6 對比（板上的說明文字，與其他交付板同一條 AAA）、G16 原始碼衛生、G21 產物同版、G23② 平印不接光。<b style="color:${t.ink}">不適用且理由</b>：G10 呼吸帶與板高（這不是一個畫面，是交付板，與 Tokens／Notes 同類）、G11 H1 起跑線（同上，已列在 H1_EXCLUDED）、G12 深色母題（圖示沒有票根／六格／錯誤線／開關這四個母題，它本來就不該有）、G14 命中盒（板上沒有可按的東西）、G19 唇邁與開關（同上）。<b style="color:${t.ink}">第 2 輪這裡寫著「尚未有 gate：圖示在 20pt 還讀不讀得出來是目視項」——本輪它變成 G26</b>：三條裁定的規格（最細筆畫／墨覆蓋率／前景對比）＋ 一條自己加嚴的（反白 p05），三種外觀 × 四個尺寸 × 兩個倍率共 ${3 * Icon.SIZES.length * Icon.SCALES.length} 格，全部由光柵化算出來。<b style="color:${t.ink}">還是沒有 gate 的</b>：主畫面上與別的 app 並排時的辨識度（那要一整頁圖示才量得出來），以及 watchOS／macOS 的變體。</span>
  </div>
</div>`);
};

/* ─────────────────────  玻璃與紙的交界（第 3 輪新增）─────────────────────
   第 2 輪在 Apple 對照板上寫了一條刻意不照做：「不用 glassEffect —— 系統材質與紙的
   厚度疊起來會變兩套光」。reviewer 的判定是「三條裡最強，但零壓測」：那句話只是宣告，
   沒有任何一張板畫出它。這張板把它變成設計。

   關鍵是：**「不用 glassEffect」不等於「畫面上不會有玻璃」**。系統的 sheet、
   navigation bar、tab bar、鍵盤，都會用它自己的 Liquid Glass 蓋在我們的紙上面 ——
   那不是我們能否決的。能決定的只有一件事：交界處誰讓誰。 */
const glassPhone = (t, { mode }) => {
  const top = 470, sheetH = 844 - top;
  return `<div class="g" data-mode="${t.dir > 0 ? 'light' : 'dark'}" data-grad="paper" style="position:relative;width:390px;height:844px;background:${gradCss(t, 'paper')};overflow:hidden;flex:none">
    ${inviteHead(t, '邀請家人', '號碼有期限，也有可用次數。')}
    <div style="padding:${SP.xl}px ${FIX.gutter}px 0;display:flex;flex-direction:column;gap:${SP.xl}px">
      ${ticket(t, { uses: 2 })}
    </div>
    <div aria-hidden="true" data-role="glassDim" style="position:absolute;left:0;top:${top}px;width:390px;height:${sheetH}px;background:${t.glassDim}"></div>
    <div data-s="system" data-sys="glass" style="position:absolute;left:0;top:${top}px;width:390px;height:${sheetH}px;border-radius:34px 34px 0 0;background:${t.glassFill};backdrop-filter:blur(24px) saturate(1.7);-webkit-backdrop-filter:blur(24px) saturate(1.7);box-shadow:0 -0.5px 0 ${t.glassEdge};display:flex;flex-direction:column;align-items:center;padding:${SP.m}px ${FIX.gutter}px ${FIX.safeBottom}px;gap:${SP.l}px">
      <span data-sys="grabber" style="width:36px;height:5px;border-radius:3px;background:${t.edge}"></span>
      <span style="${TY.c};color:${t.ink}">傳給家人</span>
      <span style="${TY.b};color:${t.ink2};text-align:center">系統的分享表單。這一層的材質、圓角、模糊、高光全部是系統畫的 —— 我們一個像素都不出。</span>
      <div${S('flat')} style="${flat(t, { pad: `${SP.m}px ${SP.l}px`, radius: 12 })};align-self:stretch">
        <span style="${TY.cap};color:${t.ink2};${press(t)}">交界在上面那條線。線以上是紙，線以下是玻璃。</span>
      </div>
    </div>
    <div aria-hidden="true" data-role="seamMark" style="position:absolute;left:0;top:${top}px;width:390px;height:${FIX.errBar}px;background:${t.pen}"></div>
  </div>`;
};

const glassSeam = (t) => doc(t, `
<div class="g" data-grad="paper" style="position:relative;width:980px;height:${h('GlassSeam.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;padding:${FIX.padSheet}px">
  <div style="display:flex;flex-direction:column;gap:${SP.m}px;margin-bottom:${FIX.gutter}px">
    <span style="${TY.cap};color:${t.ink2};letter-spacing:.14em">LITTLE SPROUT · ${BRAND} · 系統材質 × 紙</span>
    <h1 style="${TY.d};color:${t.ink};margin:0">玻璃與紙的交界</h1>
    <!-- 第 5 輪 D4-12：這一句原本埋在板底那段小字的第三行。它是這張板上唯一一句
         「照抄會出事」的話 —— 後果最嚴重的話要排在最前面、用朱筆。 -->
    <div style="display:flex;gap:${SP.m}px;align-items:flex-start;margin-bottom:${SP.s}px">
      <div aria-hidden="true" style="width:${FIX.errBar}px;align-self:stretch;flex:none;background:${t.pen}"></div>
      <span style="${TY.bs};color:${t.pen}">這張板上的玻璃是<b>畫給人看的近似</b>，不要照抄成實作。實作就是讓系統畫 —— 我們只出交界以上那張紙。</span>
    </div>
    <p style="${TY.b};color:${t.ink2};margin:0;max-width:880px">第 2 輪寫下「不用 <code>glassEffect</code>」時，那是一句立場，不是一張設計。而且那句話容易被讀錯成「這個 app 裡不會有玻璃」——<b style="color:${t.ink}">不對</b>：系統的 sheet、navigation bar、tab bar、鍵盤都會用 Liquid Glass 蓋在我們的紙上面，那不是我們能否決的。能決定的只有交界處<b style="color:${t.ink}">誰讓誰</b>。這張板把那條線畫出來（下面兩支手機上的<span style="color:${t.pen}">朱紅細線</span>就是它），並且把四條規則寫成可以被 gate 咬的形狀。</p>
  </div>
  <div style="display:flex;gap:${FIX.gutter}px;align-items:flex-start;margin-bottom:${FIX.gutter}px">
    ${glassPhone(T.light, { mode: 'Light' })}
    ${glassPhone(T.dark, { mode: 'Dark' })}
  </div>
  <div style="display:flex;gap:${FIX.gutter}px;margin-bottom:${FIX.gutter}px">
    <div style="flex:1;min-width:0">${noteBox(t, I.eye, '兩支手機上那條<b style="color:' + t.pen + '">朱紅細線</b>就是交界。線以上是我們的紙（四階台紙、凹浮平印、褪色階），線以下是系統的玻璃。線本身當然不會出現在產品裡 —— 它是這張板的標註。')}</div>
    <div style="flex:1;min-width:0">${noteBox(t, I.clock, '深色那一支的玻璃底下是同一張紙的暗處版本：光源翻到下面（凹的受光緣、浮起的落影、壓印的亮邊全部跟著翻），但<b>玻璃的高光不跟著翻</b> —— 那是系統的光，不歸我們的 dir 管。這就是 G24 要具名豁免 [data-sys] 的原因。')}</div>
  </div>
  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${FIX.gutter}px;margin-bottom:${FIX.gutter}px">
      ${ruleCard(t, '誰讓誰：紙讓玻璃，一次讓到底', [
    '<b>玻璃贏在它自己那一層</b>：交界以下的材質、圓角、模糊、高光、抓桿，全部是系統的。我們不畫、不抄、不改、不加自己的唇邊或內影去「接住」它 —— 接住它就是把兩套光疊在一起。',
    '<b>紙贏在其他所有地方</b>：交界以上是我們的四階台紙、凹浮平印、褪色階。玻璃不會爬上來，我們也不會沉下去。',
    '<b>不互相模仿</b>：我們的表面永遠不裝成玻璃（不加 backdrop blur、不加高光弧），也不要求系統的玻璃裝成紙。兩種材質同時存在是對的；一種材質假裝成另一種才是錯的。',
    `<b>這一條是有代價的</b>：玻璃會把它下面的東西吸進自己的色裡，所以交界附近我們的紙必須保持低彩度（四階 C* ${lch(t.lit).C.toFixed(1)}–${lch(t.board3).C.toFixed(1)}）。這也是主按鈕那支濃玫瑰（C* ${lch(t.cta).C.toFixed(1)}）永遠不貼著交界放的原因。`,
  ])}
      ${ruleCard(t, '三條規則，三條斷言（第 5 輪：已經是 G30，不再是承諾）', [
    `<b>① 玻璃上的字，底下只能是台紙。</b>模糊會改變局部極值，所以「壓在玻璃上的對比」只有在底下是單一漸層時算得準。照片、票根、高振幅漸層一律不准出現在有字的玻璃底下。<b>→ G30① 逐個字節點往上找它的底</b>：在 <code>[data-sys]</code> 子樹裡的每一個文字節點，背後的第一個有背景的祖先必須是 paper 那一支。`,
    `<b>② 交界 ${SP.l}pt 之內不放我們的浮起面。</b>浮起面帶落影，落影與玻璃的邊緣高光是兩個方向的光；離太近會讀成同一個物件的兩個邊。<b>→ G30② 量距離</b>：逐個浮起面量它與交界線的最短距離，小於 ${SP.l}pt 就 FAIL（交界線自己是量出來的，不是寫死的 y）。`,
    `<b>③ 系統 chrome 一律標 <code>data-sys</code>，並豁免我們的光方向 gate（G24）。</b>系統的高光由系統決定，用我們的 dir 去驗它只會驗出假的 FAIL。豁免必須是<b>具名的</b>——沒印出來的例外就是 bug。<b>→ G30③ ＋ 豁免登記簿（MG2）</b>：第 4 輪這條規則自己被違反了——當時 <code>data-light</code> 加上任何值都能豁免，而且沒有任何一份清單記得誰被豁免。現在豁免集合<b>等於</b> tokens.mjs 的 EXEMPT 具名清單（檔案＋角色＋理由），多一個少一個都 FAIL，probe 也只認清單上的值。`,
  ])}
  </div>
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })}">
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2};${press(t)}"><b style="color:${t.ink}">給 ios-dev</b>：這張板上的玻璃是<b style="color:${t.ink}">畫給人看的近似</b>（<code>background: ${t.glassFill}</code> ＋ <code>backdrop-filter: blur(24px) saturate(1.7)</code> ＋ 上緣 0.5px 高光 <code>${t.glassEdge}</code>），<b style="color:${t.ink}">不要照抄成實作</b>。實作就是讓系統畫：sheet 用預設的 presentation background、nav/tab bar 不設自訂背景、<b style="color:${t.ink}">不要在自己的卡片上呼叫 <code>glassEffect</code></b>。我們要出的只有交界以上那張紙。<b style="color:${t.ink}">這張板的 gate 適用範圍</b>：適用 G1／G2／G6（玻璃上的字照 AAA 量，見規則①）／G16／G21／G23②。<b style="color:${t.ink}">具名豁免</b>：G24 光方向（<code>[data-sys]</code> 子樹，理由如規則③）、G10 板高與 G11 起跑線（交付板）、G19 唇邊（板上的浮起面在手機模型裡，已由來源畫面驗過）。</span>
  </div>
</div>`);

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
<div class="g" data-grad="paper" style="position:relative;width:980px;height:${h('Notes.dc.html')}px;background:${gradCss(t, 'paper')};overflow:hidden;padding:${FIX.padSheet}px">
  <div style="display:flex;flex-direction:column;gap:${SP.xs}px;margin-bottom:${FIX.gutter}px">
    <span style="${TY.cap};color:${t.ink2};letter-spacing:.14em">給 ios-dev · LS-17 / LS-18</span>
    <h1 style="${TY.h};color:${t.ink};margin:0">實作註記</h1>
  </div>
  <div${S('flat')} style="${flat(t, { pad: `${SP.l}px`, radius: 14 })};margin-bottom:${FIX.gutter}px;display:flex;flex-direction:column;gap:${SP.s}px">
    <span style="${TY.l};color:${t.ink};${press(t)}">待使用者裁決（第 3 輪；設計端已表態，但不自己決定）</span>
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}"><b style="color:${t.ink}">① 字標的 3:1 —— 本輪維持現狀，等裁。</b>手寫的「萌芽」與系統字的「日記」在 lockup 裡<b style="color:${t.ink}">不是等大的</b>（手寫 ${INK.phone.h}pt 對系統字 ${INK.phone.sub}pt，約 ${(INK.phone.h / INK.phone.sub).toFixed(1)}:1）。reviewer 的判定是：這<b style="color:${t.ink}">不是排版決定，是命名決定</b> —— 它把「萌芽」做成品牌、「日記」做成品類，等於宣告這個 app 的名字重心在前兩個字；而軌 C 把四個字做成等大，宣告的是「萌芽日記」四個字一起才是名字。<b style="color:${t.ink}">同一個名字被兩軌做成兩種身分，只有使用者能裁。</b>設計端的立場：D 軌這樣做有可否證的理由（「萌」十四筆、「記」十筆，在信件明細那一格字標只有 ${INK.mail.h}pt 高，四個字全手寫每一筆不到 ${(INK.mail.h * .05).toFixed(1)}pt，對長輩就是一團墨），但那是<b style="color:${t.ink}">為什麼只手寫兩個字</b>的理由，不是<b style="color:${t.ink}">為什麼那兩個字要比較大</b>的理由。兩者要分開看。</span>
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}"><b style="color:${t.ink}">② 深色主按鈕那一支粉</b>（Tokens 板有三塊色票對照）：在使用者核定的「粉」上動刀，reviewer 已裁「准」，仍列出等最終確認。</span>
    <span style="${noWt(TY.cap)};font-weight:400;color:${t.ink2}"><b style="color:${t.ink}">③ 邀請碼字母集</b>：排掉易混字元後的位元數要與後端 LS-33 對帳（跨軌事項，兩軌同列）。</span>
  </div>
  <div style="display:grid;grid-template-columns:repeat(2, minmax(0, 1fr));gap:${SP.l}px">
    ${note(t, '對齊 Apple 官方 design kit（iOS／iPadOS 27）—— 哪些照做、哪些刻意不照做', [
      '<b>分層是刻意的</b>：系統控件（開關、sheet、nav bar、按鈕族譜）的<b>解剖與行為</b>照官方 kit；<b>識別層</b>（凹／浮／平印三種表面、台紙、票根、褪色階）是我們的，只作用在我們自己畫的表面上。長輩在別的 app 學會的東西，在這裡要一模一樣。',
      `<b>照做並且已改</b>：系統開關的解剖 —— 軌道 <code>${FIX.switchW}×${FIX.switchH}</code>、把手 <code>${FIX.switchKnob}</code>、間隙 <code>${FIX.knob}</code>。第 1 輪自己畫的是 56×32／26／3，長得像但不是系統那一個；把手的行程差幾 pt，長輩的肌肉記憶就對不上。SwiftUI 用 <code>Toggle</code> 本體，我們只換 <code>.tint(lsSprout)</code> 與整列的表面。`,
      '<b>照做</b>：字級全部落在官方文字樣式（largeTitle 34／title1 28／title3 22／body 17／subheadline 15／footnote 13），AX1–AX5 由系統推，我們不自己算級距。',
      '<b>刻意不照做（理由）</b>：① 官方有四級標籤色（Label／Secondary／Tertiary／Quaternary），我們<b>只用兩級</b>並且兩級都 AAA —— 給長輩的 app 不需要「更淡的三種淡」，第三級以下在 7:1 底下根本活不下來。② 官方按鈕族譜每一族都有 <b>disabled</b> 態。第 2 輪這裡寫的是「我們整套不 disable」——<b>字面上是假的</b>（field 有 disabled 態、載入中的按鈕就是 disabled 的樣子）。準確的規則是兩句：<b>不因驗證未通過而 disable</b>（按鈕永遠可按，按下去用錯誤或說明回話 —— disabled 的按鈕對長輩是「壞掉了」不是「還不能按」）；<b>因處理中而 disable</b>（<code>ctaBusy</code> 就是它的樣子：漸層拿掉換實色、唇邊與底同色）。這條已升格為兩軌共用的產品規則。③ 不用 <code>.glassEffect()</code>：Liquid Glass 是系統的材質語言，我們的凹凸是紙的厚度，疊起來會變成兩套光。',
      '<b>App icon</b>：分層與網格照官方 App Icon Template（1024 見方、系統套 squircle、中央安全圓），生產走 Icon Composer。見 AppIcon 板。',
    ])}
    ${note(t, '三種表面 = 三個規則', [
    '凹（<code>win</code>）只給白名單上的七個角色：輸入框、六格、照片位／等待窗、頭像、還沒產生的號碼位、開關關閉的軌道、台紙接縫。<b>白名單印在 Tokens 板上。</b>',
    '<b>三種表面各多一個判準：漸層方向。</b>凹＝上暗下亮、浮＝上亮下暗、平印＝沒有漸層。SwiftUI 用 <code>LinearGradient(colors:startPoint:.top,endPoint:.bottom)</code>，兩端都從 Asset Catalog 取，不要在 View 裡算。',
    `浮（<code>raise</code>）<b>只有兩層</b>：${FIX.lip}pt 下緣唇邊 ＋ 落影。唇邊用 <code>.overlay(alignment:.bottom)</code> 畫，不要用 shadow 假裝。第 2 輪的 inset topLight 是第三層、也是「有 inset＝可以填」的無聲例外，已移除。`,
    `平印（<code>flat</code>）給「只能讀」的：票根、明細表、說明框、待核卡片、警語條。沒有 inset、沒有 lift、<b>沒有漸層</b>，只有 ${FIX.hair}px edge 與字的 letterpress。唯一的例外是票根的號碼帶（褪色，不是光）。`,
    'SwiftUI 到現行世代（iOS 26／27）仍然沒有第一級的 inner shadow：用兩層 stroke（上緣深、下緣亮）或 <code>.stroke(gradient).blur().mask()</code>。<b>不要用 Liquid Glass 的 <code>.glassEffect()</code> 代替凹凸</b> —— 那是系統的材質語言（它自己會反光、會跟著背景動），我們的凹凸是紙的厚度，兩者疊在一起會變成兩套光。系統控件（開關、sheet、nav bar）該長什麼樣就長什麼樣，識別層只作用在我們自己畫的表面上。',
  ])}
    ${note(t, '版式：三階寬度、騎縫線、刻度（第 5 輪新增）', [
      `<b>寬度有三階，而且階有意思</b>：<b>出血</b>（板寬，只給拿在手上的實體：票根、登入托盤）／<b>欄</b>（版心 ${FIX.gutter}pt 內距，給可以操作的東西：輸入框、按鈕、選項卡、待核卡片）／<b>旁註</b>（欄再縮 ${NOTE_IN}pt，給引用與說明：明細表、說明框）。第 4 輪整份稿子 ${'156'} 個區塊只有 6 種寬度、七成是同一個 342 —— 主體與幫助文字同寬同皮，讀者分不出哪一塊要做、哪一塊只是解釋。SwiftUI：出血用 <code>.listRowInsets(EdgeInsets())</code> 或負 padding，旁註用 <code>.padding(.horizontal, ${NOTE_IN})</code>。`,
      `<b>說明框沒有皮</b>：它不是另一張紙，是印在台紙上的旁註（縮排＋左側 ${FIX.hair}pt 邊線）。平印的「皮」從此只代表一件事：那是一張真的印刷品（票根、明細表、警語條）。`,
      `<b>騎縫線是遮罩挖出來的洞，不是畫上去的線</b>：圓孔 r=${PERF.r}、齒距 ${PERF.pitch}（AX 板 ${ax(PERF.pitch)}，齒距綁 <code>ax()</code>）、左右兩緣半圓缺口 r=${PERF.notch}。<b>票根（還沒撕）＝完整圓孔</b>（上下兩半各切自己那一緣的一半）、<b>托盤（撕下來的那一邊）＝半圓扇貝邊</b>。iOS 實作用 <code>.mask()</code> 疊三層 <code>RadialGradient</code>，或直接用 <code>Path</code> 減去圓形 —— <b>不要用一條虛線圖片</b>，那是第 4 輪被判掉的裝飾線。`,
      `<b>三格刻度：還沒用的格畫當前階、用掉的格蓋朱筆銷記</b>。刻度與號碼帶是同一支漸層（ΔE→0），所以「剩幾次」在刻度與帶色上是同一件事；銷記是有提按的一劃（brush 幾何），不是 CSS 的叉；它用的是紅筆不是字標那支蠟筆——劃掉存根的是照相館的人。`,
      `<b>登入鍵組的標籤有三階，三顆各走各的</b>（第 6 輪修）。<b>借來的兩顆</b>（Apple／Google）：一般「透過 X 登入」／AX4「X 登入」／AX5「登入」——AX5 那一階是<b>它們規範自己給的短標題</b>，品牌詞由商標承擔。<b>我們自己的那顆</b>：一般「用 Email 登入」／AX4 與 AX5 都是「Email 登入」——<b>不換短標題，因為量出來放得下</b>（兩條示範行都畫在 StressLoginAX 板上：一條被裁、一條有餘裕）。<b>aria-label 只加在 AX5 的兩顆品牌鍵上</b>，值是「品牌詞＋可見文字」；其餘每一顆一律沒有 aria-label，可見文字自己就是無障礙名稱（WCAG 2.5.3 Label in Name，G32⑤ 逐顆驗）。`,
    ])}
    ${note(t, '色彩落地', [
    '把 Tokens 板的 hex 建成 Asset Catalog color set，每一個都給 Any 與 Dark 兩個外觀值；View 裡只用語意名，例如 <code>Color.lsBoard</code>。',
    `<b>粉的來源要一起帶進 code review</b>：四階台紙不是同一支粉的四個明度，而是四種老化狀態（新紙／本體／偏冷的陰影／偏暖的手澤）。改色時不要只調明度，會把溫度層次抹平。`,
    `濃玫瑰與朱<b>只當底色與線</b>（朱的錯誤句與警語條是唯一的文字用法）。任何「濃玫瑰色文字」都是 bug —— 它在台紙上只有 ${cr(L.cta, L.board)}:1。`,
    '<b>文字一律不加 opacity。</b>placeholder 用實色 <code>lsInk2</code>；步驟條未走的段用實色 <code>lsEdge</code>。',
    '<b>芽綠＝把關的機制正在生效</b>：「申請已送出」（等人放行）與審核開關 ON 的軌道（要核准才能進來）。<b>第三個綠色就是 bug。</b>',
    `<b>${FIX.lip}pt 唇邊＝該表面的深一階</b>：濃玫瑰→<code>ctaDeep</code>、台紙→<code>edge</code>、朱→<code>pen</code>。<b>兩顆品牌鍵沒有唇邊</b>（第 2 輪改；連把 Google 規範的 ${FIX.hair}px 描邊加粗成 ${FIX.lip}px 都算改它的外觀）。用 <code>.overlay(alignment:.bottom)</code> 畫，顏色跟著表面走，不要各自寫死。`,
    `<b>深色是鏡像不是變暗</b>：光源翻到下方，所以 letterpress 的亮邊、以及七種漸層的兩端<b>全部一起對調</b>。只有 seam 不翻 —— 它由「紙壓在照片上」的幾何決定。`,
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
    '<b>載入就地轉態</b>：按鈕原地換成 <code>ProgressView</code> ＋文案，<b>漸層整條拿掉換成實色</b>（<code>ctaBusy</code>／次要鍵用 <code>board-3</code>）、唇邊與底同色 —— 按不動的東西不反光。不用全螢幕遮罩。',
    '<b>空狀態</b>是邀請動作：邀請家人空狀態直接指向「產生邀請碼」，而且把號碼的用途講完。',
    `<b>錯誤只有兩個紅</b>：輸入面下方 ${SP.s}pt 處一道<b>獨立的</b> ${FIX.errBar}pt 朱線 ＋ 一行朱色訊息。它刻意不是 border-bottom —— ${FIX.lip}pt 貼邊的線是「可以按」的唇邊，兩者不可以撞衫。`,
    '<b>出錯時明細表收成一行</b>：讓「欄位 → 錯誤句 → 下一步」擠成一群，中間不卡一張三行的表。',
    '<b>驗證碼輸錯</b>：六格全部清空、焦點回第 1 格，訊息說明已經清空。主按鈕<b>不要</b> disable。',
    '過期與次數用盡是<b>兩段不同文案</b>，不可合併成「邀請碼無效」。',
  ])}
    ${note(t, '邀請碼', [
    `<b>一律 6 位英數（大寫）</b>，顯示與輸入都切 3＋3 —— <b>對齊 LS-33 已上線的產生器</b>（40-bit）。上一稿提案的「6 位純數字」已由使用者否決，這一稿不再出現純數字的邀請碼。`,
    '<b>字母表要排掉會聽錯的字元</b>（0/O、1/I/L）—— 這組碼是要在電話裡念給長輩聽的。<b>這一項需要與 LS-33 的產生器對帳</b>（見本板最後一行未決事項）。',
    '只有<b>兩種正典</b>：票根 60pt（顯示）、分格 36pt（輸入）。信裡的驗證碼（6 位<b>純數字</b>）與邀請碼（6 位<b>英數</b>）長度與分組相同，共用同一個分格元件 —— 長輩只要學一次。',
    `<b>兩種碼的分組完全一樣：${SP.xl}pt 的組間距，不用標點</b>（第 5 輪改）。第 4 輪邀請碼那一版在兩組中間印一個「、」，理由是「它要唸出來」——但唸法那一句（「${SAY}」）本來就在畫面上把它講完了，而<b>票根上的兩組號碼中間一個字元都沒有</b>：同一組碼在同一條流程裡不該有兩種分組寫法。印刷品用間距分組，不用標點——這是這一稿自己的規則，現在輸入格也照它。`,
    `期限與剩餘次數<b>永遠跟著號碼</b>（票根下緣那條）。<b>還沒產生的號碼位就是一張空票根</b>：外框、數字帶高（<code>codeLine ${FIX.codeLine}</code>）、騎縫線、下緣帶全部一樣，只有表面從平印換成凹（可以填）—— 所以四個狀態的高度一致，開關列不會跳位。`,
    '<b>有人在等核准時，票根不縮</b>（第 3 輪改）：第 2 輪這裡把票根壓成一條 51px 的細帶，而那兩張正好是全稿唯二畫得出不同褪色階的板 —— 抬標的元素被壓扁，褪色在真畫面上就等於沒發生。現在兩張待核板用的就是同一張票根（號碼帶全高、三格刻度都在），代價是這兩張會捲動。',
  ])}
    ${note(t, '兩段式審核（LS-18 使用者核定）', [
    '輸碼 → <code>request_join(code)</code> → 等待核准；核准前 RLS 一律查不到內容，UI 不要樂觀寫入。',
    'Owner 待核清單：<b>等最久的排最上面並攤開</b>，其餘收成一列（頭像＋名＋Email＋等多久＋「查看 ›」），點開才展開。一次只有一張攤開，所以濃玫瑰每畫面仍然只有一個。',
    '<b>核准這一刻不選身分</b>（使用者核定）：家人／親友由家長之後在成員設定裡指定。核准的判斷只有一件事 —— 這個人是不是你認識的；把第二個決定塞進最需要專心的一步是設計錯誤。卡片上用一行說明把「之後可以改」講清楚。',
    `核准是濃玫瑰主按鈕、拒絕是不滿版的墨色底線連結，<b>相隔 ≥${SP.xxl}pt 且不並排</b>。`,
    `<b>開關列固定在票根正下方</b>，四個狀態（空／產生中／已產生／審核關閉）同一條線 —— 它管的就是「誰能進來」，<b>不隨狀態移位</b>。空的號碼位與票根是同一個外框（凹／平印兩種表面），所以四態等高。`,
    `<b>審核開關關掉時</b>：整列的 ${FIX.lip}pt 唇邊換朱（不是再加一圈描邊——那會變成第三個紅）＋補一張<b>警語條</b>（底色是台紙最亮的 <code>lit</code>，因為它是此刻唯一該讀的一句）＋<b>撤掉濃玫瑰主按鈕</b>，主動作降級成次要的「還是要傳給家人」。示警靠這三件事，不靠版面跳動。`,
  ])}
    ${note(t, 'iPad', [
    `登入是全螢幕流程，照片吃左邊 55%（657/1194）。內容欄<b>不垂直置中</b>，改三段式：字標貼上緣、標題組居中、按鈕與法律行貼欄底。兩段間隔各掛 <code>data-pause</code> 說明理由。按鈕<b>寬度上限 ${FIX.btnMax}pt</b>。`,
    `三岔路 iPad <b>不放照片</b>（照片在登入頁出場過了）：雙欄。說明欄<b>比照手機版，帳號列貼上緣</b>，往下 ${FIX.gutter} → H1 → ${SP.s} → 副標 → ${SP.xxl} → 說明框，<b>排完就停</b>（沒有 <code>space-between</code>），剩餘空白落在欄底。`,
    `兩欄的第一行字仍然視覺同高：左欄 H1（42/50）的 cap-height 對齊右欄首卡標題（28/34、卡內距 ${FIX.tap}）的 cap-height —— 右欄整體下推 <b>${FIX.capAlign}pt</b>（＝${FIX.tap}+${FIX.gutter} 的帳號列高度差與兩級字 cap 差的合計，管線逐張量）。`,
    '<b>iPad 內文一律 19pt 起跳</b>；iPad 歡迎頁標題用 60pt（與票根同一階，不是新階）。',
    '進到家庭之後才切 <code>NavigationSplitView</code>（M2）。',
  ])}
    ${note(t, '照片', [
    `<b>已經是真實素材，不是佔位圖。</b>${PHOTO.w}×${PHOTO.h}（2:3），晨光側逆光。畫面上<b>不印任何規格註記</b>——攝影條件只在這張板上（第 2 輪：「把 backlog 當設計」）。`,
    '它符合板上原本寫的採購條件：兩個人、兩張臉都看得見而且都朝著鏡頭、有生活雜訊（櫃子、收音機、摺好的布巾）、沒有人背對鏡頭走開、清晰。<b>而且主角是長輩</b>——這個 app 是為長輩設計的，主視覺裡就該有長輩。',
    `台紙上緣壓過照片 ${FIX.seamPhone}pt（iPad 是 ${FIX.seam}pt）並帶 ${FIX.hair}pt 切邊，交界處另有一道 seam 漸層（紙的厚度投下的影）—— 這個交界是整套語言的出處，不要拉平。`,
    `<b>焦點規格（各斷點自己一組值，不要共用一組）</b>：焦點寫成影像座標比例 <b>(${Math.round(PHOTO.fx * 100)}%, ${Math.round(PHOTO.fy * 100)}%)</b>，取在<b>兩張臉的中間</b>而不是單一張臉上 —— 主體是「兩個人靠在一起」這件事。<code>object-position</code> 由它推。${measured.focusLine}`,
    `<b>alt 寫「看得到什麼」</b>（誰、在哪、在做什麼），不寫用途、不寫攝影指示 —— brief 不可以藏在 alt 裡。目前的 alt：「${PHOTO_ALT}」。`,
    '照片上<b>不放任何文字</b>（壓在照片上的對比無法定義）。歡迎頁的溫度來源是手寫字標，它在台紙上，對比量得出來。',
    `<b>深色模式的照片少一格光</b>（第 5 輪新增）：<code>brightness(${PHOTO_DIM})</code> —— 曝光少一格＝亮度剩一半（${PHOTO_STOP}），sRGB 是通道乘法所以 0.5^(1/2.2)=${PHOTO_DIM}。理由是這一稿的深色是「同一本相簿在夜裡」：全稿每一塊面都跟著暗了，照片不能是唯一自己發光的東西。<b>為什麼不照台紙的比例降</b>（台紙 Y 0.771→0.0097）：那會把照片變成一塊黑——相紙不是台紙。<b>誠實話</b>：少一格之後照片的白仍然比它裱在上面的紙亮十幾倍，這是取捨不是物理終點。SwiftUI 用 <code>.brightness()</code> 之前先確認它作用在 sRGB 上，或改用 <code>.colorMultiply(.init(white: ${PHOTO_DIM}))</code>。`,
    `<b>出貨前要補的</b>：這張 ${PHOTO.w}px 寬的素材在 iPad@2x（需要 ${657 * 2}px）不夠，出貨要重新出圖或換更大的原檔。`,
  ])}
    ${note(t, '三顆登入鍵（順序為使用者核定）', [
    '<b>順序：Apple → Google → Email。</b>三顆同高、同圓角、同間距、直排，每顆 ≥' + FIX.button + 'pt。',
    `<b>已改寫的固化決定</b>：上一稿是「Email 在上，順序是唯一的優先訊號，接受深色下 Apple 白底的重量反轉」。現在<b>順序與視覺重量同向</b>——Apple 在最上，而它在兩種模式下都自動是全頁最重的一塊（淺色純黑 ${cr(L.appleBg, L.board)}:1、深色純白 ${cr(D.appleBg, D.board)}:1）。<b>所以那條讓步不再需要。</b>`,
    `<b>Email 這一顆從主按鈕降級成一般浮起面</b>：歡迎頁因此一顆濃玫瑰都沒有 —— 色彩不再與順序打架。不要為了「讓 Email 明顯一點」把它改回濃玫瑰。`,
    'Apple：黑底白字（深色反白）、官方字串、圓角 14 —— <b>顏色與字樣不可改</b>（HIG）。它是全稿唯一沒有唇邊的浮起面，因為連唇邊都算改到它的外觀。',
    `Google：白底（深色 ${D.googleBg}）、官方四色 G、指定描邊 <code>${L.googleBg === '#FFFFFF' ? L.googleLine : ''}</code>（深色 ${D.googleLine}）。<b>四色 G 是商標不是裝飾性 icon —— AX 放大時不可以拿掉，只能跟著長大</b>（我們自己的 icon 在 AX3 以上才拿掉）。它與 Apple 鍵一樣<b>不加唇邊、不加漸層</b> —— 我們只借幾何（同高、同圓角、同間距、同命中盒），不借光也不改邊。<b>AX5 空間不夠時換官方短標題「登入」，版式不動</b>；不要自己把標誌堆到字的上方。`,
    `深色下三鍵的重量順序是 Apple（純白）→ Email（台紙浮起）→ Google（近黑＋描邊）。<b>Google 在深色下比 Email 輕，是第三方規範的必然</b>，不要改它的色去扳回順序；它的邊界由描邊撐住（${cr(D.googleLine, D.board)}:1，門檻 3:1）。`,
    '送審前請再確認當時的 Review Guidelines（第三方登入並存時 Apple 的呈現要求）。',
  ])}
  </div>
  <p style="${TY.cap};color:${t.ink2};margin:${FIX.gutter}px 0 0">尚未決定、需要人核可：① 邀請碼字母表是否排掉 0/O、1/I/L（要與 LS-33 已上線的 40-bit 產生器對帳，會影響碰撞率）；② 三顆登入鍵並存時的送審呈現要求；③ iPad@2x 需要更大的照片原檔。</p>
</div>`);
};

/* ─────────────────────  對比實測（寫進 Tokens 板）  ───────────────────── */

const hex = (h) => { h = h.replace('#', ''); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
const lum = (c) => { const s = c.map((v) => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }); return .2126 * s[0] + .7152 * s[1] + .0722 * s[2]; };
const CR = (a, b) => { const l1 = lum(a), l2 = lum(b); const [hi, lo] = l1 > l2 ? [l1, l2] : [l2, l1]; return (hi + .05) / (lo + .05); };
const cr = (a, b) => CR(hex(a), hex(b)).toFixed(2);
const asRatio = (n) => `${n}:1`;   // 「x:1」的那個 1 是記法不是規格數字，所以連它也內插
const ratio = (a, b) => asRatio(cr(a, b));   // 註記裡的對比一律用這個，":1" 才不是手打的數字
const mix = (fg, bg, al) => fg.map((v, i) => v * al + bg[i] * (1 - al));
const crMix = (fg, bg, al) => CR(mix(hex(fg), hex(bg), al), hex(bg)).toFixed(2);
const tag = (v) => (v >= 7 ? 'AAA' : v >= 4.5 ? 'AA' : v >= 3 ? '3:1 過' : 'FAIL');

/* 第 2 輪板上兩句話被 reviewer 量出字面為假，本輪改寫成實測上界 —— 而且不手打：
     rot   固定 L* 只轉色相（深色四階的修法）造成的對比變動上界。8 bit 進位造成的。
     lit   本輪 lit 換色（L* 96.6 → 94.11）造成的對比變動上界，與最低的那一組。
     gradSpan 漸層端點的色相跨距 —— 「−18.95°」只對實體 token 成立的反證。 */
const LIT_DELTA = (() => {
  const OLD = { light: '#FEF3F0', dark: '#462A2B' };
  let lit = 0, worst = 99;
  for (const [k, th] of [['light', T.light], ['dark', T.dark]]) {
    for (const fg of ['ink', 'ink2', 'pen', 'cta']) {
      lit = Math.max(lit, Math.abs(+cr(th[fg], OLD[k]) - +cr(th[fg], th.lit)));
      if (/ink|pen/.test(fg)) worst = Math.min(worst, +cr(th[fg], th.lit));
    }
  }
  /* 固定 L* 只轉色相的量化誤差：對每一個實體 token，把它轉一圈回原色相，
     量重新量化之後的對比差 —— 這就是「一位元沒動」實際上動了多少。 */
  let rot = 0;
  for (const th of [T.light, T.dark]) {
    for (const k of ['board', 'board2', 'board3', 'cta']) {
      const c = lch(th[k]), round = lchHex(c.L, c.C, c.h);
      rot = Math.max(rot, Math.abs(+cr(th.ink, th[k]) - +cr(th.ink, round)));
    }
  }
  let span = 0;
  for (const th of [T.light, T.dark]) {
    for (const k of GRAD_KEYS) {
      const st = th.grad[k].filter(([c]) => /^#/.test(c));
      if (st.length >= 2) span = Math.max(span, Math.abs(dHue(lch(st[0][0]).h, lch(st.at(-1)[0]).h)));
    }
  }
  return { lit: lit.toFixed(2), rot: Math.max(rot, 0.01).toFixed(2), worst: asRatio(worst.toFixed(2)), gradSpan: span.toFixed(0) };
})();


const L = T.light, D = T.dark;
// 漸層端點取色（色停現在是 [色, 位置%]）：0＝上端、-1＝下端
const gc = (th, k, i) => th.grad[k].at(i)[0];
const measured = {
  board: `ink ${cr(L.ink, L.board)} · ink2 ${cr(L.ink2, L.board)}`,
  board2: `ink ${cr(L.ink, L.board2)} · ink2 ${cr(L.ink2, L.board2)}`,
  board3: `ink ${cr(L.ink, L.board3)} · ink2 ${cr(L.ink2, L.board3)}`,
  lit: `朱 ${cr(L.pen, L.lit)} · ink ${cr(L.ink, L.lit)}`,
  ink: `on board ${cr(L.ink, L.board)}`,
  ink2: `board ${cr(L.ink2, L.board)} · b-2 ${cr(L.ink2, L.board2)} · b-3 ${cr(L.ink2, L.board3)}`,
  cta: `紙字/漸層上端 ${cr(L.onCta, gc(L, 'cta', 0))} · 下端 ${cr(L.onCta, gc(L, 'cta', -1))} · 載入實色 ${cr(L.onCta, L.ctaBusy)}`,
  pen: `台紙漸層下端 ${cr(L.pen, gc(L, 'paper', -1))} · 警語條 lit ${cr(L.pen, L.lit)}`,
  brand: `Google 字/底 ${cr(L.googleFg, L.googleBg)} · 描邊/台紙 ${cr(L.googleLine, L.board)} · Apple 字/底 ${cr(L.appleFg, L.appleBg)}`,
  sprout: `board ${cr(L.sprout, L.board)} · ON 軌道對 b-3 ${cr(L.sprout, L.board3)} · 白把手/芽綠 ${cr(L.knob, L.sprout)}`,
  knob: `OFF 把手/軌道 淺 ${cr(L.knob, L.grad.well[1][0])} · 深 ${cr(D.knob, D.grad.well[0][0])}（門檻 3:1；第 2 輪 1.04）· ON 把手/芽綠 ${cr(L.knob, L.sprout)}`,
  edge: `board ${cr(L.edge, L.board)} · b-2 ${cr(L.edge, L.board2)} · b-3 ${cr(L.edge, L.board3)}`,
  inkContrast: cr(L.ink, L.board),
  edgecases: [
    `placeholder 實色 ink2/board2 … ${cr(L.ink2, L.board2)} ${tag(+cr(L.ink2, L.board2))}（原 ink2@.72 = ${crMix(L.ink2, L.board2, .72)}）`,
    `步驟條未走段 實色 edge/board … ${cr(L.edge, L.board)} ${tag(+cr(L.edge, L.board))}（原 edge@.38 = ${crMix(L.edge, L.board, .38)}）`,
    `錯誤線 朱/台紙 … ${cr(L.pen, L.board)}（非文字，門檻 3:1）`,
    `芽綠軌道 sprout/board3 … ${cr(L.sprout, L.board3)}（非文字，門檻 3:1）· 白把手/芽綠 ${cr(L.onSprout, L.sprout)}`,
    `警語條 朱/lit … ${cr(L.pen, L.lit)} AAA（這一句是朱唯一的長文字用法）`,
    `平印表面 ink/board（無填色）… ${cr(L.ink, L.board)} AAA`,
  ],
  dark: [
    `board ${D.board} · board-2 ${D.board2} · board-3 ${D.board3} · lit ${D.lit}`,
    `ink ${D.ink} ${cr(D.ink, D.board)} · ink2 ${D.ink2} ${cr(D.ink2, D.board)}`,
    `cta ${D.cta} ＋墨字 → 漸層上端 ${cr(D.onCta, gc(D, 'cta', 0))}／下端 ${cr(D.onCta, gc(D, 'cta', -1))}`,
    `朱 ${cr(D.pen, D.board)} · 警語條 朱/lit ${cr(D.pen, D.lit)} · sprout 軌道對 b-3 ${cr(D.sprout, D.board3)} · 把手 ${cr(D.onSprout, D.sprout)}`,
    `placeholder ink2/board2 ${cr(D.ink2, D.board2)} · Apple 反白 ${cr(D.appleFg, D.appleBg)} · Google ${cr(D.googleFg, D.googleBg)}`,
    `光源反轉：letterpress 由「下緣亮」翻成「上緣暗」（press: ${D.press}），<b>${GRAD_KEYS.length} 種漸層的兩端也一起對調</b> —— 只有 seam 不翻（它是幾何不是光）`,
    `深色最低文字組合 ${Math.min(+cr(D.onCta, gc(D, 'cta', 0)), +cr(D.ink2, D.board), +cr(D.pen, D.lit)).toFixed(2)}（AAA）`,
  ],
  gaps: '', sizes: '', pads: '', insetLine: '', ctaLine: '', h1Line: '', voidLine: '', errLine: '', trayLine: '',
  lipLine: '', focusLine: '', gradLine: '', axFitLine: '', photoLine: '', scaleLine: '', perfLine: '', widthLine: '',
};

/* verify.mjs / measure.mjs 會重新掃描產出並回填實測句子；
   設計稿上印的每一句都是從 measured.json 讀的，不是手寫的。 */
const MJ = new URL('measured.json', import.meta.url);
const MEAS_RAW = existsSync(MJ) ? readFileSync(MJ, 'utf8') : '';
/* verify 算完之後才知道的四個統計，寫在自己的檔裡（第 3 輪拆出來的）——
   它們不能回寫進 measured.json，那會讓 G21 變成不冪等的：verify 動了那個檔，
   同一份產物再驗一次就會說「板上印的是上一版」。跑兩次得到兩個答案的 gate 不是 gate。 */
const VJ = new URL('verified.json', import.meta.url);
const V = existsSync(VJ) ? JSON.parse(readFileSync(VJ, 'utf8')) : {};
const M = { ...(MEAS_RAW ? JSON.parse(MEAS_RAW) : {}), ...V };
/* 這一次 build 讀到的 measured.json 指紋。每一張產物都蓋上它（見 doc()），
   verify 的 G21 拿現行 measured.json 的指紋比對 —— 板上印的實測句是不是上一版，
   從此是 gate 判的，不是人記得跑第二輪。 */
/* ── 指紋迴圈：戳記排除 root（第 5 輪 D4-09）────────────────────────
   第 4 輪：跑兩次同一份原始碼，34 張板的內容雜湊每次都不一樣。原因是一個自我餵食的迴圈 ——
     板上蓋的 ls-measured 戳記 ＝ hash(measured.json 全文)
     而 measured.json 裡有 root.contentFp ＝ hash(34 張板的原文)
     而板的原文裡有那個戳記……
   所以每一次 measure 都會把上一次的戳記吃進去、生出一個新的戳記，永遠不收斂。
   後果不是美觀問題：**沒有人能靠重建來核對這一份產物**（重跑必變），
   而「可重現」正是這一整套 gate 的地基。
   修法：戳記只吃 measured.json 裡**與產物內容無關**的部分 —— 把 root 整段排除。
   root 自己另有兩道守衛（measure 開跑前的三方對帳、G21b／G21c），不靠戳記。 */
const MEAS_HASH = measStamp(MEAS_RAW);
const say = (v, f) => (v === undefined ? '（尚未量測：node measure.mjs && node verify.mjs）' : f(v));

measured.gaps = say(M.gapCount, () => `實測（${M.measuredAt || '本次'}）：${M.count} 張板共 ${M.gapCount} 個 gap，全部落在這七階。`);
measured.sizes = say(M.sizesUsed, () => `實測：${M.count} 張板的 font-size 只出現這 ${M.sizesUsed.length} 階 [${M.sizesUsed}]，外加 AX 壓力板的 ×3.1 推導值 ${M.axDerived.length} 個。`);
measured.pads = say(M.padCount, () => `實測：${M.padCount} 個 padding/margin 值，全部落在七階或上表的常數（第 2 輪只掃 gap，放走 133 個）。`);
measured.trayLine = say(M.trayDelta, () => (M.trayDelta.length
  ? `${M.trayDelta.length} 顆，最小 ${M.trayDeltaMin}（${M.trayDeltaMinWho}）—— 第 2 輪 reviewer 說這個數「正確但膽小」，本輪刻意不追它，理由見上一點。`
  : '（尚未量測）'));
measured.insetLine = say(M.insetUse, () => `實測：${M.insetTotal} 個帶 inset 的使用點，全部落在這 ${Object.keys(M.insetUse).length} 個角色（第 2 輪只 grep helper 定義，實測 49 個非可填元件帶 inset）。`);
measured.ctaLine = say(M.ctaMax, () => `實測：${M.ctaBoards} 張流程板，最外層濃玫瑰區塊最多 ${M.ctaMax} 個／板；歡迎頁 ${M.ctaZero} 張是 0 個。`);
measured.gradLine = say(M.grad, () => `實測：${M.count} 張板上共 ${M.grad.total} 個漸層使用點，全部出自這 ${M.grad.kinds} 種登記在案的寫法（方向不是 180deg 的 ${M.grad.badDir} 個）；其中 ${M.grad.textOn} 個上面壓了字，逐字取漸層最不利點算對比，最低 ${M.gradMin}（${M.gradWorst}），門檻 ${CONTRAST.aaa}。`);
measured.h1Line = say(M.h1 && M.h1.groups, () => `實測：${Object.entries(M.h1.groups).map(([g, v]) => `${g} ${v.n} 張同在 ${v.ys.join('／')}px`).join('；')}。排除 ${H1_EXCLUDED.length} 張（iPad 走跨欄基線、AX 壓力板、板中板、交付板）。`);
/* 措辭統一（第 4 輪 R10）：主按鈕的位置一律講「最低」＝畫面上最靠下的那一張＝百分比最大的那一張。
   measure.mjs 的 console、verify.mjs 的 G10、這一句，三處同一個詞。 */
measured.voidLine = say(M.maxVoid, () => `實測：手機最大 ${M.maxVoid}px（${M.maxVoidFile}）；iPad 欄內最大 ${M.maxVoidPad}px（${M.maxVoidPadFile}）；超過 ${RULE.pause} 的 ${M.pauses ? M.pauses.length : 0} 段全部掛了 data-pause，未掛牌的 ${M.pauseBad ? M.pauseBad.length : 0} 段。尾段空白最大 ${M.maxTrail}px（${M.maxTrailFile}）；主按鈕中心<b>位置最低</b>（＝百分比最大）的是 ${M.btnMaxPct}%（${M.btnMaxFile}），其中尾段 >${RULE.pause}px 的板位置最低 ${M.btnTailPct === null ? '無此板' : `${M.btnTailPct}%（${M.btnTailFile}）`}。`);
measured.errLine = say(M.errGap, () => `實測：${M.errCount} 道錯誤線，與最近的唇邊距離最小 ${M.errGap}px。`);
measured.lipLine = say(M.lips, () => {
  const n = (k) => M.lips[`${k}@${FIX.lip}`] || 0;
  const who = (re) => (M.lipNoneWho || []).filter((s) => re.test(s)).length;
  return `實測：${M.lipTotal} 個浮起面，唇邊 ctaDeep ${n('ctaDeep')}／edge ${n('edge')}／pen ${n('pen')}／googleLine ${n('googleLine')}，寬度一律 ${FIX.lip}pt。`
    + `<b>兩個例外，都在這裡</b>：Apple 鍵 ${who(/:button$/)} 個沒有唇邊（HIG 外觀不可改，連唇邊都算改）；審核開關 ON 的軌道 ${who(/:switch$/)} 個沒有唇邊（56×32 的膠囊，唇邊會壓到把手的行程）。`
    + `<b>Google 鍵不是例外</b>：它的品牌規範自己指定了一條描邊色，那條色正好就是「該表面的深一階」，所以它走同一條唇邊規則，只是顏色由對方給。`
    + `另外「載入中」的按鈕底與唇邊同色（ctaBusy）而且漸層整條拿掉，因為它這一刻按不動。`;
});
/* 第 5 輪新增的五條實測句。每一句都只讀 measured.json —— 板上印的與 gate 判的同一份。 */
measured.axFitLine = say(M.axFit, () => {
  const g = (M.axFit || []).find((x) => x.id === 'ax5-google');
  const e = (M.axFit || []).find((x) => x.id === 'ax5-email');
  return g && e
    ? `AX5 的「Google 登入」在 ${ax(17)}pt 下佔 ${g.need}px，那顆鍵真正剩給標籤的寬度是 ${g.room}px —— <b>差 ${g.short}px</b>（板上那條被裁掉的示範行就是它）：跟著長大的商標 ${ax(20)}px 與間距 ${SP.m}px 吃掉的就是這個差。同一階的「Email 登入」佔 ${e.need}px，而那顆鍵剩 ${e.room}px —— <b>還有 ${-e.short}px 沒用到</b>（它沒有商標要擺）。同一個機身寬 ${390}px、同一階字級，一顆放不下一顆放得下，所以第三顆不縮不是通融。`
    : '（尚未量測）';
});
measured.photoLine = say(M.photo, () => `實測（逐像素，${M.photo.n} 張照片）：深色版對淺色版，平均亮度比 ${M.photo.meanRatio}、p99 比 ${M.photo.p99Ratio}，門檻是一格光 ${PHOTO_STOP}±${'0.04'}。`);
measured.scaleLine = say(M.scale, () => {
  const adj = (M.scaleDelta || {}).adjMin, ends = (M.scaleDelta || {}).endsMin;
  return `實測：${(M.scale || []).length} 個刻度使用點；逐格對位，相鄰狀態最大 ΔE 最小的一組是 ${adj}（門檻 ${SCALE_DE.adj}），剛印好↔用完了三格最小 ΔE ${ends}（門檻 ${SCALE_DE.ends}）；「還沒用的格」與號碼帶的 ΔE 最大 ${(M.scaleDelta || {}).bandMax}（門檻 ${SCALE_DE.band}，這一條是「刻度＝帶子」）。`;
});
measured.perfLine = say(M.perf, () => `實測：${M.perf.length} 個騎縫線使用點（完整圓孔 ${M.perf.filter((p) => /^joined/.test(p.kind)).length}、半圓扇貝邊 ${M.perf.filter((p) => p.kind === 'torn-t').length}），齒距 ${[...new Set(M.perf.map((p) => p.pitch))].sort((a, b) => a - b).join('／')}px（一般 ${PERF.pitch}、AX 板 ${ax(PERF.pitch)}）。`);
measured.widthLine = say(M.widths, () => `實測：${Object.keys(M.widths).length} 張板，每張板的區塊寬度種類最少 ${Math.min(...Object.values(M.widths).map((w) => w.kinds))} 種（門檻 2）；全稿共 ${new Set(Object.values(M.widths).flatMap((w) => w.list)).size} 種寬度（第 4 輪是 6 種，其中 72% 是同一個 342）。`);
measured.focusLine = say(M.focus, () => M.focus.map((f) => `<b>${f.name} ${f.bw}×${f.bh}</b>：cover 後只裁${f.axis}（${f.crop}px），<code>object-position:${f.pos}</code>${f.clamped ? '（焦點推出來的值超出可及範圍，已鎖到極值 —— iPad 的框幾乎與素材同比例，所以「從最上面開始顯示」就是對的）' : ''}`).join('；') + '。另一軸寫什麼都沒有作用，不要照抄兩軸數字。');

/* ─────────────────────────  EMIT  ───────────────────────── */

const files = {
  'Main.dc.html': welcome(L),
  'WelcomeDark.dc.html': welcome(D),
  'WelcomeIPad.dc.html': welcomeIPad(L),
  'Email.dc.html': emailScreen(L),
  'EmailError.dc.html': emailScreen(L, { error: true }),
  'EmailSending.dc.html': emailScreen(L, { busy: true }),
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
  'InviteReadyDark.dc.html': inviteScreen(D, { state: 'ready' }),
  'InviteApprovalOff.dc.html': inviteScreen(L, { state: 'approvalOff' }),
  'InviteApprovalOffDark.dc.html': inviteScreen(D, { state: 'approvalOff' }),
  'InviteSpent.dc.html': inviteScreen(L, { state: 'spent' }),
  'InviteRequests.dc.html': inviteRequests(L),
  'InviteRequestsMany.dc.html': inviteRequests(L, { many: true }),
  'StressType.dc.html': stressType(L),
  'StressLoginAX.dc.html': stressLoginAX(L),
  'StressCodeAX.dc.html': stressCodeAX(L),
  'StressContent.dc.html': stressContent(L),
  'Tokens.dc.html': tokensSheet(measured),
  'AppIcon.dc.html': iconSheet(),
  'GlassSeam.dc.html': glassSeam(L),
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
  ...row(0, [['Main.dc.html', P], ['WelcomeDark.dc.html', P], ['WelcomeIPad.dc.html', 1194, 834]]),
  ...row(PH + GY, [['Email.dc.html', P], ['EmailError.dc.html', P], ['EmailSending.dc.html', P], ['Otp.dc.html', P], ['OtpError.dc.html', P], ['OtpErrorDark.dc.html', P]]),
  ...row(2 * (PH + GY) + 40, [['Fork.dc.html', P], ['ForkIPad.dc.html', 1194, 834], ['CreateFamily.dc.html', P], ['CreateFamilySending.dc.html', P]]),
  ...row(3 * (PH + GY) + 40, [['JoinCode.dc.html', P], ['JoinCodeDark.dc.html', P], ['JoinExpired.dc.html', P], ['JoinUsedUp.dc.html', P], ['Pending.dc.html', P]]),
  ...row(4 * (PH + GY) + 80, [['InviteEmpty.dc.html', P], ['InviteGenerating.dc.html', P], ['InviteReady.dc.html', P], ['InviteReadyDark.dc.html', P], ['InviteApprovalOff.dc.html', P], ['InviteApprovalOffDark.dc.html', P]]),
  ...row(5 * (PH + GY) + 80, [['InviteSpent.dc.html', P], ['InviteRequests.dc.html', P], ['InviteRequestsMany.dc.html', P]]),
].map((a) => ({ ...a, page: 'page-1' }));

const sheets = [
  { file: 'StressType.dc.html', x: 0, y: 0, w: P, h: h('StressType.dc.html'), page: 'page-2' },
  { file: 'StressLoginAX.dc.html', x: P + GX, y: 0, w: P, h: h('StressLoginAX.dc.html'), page: 'page-2' },
  { file: 'StressCodeAX.dc.html', x: 2 * (P + GX), y: 0, w: P, h: h('StressCodeAX.dc.html'), page: 'page-2' },
  { file: 'StressContent.dc.html', x: 3 * (P + GX), y: 0, w: 1290, h: h('StressContent.dc.html'), page: 'page-2' },
  { file: 'Tokens.dc.html', x: 3 * (P + GX), y: h('StressContent.dc.html') + GY, w: 980, h: h('Tokens.dc.html'), page: 'page-2' },
  { file: 'Notes.dc.html', x: 3 * (P + GX) + 980 + GX, y: h('StressContent.dc.html') + GY, w: 980, h: h('Notes.dc.html'), page: 'page-2' },
  { file: 'AppIcon.dc.html', x: 3 * (P + GX) + 980 + GX + 980 + GX, y: h('StressContent.dc.html') + GY, w: 1290, h: h('AppIcon.dc.html'), page: 'page-2' },
  { file: 'GlassSeam.dc.html', x: 3 * (P + GX) + 980 + GX + 980 + GX + 1290 + GX, y: h('StressContent.dc.html') + GY, w: 980, h: h('GlassSeam.dc.html'), page: 'page-2' },
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
      id: 'icon-veto', x: 1400, y: -320, w: 620, page: 'page-1',
      text: `<b>AppIcon 板：概念經使用者否決（${ICON_VETO.when}），原地凍結。</b>被否決的是「app icon ＝ 一個字」<b>這件事本身</b> —— 不是筆觸、不是尺寸、不是那個字選得好不好，所以換筆換字都不是修法。${ICON_VETO.next} 板上其餘每一段（分層意圖、三種外觀、驗收排、G26 的四條規格、Tinted 的中灰玻璃底）留著，因為那些是<b>任何一個圖示都要通過的檢查</b>，換素材之後照樣要跑。G26／G26b／G26c 三族在這張板上暫停，登記在具名豁免簿（data-veto="icon-concept"→G26），恢復條件寫在那一筆上；負面對照裡指名咬那一族的樣本一起暫停並具名。ios-dev：<b>不要照這張板出圖</b>。`,
    },
    {
      id: 'motif', x: 0, y: -320, w: 640, page: 'page-1',
      text: `母題：相簿台紙。三種表面，一種一個意思 —— 凹進去＝可以填東西進去；浮起來＝可以按（兩層：${FIX.lip}pt 唇邊＋落影，沒有第三層 inset）；平印上去＝只能讀。凹的白名單有 ${A(M.insetUse, (u) => Object.keys(u).length)} 個角色（實測 ${A(M.insetTotal, (n) => n)} 個使用點全部落在裡面），全部印在 Tokens 板上；沒印在那張板上的例外就是 bug。粉不是濾鏡：彩色沖印的青色染料衰退最快，家裡那本相簿與它的台紙就是一年一年往洋紅偏過去 —— 這是家庭記憶會變成的顏色。四階台紙因此是四種老化狀態（新紙／本體／偏冷的陰影／偏暖的手澤），不是同一支粉的四個明度。`,
    },
    {
      id: 'ink-note', x: 700, y: -320, w: 620, page: 'page-1',
      text: `字標「${BRAND}」＝手寫「萌芽」＋系統字「日記」。手寫那兩個字是全稿唯一的非系統線條，也是歡迎頁的溫度來源 —— 不是暖色底、不是粗體字；第 6 輪起它是一隻手用蠟筆寫的真跡描成的向量（來源雜湊與描摹參數綁在 ink.mjs 上，G33 驗；第 5 輪以前的程式生成筆跡被使用者判「很醜」，換掉的是字樣不是規則）。四個字不全部手寫是有理由的：「萌」十四筆、「記」十筆，在信件明細那一格字標只有 ${INK.mail.h}pt 高，全手寫每一筆不到 ${(INK.mail.h * .05).toFixed(1)}pt，對長輩就是一團墨 —— 所以手寫的是名字的意思（萌芽）、系統字的是種類（日記），而且「日記」是真文字，會跟著 Dynamic Type 長大。五個使用點：歡迎頁（手機 ${INK.phone.h}pt／iPad ${INK.pad.h}pt）、信件明細的「寄件人」（${INK.mail.h}pt）、建立家庭的即時預覽（${INK.preview.h}pt）、規格板（${INK.sheet.h}pt）—— 你在畫面上看到的筆跡，信箱裡會看到同一支。它刻意不壓在照片上（照片上的對比無法定義），在卡紙上實測 ${ratio(L.ink, L.board)}。整組只掛一個無障礙名稱＝產品全名。`,
    },
    {
      id: 'photo-note', x: 1400, y: -320, w: 600, page: 'page-1',
      text: `照片已經是真實素材（${PHOTO.w}×${PHOTO.h}），不是佔位圖 —— 畫面上不印任何規格註記，攝影條件只在 Notes 板。它符合板上原本就寫著的條件：兩個人、兩張臉都看得見而且都朝著鏡頭、有生活雜訊、沒有人背對鏡頭走開、清晰；而且主角是長輩 —— 這個 app 是為長輩設計的，主視覺裡就該有長輩。焦點寫成影像座標比例 (${Math.round(PHOTO.fx * 100)}%, ${Math.round(PHOTO.fy * 100)}%)，取在兩張臉的中間而不是單一張臉上；object-position 由各斷點自己換算：${A(M.focus, (f) => f.map((x) => `${x.name} ${x.bw}×${x.bh} 只裁${x.axis} ${x.crop}px → ${x.pos}`).join('；'))}（另一軸寫什麼都沒有作用）。台紙上緣壓過照片 ${FIX.seamPhone}pt、iPad ${FIX.seam}pt，交界另有一道 seam 漸層（紙的厚度投下的影）。<b>深色模式的照片少一格光</b>（第 5 輪）：<code>brightness(${PHOTO_DIM})</code>＝亮度剩 ${PHOTO_STOP}（sRGB 通道乘法，${PHOTO_STOP}^(${1}/${2.2})）。實測逐像素平均亮度比 ${A(M.photo, (p) => p.meanRatio)}、第 ${99} 百分位亮度比 ${A(M.photo, (p) => p.p99Ratio)}。不照台紙的比例降是刻意的：台紙從 Y=${'0.771'} 掉到 ${'0.0097'}，照片跟著降就是一塊黑 —— 相紙不是台紙。誠實話：少一格之後照片的白仍然比紙亮十幾倍。`,
    },
    {
      id: 'void-note', x: 0, y: PH + GY - 300, w: 620, page: 'page-1',
      text: `呼吸帶是兩條規則，分工不是寬嚴兩版。①內容首末之間，任何一段連續無字無圖的縱向區間 ≤${RULE.pause}px —— 手機 iPad 同一條，沒有 iPad 例外；超過的必須掛 data-pause 寫出理由，掛不出理由就是版面破了（本稿 ${A(M.pauses, (p) => p.length)} 段掛牌、${A(M.pauseBad, (p) => p.length)} 段未掛牌，未掛牌一律 FAIL）。②內容末端到板底不設上限 —— 底部主按鈕貼安全區是 iOS 的正解（safeAreaInset）—— 但用到這個豁免的板（尾段 >${RULE.pause}px）要付對價：主按鈕中心得落在畫面 ${RULE.btnPct}% 以內。設計稿一律不畫假鍵盤、也不畫假狀態列。`,
    },
    {
      id: 'err-note', x: 700, y: PH + GY - 300, w: 620, page: 'page-1',
      text: `錯誤的幾何刻意脫離「可以按」的幾何：錯誤是一道獨立的 ${FIX.errBar}pt 朱線，離輸入面 ${SP.s}pt；可以按的唇邊是 ${FIX.lip}pt、貼著元件下緣。第 2 輪這兩者同寬同位置 —— 出錯的欄位長得像按鈕。全稿 ${A(M.errCount, (n) => n)} 道錯誤線出自同一個元件，實測與最近的唇邊距離最小 ${A(M.errGap, (g) => g)}px、重合 ${A(M.errOverlap, (n) => n)} 處。出錯時明細表收成一行，讓「欄位→錯誤句→下一步」擠成一群。`,
    },
    {
      id: 'ipad-note', x: 490, y: 2 * (PH + GY) + 40 - 300, w: 700, page: 'page-1',
      text: `iPad 兩板不再垂直置中：改三段式（上錨／中／下錨）。三岔路兩欄的第一行字同高 —— 左欄 H1（${ty2(TY.dPad)}）的 cap-height 對齊右欄首卡標題（${ty2(TY.h)}）的 cap-height，右欄整體下推 capAlign ${FIX.capAlign}pt，實測兩欄差 ${A(capPair.length === 2 ? capPair : null, (p) => Math.abs(p[0].y - p[1].y).toFixed(1))}px。兩欄「不齊底」是刻意的：說明欄排完就停，欄底剩 ${A(padCol('ForkIPad', 'desc'), (v) => v.trail)}px；選項欄剩 ${A(padCol('ForkIPad', 'options'), (v) => v.trail)}px —— 齊底不是目標，欄內不留大洞才是。死帶改成分欄量測：全幅量測會被欄位底色遮蔽，量不到欄內的空白（iPad 欄內最大 ${A(M.maxVoidPad, (n) => n)}px，${A(M.maxVoidPadFile, (s) => s)}，已掛 data-pause）。`,
    },
    {
      id: 'approval-note', x: 0, y: 4 * (PH + GY) + 80 - 300, w: 700, page: 'page-1',
      text: `兩段式審核。審核開關 ON 的軌道是芽綠（綠＝門禁開著、目前安全）—— 這是芽綠在全稿的第二個也是最後一個使用點，例外印在 Tokens 板。關掉時開關不移位：五張板（空／產生中／已產生／審核關閉／深色）的開關列都固定在票根正下方 y=${A(M.toggles, (g) => [...new Set(g.map((x) => x.top))].join('／'))} —— 空號碼位與票根是同一個外框，四態等高，所以位置是結構保證的，不是事後對齊。示警改用三件不移動版面的事：整列 ${FIX.lip}pt 唇邊換朱、補一張警語條（底色是台紙最亮的 lit ——「此刻唯一該讀的那一句」，也是 lit 在全稿唯一的使用點）、撤掉濃玫瑰主按鈕（沒有值得推薦的動作），「傳給家人」降成次要的「還是要傳給家人」。讓長輩重新找一次開關才是更糟的設計。另外：核准這一刻不再選身分（使用者核定）—— 身分由家長之後在成員設定裡指定，核准只判斷「這個人是不是你認識的」。`,
    },
    {
      id: 'queue-note', x: 0, y: 5 * (PH + GY) + 80 - 300, w: 700, page: 'page-1',
      text: `待核清單：等最久的排最上面並攤開，其餘收成一列（頭像＋名＋Email＋等多久＋「查看 ›」）。一次只有一張攤開 —— 濃玫瑰因此每畫面仍然只有一個（第 2 輪是四個），而且順序天然就是「先處理等最久的」。兩張待核板都放不下 ${PH}（單人 ${h('InviteRequests.dc.html')}px、多人 ${h('InviteRequestsMany.dc.html')}px），所以長高＝這兩張會捲動。<b>第 2 輪這裡把票根壓成一條細帶</b>（高度只剩號碼帶的 ${Math.round(51 / FIX.codeLine * 100)}%）——reviewer 的判定是：全稿唯二畫得出不同褪色階的兩張板，正好是把票根壓扁的那兩張，褪色因此在真畫面上等於沒發生。本輪撤掉細帶，這兩張用的就是同一張票根（號碼帶全高、三格刻度都在），代價就是這兩張要捲動。`,
    },
    {
      id: 'width-note', x: 1480, y: 5 * (PH + GY) + 80 - 300, w: 680, page: 'page-1',
      text: `<b>版式有三階寬度，材質也跟著分工</b>（第 5 輪）。<b>出血</b>（板寬 ${P}）只給拿在手上的實體：票根與登入托盤 —— 印刷品是從整張紙上裁下來的，不會乖乖坐在版心裡，所以它跑出版心、左右兩緣被打孔機咬掉一口。<b>欄</b>（版心，兩側 ${FIX.gutter}）給可以操作的東西：輸入框、按鈕、選項卡、待核卡片。<b>旁註</b>（再縮 ${NOTE_IN}×${2}）給引用與說明：明細表、說明框、提示句 —— 而且<b>旁註沒有皮</b>（縮排＋左側 ${FIX.hair}px 邊線），因為它不是另一張紙，是印在台紙上的旁註。平印的「皮」從此只代表一件事：那是一張真的印刷品。實測 ${A(M.widths, (w) => Object.keys(w).length)} 張板每一張至少兩種區塊寬度（G28①），全稿共 ${A(M.widths, (w) => new Set(Object.values(w).flatMap((x) => x.list)).size)} 種。<b>騎縫線是紙的形狀不是印上去的線</b>：遮罩挖出來的圓孔（r=${PERF.r}、齒距 ${PERF.pitch}，AX 板 ${ax(PERF.pitch)} —— 齒距綁 ax()，紙變大齒跟著變大），洞裡透出來的是台紙本身。<b>票根還沒撕＝完整圓孔、托盤是撕下來的那一邊＝半圓扇貝邊</b>，同一台打孔機的兩種狀態（G27 逐個使用點驗）。`,
    },
    {
      id: 'stub-note', x: 760, y: 5 * (PH + GY) + 80 - 300, w: 700, page: 'page-1',
      text: `<b>號碼帶的褪色階 ＝ 還可以用幾次</b>（第 2 輪新增；這是這一稿唯一「只有褪色相紙這個概念才長得出來」的東西 —— 卡紙的語言裡，一張卡片不會因為被用過而變淡）。票根是照相館的取件存根：<b>號碼帶是印上去的染料（會褪），號碼本身是碳墨（不會褪）</b>，這正是整個 app 的粉的出處。所以每被用掉一次，號碼帶就往「乾淨的紙」褪一階，而號碼永遠讀得到（四階實測全部 ${asRatio(CONTRAST.aaa)} 以上）。送出申請的當下就算用掉一次，不是核准才算 —— 所以：已產生 ${USES_TOTAL} 次（stub${USES_TOTAL}）→ 有 ${1} 個人在等、他用的是這組碼，剩 ${USES_TOTAL - 1} 次（stub${USES_TOTAL - 1}）→ 有 ${QUEUE.length} 個人在等、其中 ${QUEUE_OWN} 位用這組碼（另 ${QUEUE.length - QUEUE_OWN} 位用上一組，攤開的那張卡上寫著），剩 ${USES_TOTAL - QUEUE_OWN} 次（stub${USES_TOTAL - QUEUE_OWN}）。褪到最後（用完了）色相位移、明度差、彩度三個量一起趨近於零：<b>褪完了就沒有褪色的方向了</b> —— 這與「還沒印上號碼的空票根沒有這條漸層」是同一句話的兩端。G23④ 斷言三個量單調衰減、G23⑤ 斷言「畫出來的階數 ＝ 印在板上的次數」，改了文案不改階數會 FAIL。<b>三格刻度（第 5 輪改）</b>：還沒用的格畫的是<b>當前階</b>（與號碼帶同一支漸層，實測 ΔE ${A(M.scaleDelta, (d) => d.bandMax)}）、用掉的格褪到底並蓋一道<b>朱筆銷記</b>（照相館在存根上劃掉用過的那一格，那一道是有提按的真筆跡，紅筆，與字標那支蠟筆刻意不同支）。第 4 輪未用格永遠畫 stub${USES_TOTAL}，所以帶子走到第幾階刻度上看不到 —— 遮住文字時五個狀態裡有三個逐格 ΔE 為 ${0}。現在逐格對位實測：相鄰狀態最大 ΔE 最小的一組 ${A(M.scaleDelta, (d) => d.adjMin)}、剛印好↔用完了三格最小 ${A(M.scaleDelta, (d) => d.endsMin)}（門檻 ${SCALE_DE.adj}／${SCALE_DE.ends}，G29）。ios-dev：褪色階是這組碼的<b>資料</b>（remaining uses），不是那個畫面的樣式 —— 票根出現在哪裡就帶到哪裡。`,
    },
    {
      id: 'ax-note', x: 0, y: -280, w: 480, page: 'page-2',
      text: `AX5（${Math.round(AX * 100)}%）：內文 ${fs1(TY.b)}pt → ${ax(+fs1(TY.b))}pt。版面不重排、只長高。按鈕裡的 icon 在 AX3 以上一律拿掉只留字；長 Email 在 @ 後面斷行，不切在字中間也不掉孤兒字元。`,
    },
    {
      id: 'axcode-note', x: P + GX, y: -280, w: 480, page: 'page-2',
      text: `邀請碼在 AX5：六格改兩排三格（不橫向壓縮）；票根的 ${fs1(TY.n1)}pt 不跟著放大 —— ${fs1(TY.n1)}×${AX} = ${ax(+fs1(TY.n1))}pt，一行排不下三碼，鎖在分格那一階（${fs1(TY.n2)}pt）的推導值 ${ax(+fs1(TY.n2))}pt 並拆成兩排。Notes 上寫了這兩條規則，這張板把它們畫出來。邀請碼本身是 ${CODE.replace(' ', '').length} 位英數（使用者核定，對齊 LS-33 已上線的產生器），不是純數字。`,
    },
    {
      id: 'grad-note', x: 1400, y: PH + GY - 300, w: 660, page: 'page-1',
      text: `漸層是有帳可查的，不是氣氛。全稿只有一個光源假設（淺色從上、深色從下）與一個時間假設（見光的那一邊先褪），落地成 ${GRAD_KEYS.length} 種漸層：台紙、凹窗兩種、浮起面、主按鈕、票根號碼帶的四階、接縫。三種表面因此各多一個判準 —— 凹＝上暗下亮、浮＝上亮下暗、平印＝沒有漸層。每一種的理由與每一個色停都印在 Tokens 板上（沒印理由的漸層就是裝飾，管線 FAIL）。第 2 輪把「光」與「時間」分家並且量得出來：光只改明度（兩端色相差 ≤${LIGHT_DH}°）、時間會改色相（≥${TIME_DH}°）；而且只有號碼帶是三色停的非等速漸層（膝點 ${STUB_KNEE}%，邊緣加權）—— 時間長得不像光，這是斷言不是說法。實測：漸層 ${A(M.grad, (g) => g.total)} 處、${A(M.grad, (g) => g.kinds)} 種寫法、非垂直 ${A(M.grad, (g) => g.badDir)} 處；壓在漸層上的字 ${A(M.grad, (g) => g.textOn)} 個節點，對比以「字底下那一段漸層裡最不利的一點」計，最低 ${A(M.gradMin, (n) => n)} —— 量不了最不利點的漸層（斜的）一律不准壓字。平印面上的漸層另外逐個使用點掃（G23②）：只有掛牌的號碼帶與騎縫線合法，違規 ${A(M.flatBad, (b) => b.length)} 處。`,
    },
    {
      id: 'signin-note', x: 700, y: -320 - 380, w: 660, page: 'page-1',
      text: `三顆登入鍵的順序是使用者核定的：Apple → Google → Email。上一稿是「Email 在上，順序是唯一的優先訊號」，那是一條讓步 —— 色（主按鈕）與序打架時只好宣告序贏。這一稿順序與視覺重量同向：Apple 在最上，而它在兩種模式下都自動是全頁最重的一塊（淺色純黑 ${ratio(L.appleBg, L.board)}、深色純白 ${ratio(D.appleBg, D.board)}）。Email 這一顆從主按鈕降級成一般浮起面 —— 歡迎頁因此一顆濃玫瑰都沒有。第 2 輪把三顆鍵放進<b>凹下去的台紙托盤</b>（角色 tray，已進「凹＝可以填」白名單）：這一頁最重的兩塊是別人的品牌（Apple 對台紙 ΔE ${dE(L.appleBg, L.board).toFixed(1)}、Google ${dE(L.googleBg, L.board).toFixed(1)}、我們自己的一塊都沒有），收編它們的方法不是把它們調暗，是<b>改它們坐的那個面</b> —— 改自己的東西，不改別人的東西。實測鍵與托盤之間 ΔE 最小 ${A(M.trayDeltaMin, (n) => n)}（${A(M.trayDeltaMinWho, (s) => s)}），深色 Email 鍵原本坐在台紙上，色差落在可辨識門檻邊緣（第 1 輪實測；那一版的深色色票已經不存在，所以這裡不留一個算不回來的數字），坐進托盤就解決了。兩顆品牌鍵一律不加唇邊、不加漸層：連把它規範的 ${FIX.hair}px 描邊加粗成 ${FIX.lip}px 都算改外觀（第 1 輪 R6）。AX5 空間不夠時換官方短標題「登入」，版式不動（第 1 輪 R7）。`,
    },
  ],
  pages: [
    { id: 'page-1', name: 'M1 流程' },
    { id: 'page-2', name: '壓力測試與交付' },
  ],
  launch: { view: 'canvas', page: 'page-1' },
};

writeFileSync(new URL('canvas.json', import.meta.url), JSON.stringify(canvas, null, 2));

/* ── 產物根目錄的身分（第 1 輪 R9）────────────────────────────
   measure.mjs 是在 http server 上量的，而軌 B 的複本檔名、欄位、data-* 標記全部相容 ——
   埠號指到別軌的根目錄時，量到的是別人的畫面，measured.json 卻長得完全正常，
   31 張板的 gate 會**全綠地放行別人的設計**（reviewer 實測重現）。
   build 把「這一份產物」的指紋寫成 _root.json；measure 開跑前先抓 server 上的同名檔
   比對，不一致就 exit 1（fail-closed）；verify 再比對 measured.json 裡記下的那一份。
   指紋 = 軌別 + 板清單 + 每張板的尺寸 —— 換一軌一定不同，同一軌改內容不會誤報。 */
/* ── R9 第二版：指紋要吃內容，不能只吃板清單 ──────────────────────────
   第 2 輪 reviewer 親自踩到：一台殘留在別的目錄上的 http server，板名與尺寸完全一樣，
   `_root.json` 也一樣 —— measure 於是印「根目錄核對 OK」，然後把**別的目錄**的畫面
   量進這一軌的 measured.json。指紋只吃 `檔名:寬x高`，所以「同名不同內容」是它的盲區。

   兩層修法（兩層都必須通過，缺一不可）：
     ① fp 併入 32＋張 .dc.html 的**原文雜湊**。改一個字元，fp 就變 ——
        「同名不同內容」不再是盲區。
     ② _probe.html 把它**實際 fetch 到**的每一份原文再雜湊一次（contentFp），
        measure 拿它跟本地重算的比。①管的是「server 上那份 _root.json 對不對」，
        ②管的是「瀏覽器真的讀到的那 34 份對不對」—— 中間任何一步被換掉都會被咬。 */
const CONTENT_FP = hash12(JSON.stringify(Object.entries(files).sort(([a], [b]) => (a < b ? -1 : 1)).map(([f, src]) => `${f}:${hash12(src)}`)));
const STRUCT_FP = hash12(JSON.stringify([TRACK, canvas.artboards.map((a) => `${a.file}:${a.w}x${a.h}`).sort()]));
const ROOT_FP = hash12(JSON.stringify([STRUCT_FP, CONTENT_FP]));
/* 兩個指紋各管一件事，而且**必須分開**：
     fp（結構＋內容）  measure 開跑前跟 server 上的比。內容在裡面，所以「同名不同內容」
                       的殘留 server 騙不過去 —— 這就是 R9 第二版要的那一條。
     structFp（只有結構）G21b 用。因為管線是 build→measure→build（第二次 build 才把
                       量到的數字印上板），內容雜湊在那一步**必然**會變一次；
                       拿它去驗「量測是不是在本軌量的」會永遠 FAIL，而且是假的 FAIL。
   兩者都寫進 _root.json 與 measured.json，誰在守什麼是印出來的。 */
writeFileSync(new URL('_root.json', import.meta.url), `${JSON.stringify({ track: TRACK, fp: ROOT_FP, structFp: STRUCT_FP, contentFp: CONTENT_FP, boards: canvas.artboards.length }, null, 2)}\n`);

/* ── 具名豁免登記簿的機器可讀版（第 5 輪 D4-07②）────────────────────
   _probe.html 只認這一份清單上的 marker+role+板名：不在清單上的豁免標記**不生效**
   （第 4 輪的 M1b 是「data-light 加任何值都豁免」，這一版那一招當場失效），
   而且 MG2 會反過來驗「畫面上有的」與「清單上有的」是同一個集合。 */
writeFileSync(new URL('_exempt.json', import.meta.url), `${JSON.stringify(EXEMPT, null, 2)}\n`);
console.log(`wrote ${Object.keys(files).length} artboards + canvas.json + _root.json (${TRACK} #${ROOT_FP} / 內容 #${CONTENT_FP})`);
