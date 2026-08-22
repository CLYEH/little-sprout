// 自驗：設計稿上「宣稱」的每一件事，都必須在這裡跑得出來。
// 靜態項自己掃 HTML 原始碼；量測項讀 measured.json（measure.mjs 在真瀏覽器裡量的）。
// 第 2 輪被抓到三盞燈接錯線（grep helper 定義、只掃 gap、全幅量死帶），
// 所以 G1–G12 全部進管線，reviewer 拒絕管線外自證。
// Run: node measure.mjs && node verify.mjs
import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { T, GAPS, SIZES, FIX, AX, RULE, H1_GROUPS, H1_EXCLUDED, hash12 } from './tokens.mjs';

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

/* ══ G4  紅訊號：一張板最多兩處酒紅 ══════════════════════════════ */
{
  const rows = [];
  for (const f of files) {
    if (/Tokens|Notes/.test(f)) continue;
    const body = read(f).replace(/--ls-wine:[^;]+;/g, '');
    const n = [...body.matchAll(new RegExp(T.light.wine, 'gi'))].length + [...body.matchAll(new RegExp(T.dark.wine, 'gi'))].length;
    if (n) rows.push([f, n]);
  }
  const bad = rows.filter(([, n]) => n > 2);
  ok(bad.length === 0, `G4 紅訊號：有酒紅的 ${rows.length} 張板，每張 ≤2 處`,
    bad.length ? bad.map(([f, n]) => `${f}=${n}`).join(' ') : rows.map(([f, n]) => `${f.replace('.dc.html','')}:${n}`).join(' '));
}

/* ══ G5  「凹＝可以填」：掃使用點的 computed box-shadow ══════════
   第 2 輪只 grep helper 定義，實測 49 個非可填元件帶 inset。 */
if (M.insetBad) {
  ok(M.insetBad.length === 0, `G5 凹的白名單：${M.insetTotal} 個帶 inset 的使用點，全部落在八個角色`,
    M.insetBad.length ? M.insetBad.slice(0, 6).join(' | ') : Object.entries(M.insetUse).map(([k, v]) => `${k}×${v}`).join(' '));
  ok(!/const raise[\s\S]{0,400}?inset/.test(src), 'G5 浮起只有兩層：raise() 沒有 inset（第三層 topLight 已移除）');
  ok(/border-bottom:\$\{FIX\.lip\}px/.test(src), 'G5 浮起保留 3pt 唇邊');
  ok(!/const flat =[\s\S]*?box-shadow/.test(src.slice(src.indexOf('const flat ='), src.indexOf('const press ='))), 'G5 平印：flat() 沒有 inset、沒有 box-shadow');
  ok(/const win[\s\S]{0,300}?inset 0 1\.5px 0/.test(src), 'G5 凹窗：win() 保留上緣內陰影（真凹沒有被動到）');
} else need('insetBad', 'G5 凹的白名單');

/* ══ G6  對比：節點級，全部 AAA，而且沒有字壓在照片上 ══════════ */
if (M.contrastNodes) {
  ok(M.contrastFails.length === 0, `G6 對比：${M.contrastNodes} 個文字節點全部 ≥7:1（最低 ${M.contrastMin} @ ${M.contrastWorst}）`,
    M.contrastFails.slice(0, 6).join(' | '));
  ok(M.textOverPhoto === 0, `G6 照片上文字：${M.textOverPhoto} 個（壓在照片上的對比無法定義，所以一個都不能有）`);
} else need('contrastNodes', 'G6 對比');

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
  const GROUPS = /<span[^>]*>(\d{3})<\/span>\s*<span[^>]*>(\d{3})<\/span>/;
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

  ok(/念的時候是「七四二、九三六」。/.test(join), 'G7 「念的時候是「七四二、九三六」。」還在（畫面的分組＝嘴巴唸的分組）');
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
  const PAUSE = RULE.pause, FLOW = (f) => !/Tokens|Notes|Stress/.test(f);
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
    ['身分選項選中＝更亮', 'InviteRequests.dc.html'],
    ['待核清單收成一列', 'InviteRequestsMany.dc.html'],
    ['票根降成一行', 'InviteRequestsMany.dc.html'],
    ['iPad 三段式登入', 'WelcomeIPad.dc.html'],
    ['iPad 雙欄三岔路', 'ForkIPad.dc.html'],
    ['深色光源反轉', 'InviteApprovalOffDark.dc.html'],
  ];
  const missing = claims.filter(([, f]) => !files.includes(f));
  ok(missing.length === 0, `G15 Notes 要求的 ${claims.length} 種版式，每一種都有板畫出來`, missing.map(([c]) => c).join(' '));
  // 手寫字標的三個使用點
  const inkBoards = files.filter((f) => /aria-label="小芽"/.test(read(f)));
  ok(inkBoards.length >= 8, `G15 手寫字標出現在 ${inkBoards.length} 張板（歡迎×4、信件明細×2、建立家庭×3、Tokens）`);
  ok(/Main|Welcome/.test(inkBoards.join()) && /Email\.dc/.test(inkBoards.join()) && /CreateFamily\.dc/.test(inkBoards.join()),
    'G15 手寫字標跨板縫合：歡迎頁 → 信件明細「寄件人」 → 建立家庭即時預覽');
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
  ok(Object.keys(M.lips).every((k) => /^(ctaDeep|edge|wine)@/.test(k)),
    'G19 唇邊只有三種顏色，而且都是該表面的深一階（陶土→ctaDeep、卡紙→edge、危險→wine）',
    Object.keys(M.lips).filter((k) => !/^(ctaDeep|edge|wine)@/.test(k)).join(' '));
  ok(M.lipNoneWho.every((s) => /:(button|switch)$/.test(s)) && M.lipNone === 7,
    `G19 沒有唇邊的浮起面只有兩種、共 ${M.lipNone} 個：Apple 鍵（HIG 不可改外觀）與審核開關 ON 的軌道（膠囊軌道，唇邊會壓到把手行程）—— 例外印在 Tokens 板上`,
    M.lipNoneWho.join(' '));
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
    const LIT_OK = [/AX[35]/g, /H1/g, /第 2 輪/g];   // 級名（AX3／AX5／H1）與歷史敘述，不是規格數字
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
      `G20 註記無手打數字：${notes.length} 則註記的模板裡，阿拉伯數字一律出自 \${}（例外只有 AX3／AX5 級名與「第 2 輪」）`,
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
