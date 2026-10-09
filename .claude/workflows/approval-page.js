// .claude/workflows/approval-page.js — Haiku 核可頁產線（LS-429 範圍 4）
// 用法：Workflow({name: 'approval-page', args: {ticket: 'LS-425', vr_comment: '<VR APPROVE comment id>', handoff_comment: '<設計 handoff comment id>',
//        boards_dir: '<worktree>/.claude/evidence/LS-425/r3', questions: ['C1 …（a／b）', …], date: 'YYYY-MM-DD', scratch: '<scratchpad>', gate?: '<gate 路徑>', url?: '<既有 artifact>'}})
// 一支 Haiku 組頁：內容只能引述 VR verdict 與設計 handoff 的原文（含 comment id），不得自己評圖；板圖以路徑嵌入；
// 「待使用者」段列 orchestrator 給的問題（逐字）。寫 md → 跑 report-cite-check → Artifact 發布。orchestrator 收到後抽驗 2 條引據再給使用者。

export const meta = {
  name: 'approval-page',
  description: 'Haiku 核可頁：引述 VR APPROVE verdict 與設計 handoff 原文＋板圖＋待裁決題，經 report-cite-check gate 後發布 artifact',
  whenToUse: '設計票 VR 第 3 輪起 APPROVE 後，送使用者核可前',
  phases: [{ title: 'Compose', detail: '一支 Haiku 讀兩則 comment 與板圖目錄，組頁、過 gate、發布', model: 'haiku' }],
}

const a = args || {}
const gate = a.gate || 'scripts/gates/report-cite-check.sh'
for (const k of ['ticket', 'vr_comment', 'handoff_comment', 'boards_dir', 'date', 'scratch']) {
  if (typeof a[k] !== 'string' || !a[k]) throw new Error(`approval-page 需要字串 args.${k}`)   // R1 I4：非字串 .slice 會 TypeError
}
const imgDir = `${a.scratch}/approval-${a.ticket}-img`
const questions = Array.isArray(a.questions) ? a.questions : []

const SCHEMA = {
  type: 'object',
  properties: {
    md_path: { type: 'string' },
    gate_rc: { type: 'number' },
    gate_output: { type: 'string' },
    url: { type: 'string' },
    board_count: { type: 'number' },
  },
  required: ['md_path', 'gate_rc', 'gate_output', 'url', 'board_count'],
}
// R1 M1：抽驗樣本由 orchestrator 用 `report-cite-check.sh <md> --sample 2` 自己抽，不由組頁員自報。

phase('Compose')
const mdPath = `${a.scratch}/approval-${a.ticket}-${a.date}.md`
const result = await agent(
  `今天是 ${a.date}。你是 Little Sprout 設計核可頁的組頁員，只引述、不評圖。
來源（用 mcp__linear__* 讀，工具失敗改 \`bash scripts/ops/linear-post.sh get ${a.ticket} --comments\`）：
- 票文：get_issue ${a.ticket}（標題、範圍段）。
- VR verdict：list_comments ${a.ticket} 裡 id 以 ${a.vr_comment.slice(0, 8)} 開頭的那則——只抄 Verdict 行、APPROVE 附帶條件、MN／I 清單原文。
- 設計 handoff：id 以 ${a.handoff_comment.slice(0, 8)} 開頭的那則——抄「定案表」（態／板 id／定案一句）與產出位置。
- 板圖：\`ls ${a.boards_dir}\`，檔名＝板 id；每張以相對說明列出（態名＋板 id＋檔案路徑），不要自己描述畫面內容。

固定版型（markdown）：
# ${a.ticket} 核可頁 ${a.date}
## 定案摘要（引述設計 handoff ${a.handoff_comment.slice(0, 8)}）
表格：態｜板 id（淺／深／AX3）｜定案一句（逐字）。
## VR 裁決（引述 ${a.vr_comment.slice(0, 8)}）
Verdict 行原文＋附帶條件逐條；MN／I 以清單列出（每列附 comment id 前 8 碼）。
## 板圖
每張一列：態名｜板 id｜路徑（這段每列帶板 id，id 在 Notes 可反查）。
## 待使用者裁決
${questions.length ? questions.map((q, i) => `${i + 1}. ${q}`).join('\n') : '（orchestrator 未給題，寫「無」）'}
回覆格式提示一行：「回『<題號><選項>』，如 C1a C2b」。

規則：
1. 非豁免段裡的每一行（清單列含編號／縮排、表格資料列、段落句）都是事實列，必含引據（comment id 前 8 碼、板 id 配 LS 票號＋狀態詞、或 commit sha）；只有「待使用者裁決」段（標題必須以這幾個字開頭）豁免。
2. Write 到 ${mdPath}，跑 \`bash ${gate} ${mdPath}\`；rc≠0 只修被點名列（補 id），最多 3 次；仍紅就不發布、回報 gate 原文。
3. gate 綠後 Skill 載入 artifact-design，再用 Artifact 工具發布（檔名 approval-${a.ticket}.html，title「${a.ticket} 核可頁」，icon "design"${a.url ? '，url 參數填 ' + a.url + ' 更新同一頁' : ''}）。**板圖必須看得到**：artifact 讀不到本機路徑，所以先 \`mkdir -p ${imgDir}\`，每張板圖用 \`sips -Z 720 <png> --out ${imgDir}/<板id>.png\` 縮到長邊 720，再用 python3 轉 base64 以 \`<img src="data:image/png;base64,…" alt="<板id>">\` 內嵌（一張一格，格下標「態名｜板 id」），總量控制在 12MB 內（超過就再縮到 540）；不要只列路徑、不要省略任何板。
4. 回傳 md_path／gate_rc／gate_output／url／board_count（抽驗樣本由 orchestrator 用 gate 的 --sample 自己抽，你不必提供）。`,
  { label: `approval:${a.ticket}`, phase: 'Compose', model: 'haiku', schema: SCHEMA },
)

if (!result) throw new Error('核可頁組頁員失敗（null）')
if (result.gate_rc !== 0) log(`⚠ cite gate 紅（rc=${result.gate_rc}），未發布`)
else log(`核可頁已發布：${result.url}（${result.board_count} 張板圖）`)
return { ticket: a.ticket, ...result }
