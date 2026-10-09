// .claude/workflows/morning-report.js — Haiku 日報產線（LS-429）
// 用法：Workflow({name: 'morning-report', args: {date: 'YYYY-MM-DD', now: 'HH:MM', scratch: '<scratchpad 絕對路徑>', url?: '<既有 artifact URL>'}})
// 由巡檢 cron 在每天 08:00 後第一輪印「→ 晨報」動作時觸發（scripts/ops/patrol.sh 晨報段）。
// Phase Collect：6 支 Haiku 收集員並行（lane×5＋git／PR／CI），只回帶 id 的事實；Phase Compose：1 支 Haiku 彙整員寫 markdown、
// 跑 scripts/gates/report-cite-check.sh、用 Artifact 工具發布。orchestrator 收到結果後自己跑 `report-cite-check.sh <md_path> --sample 2`
// 取腳本隨機抽的 2 條（R1 M1：不用 Haiku 自報的樣本）反查（get_issue／list_comments／git show）再把當日標記檔 touch 掉；
// 抽到錯就同 args 重跑（Workflow resume 會快取沒變的 agent）。
// Date.now()／new Date() 在 workflow 內不可用，日期一律由 args 帶入。

export const meta = {
  name: 'morning-report',
  description: 'Haiku 晨報：6 支收集員（lane×5＋git/PR/CI）並行收事實，1 支彙整員出 artifact，經 report-cite-check gate',
  whenToUse: '每天 08:00 後第一輪巡檢印「→ 晨報」時由 orchestrator 觸發；或使用者要求重出當日進度報告',
  phases: [
    { title: 'Collect', detail: '每 lane 一支 Haiku 讀 Linear 近 24h 事件；一支讀 git／PR／CI', model: 'haiku' },
    { title: 'Compose', detail: '一支 Haiku 合併成固定版型、過 cite gate、發布 artifact', model: 'haiku' },
  ],
}

const date = args && args.date
const now = (args && args.now) || ''
const scratch = args && args.scratch
const existingUrl = (args && args.url) || ''
// gate 路徑可用 args.gate 覆寫（LS-429 併入 main 前從票 worktree 跑試點時給絕對路徑）
const gate = (args && args.gate) || 'scripts/gates/report-cite-check.sh'
if (!date || !scratch) throw new Error('morning-report 需要 args.date 與 args.scratch')

const LANES = ['harness', 'backend', 'design', 'ui', 'product']

const LANE_SCHEMA = {
  type: 'object',
  properties: {
    lane: { type: 'string' },
    items: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          ticket: { type: 'string', description: 'LS-<n>' },
          title: { type: 'string', description: '票標題前 40 字' },
          state: { type: 'string', description: 'Linear 狀態名，如 In Progress／QA／Done' },
          event: { type: 'string', description: '近 24h 最新一件事，一句，≤60 字；沒有就寫「近 24h 無新 comment」' },
          cite: { type: 'string', description: '該事件的引據：Linear comment id 前 8 碼、PR #號、或 commit sha；沒有事件時寫票號＋狀態' },
          needs_user: { type: 'boolean', description: 'comment 中有「待使用者／請裁／回覆」字樣' },
          user_question: { type: 'string', description: 'needs_user 時逐字抄問句（含選項）；否則空字串' },
        },
        required: ['ticket', 'state', 'event', 'cite', 'needs_user'],
      },
    },
    notes: { type: 'string', description: '查不到／工具失敗的範圍，沒有就空字串' },
  },
  required: ['lane', 'items', 'notes'],
}

const GIT_SCHEMA = {
  type: 'object',
  properties: {
    main: { type: 'string', description: 'origin/main 短 sha＋最新 tag，如 a4cdce8 v0.27.29' },
    test: { type: 'string' },
    development: { type: 'string' },
    drift: { type: 'string', description: 'dev←main／test←main／test←dev 落後數，如 0／0／0' },
    open_prs: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          number: { type: 'number' },
          title: { type: 'string' },
          head: { type: 'string' },
          base: { type: 'string' },
          ci: { type: 'string', description: 'success／failure／pending／none' },
          review_status: { type: 'string', description: 'commit status merge-review／qa 的值，或 none' },
        },
        required: ['number', 'title', 'head', 'base', 'ci'],
      },
    },
    merged_24h: { type: 'array', items: { type: 'string' }, description: '近 24h 併入 main 的 PR 一行一筆：#號 標題 sha' },
    tags_24h: { type: 'array', items: { type: 'string' } },
    worktrees: { type: 'array', items: { type: 'string' }, description: 'git worktree list 每筆：路徑 basename＋分支' },
    notes: { type: 'string' },
  },
  required: ['main', 'test', 'development', 'drift', 'open_prs', 'merged_24h', 'tags_24h', 'worktrees', 'notes'],
}

const COMPOSE_SCHEMA = {
  type: 'object',
  properties: {
    md_path: { type: 'string' },
    gate_rc: { type: 'number' },
    gate_output: { type: 'string' },
    url: { type: 'string', description: 'artifact URL；gate 紅未發布則空字串' },
    fact_count: { type: 'number' },
  },
  required: ['md_path', 'gate_rc', 'gate_output', 'url', 'fact_count'],
}
// R1 M1：抽驗樣本不由受驗的 Haiku 自報——orchestrator 收到 md_path 後自己跑 `report-cite-check.sh <md> --sample 2`，
// 由腳本從已查事實列隨機抽，再反查印出的 2 條。

const COMMON = `今天是 ${date}${now ? ' ' + now : ''}。你是 Little Sprout 晨報的收集員，只回報「看到的事實＋可反查的 id」：
- Linear 用 mcp__linear__* 工具（ToolSearch 載入 list_issues／get_issue／list_comments）；工具失敗改 \`bash scripts/ops/linear-post.sh get LS-<n> --comments\`，再不行就在 notes 寫「查無」。
- 沒親眼看到的不寫、不推測、不給建議；comment 裡的問句逐字抄。
- 每筆 cite 一定要是 comment id 前 8 碼、PR #號或 commit sha；拿不到 id 的事件寫成「票號＋狀態」。
- 一次查完再回；不要中途停下問。`

phase('Collect')
log(`晨報 ${date}：6 支 Haiku 收集員並行`)

const laneTasks = LANES.map(lane => () => agent(
  `${COMMON}
範圍：lane:${lane}。用 list_issues（team LS）列狀態 Ready／In Progress／In Review／QA 的票，加上近 24h 變成 Done／Canceled 的票——**只算 completedAt／canceledAt 在 ${date} 前 24h 內的**（用 get_issue 看 completedAt；舊的 Done 票一律不列），只留 labels 含 lane:${lane} 的。每張票 list_comments 取近 24h 最新一則（作者＋時間＋一句摘要＋id 前 8 碼）；近 24h 沒有 comment 的在飛票 event 寫「近 24h 無新 comment」；comment 含「待使用者」「請裁」「回覆用」「a／b／c」這類字樣就 needs_user=true 並逐字抄問句與選項。超過 12 張票只列最新更新的 12 張，其餘在 notes 寫「另有 N 張未列」。`,
  { label: `collect:${lane}`, phase: 'Collect', model: 'haiku', schema: LANE_SCHEMA },
))

const gitTask = () => agent(
  `${COMMON}
範圍：git／PR／CI。在 repo 根目錄用 Bash（唯讀）：\`git fetch -q origin\`；\`git rev-parse --short origin/main origin/test origin/development\`；\`git describe --tags --abbrev=0 origin/main\`；\`git rev-list --count origin/main..origin/development\` 等三個落後數；\`gh pr list --state open --json number,title,headRefName,baseRefName,statusCheckRollup\`；每個 open PR 的 head sha 用 \`gh api repos/{owner}/{repo}/commits/<sha>/status --jq '.statuses[] | "\\(.context)=\\(.state)"'\` 看 merge-review／qa；\`gh pr list --state merged --search "merged:>=${date}T00:00" --json number,title,mergeCommit\`；\`git tag --sort=-creatordate | head -5\` 配 \`git log -1 --format=%ci <tag>\` 判斷 24h 內；\`git worktree list\`。失敗的命令寫進 notes。`,
  { label: 'collect:git-pr-ci', phase: 'Collect', model: 'haiku', schema: GIT_SCHEMA },
)

// 彙整需要全部收集結果一起排版（跨 lane 的「待使用者」要合併成一段）→ 這裡的 barrier 是必要的
const results = await parallel([...laneTasks, gitTask])
const lanes = results.slice(0, LANES.length).filter(Boolean)
const git = results[LANES.length]
const missing = LANES.filter((l, i) => !results[i])
if (missing.length) log(`⚠ 收集員失敗：${missing.join('、')}（彙整會標「本 lane 查無」）`)
if (!git) log('⚠ git／PR／CI 收集員失敗（狀態表會標「查無」）')

phase('Compose')
log('彙整員寫 markdown → cite gate → artifact')

const mdPath = `${scratch}/morning-report-${date}.md`
const composed = await agent(
  `今天是 ${date}${now ? ' ' + now : ''}。你是 Little Sprout 晨報的彙整員。下面是六支收集員的原始資料（JSON），你只做排版與合併，不新增任何資料裡沒有的事實，不寫建議、不下判斷。

收集結果：
${JSON.stringify({ lanes, git, missing }, null, 2)}

固定版型（markdown，繁體中文，標題照抄）：
# 晨報 ${date}
## 狀態表
表格：main／test／development（sha＋tag）、分支漂移、open PR（每個 PR 一列：#號 標題 head→base CI 審查狀態）。
## 近 24h 完成
清單：只列收集員標為近 24h 內 Done／Canceled 的票（event 不是「近 24h 無新 comment」）與併入 main 的 PR、tag，每列帶 cite；資料裡沒有就寫一列「近 24h 無完成票」。
## 在飛
依 lane 分小標（### lane:harness …），每票一列：票號 狀態，事件（cite）。lane 失敗的寫一列「本 lane 查無（收集員失敗）」。
## 待使用者
把所有 needs_user 的票列出：票號＋逐字問句與選項，一列一題（這段豁免 cite gate，但仍附 comment id）。
## 風險與查無
收集員 notes 裡的「查無／失敗」逐條列出，帶來源 lane。

規則：
1. 每條事實列（清單列、表格資料列）必含引據：comment id 前 8 碼、PR #號、commit sha，或「LS-<n>＋狀態詞」。資料裡沒有 id 的事件改寫成「LS-<n> <狀態>」。
2. 用 Write 寫到 ${mdPath}，然後跑 \`bash ${gate} ${mdPath}\`；rc≠0 就只修被點名的那幾行（補 id 或改成票號＋狀態）再跑一次，最多 3 次；仍紅就停止、不發布，回報 gate 原文。
3. gate 綠後用 Skill 載入 artifact-design，再用 Artifact 工具發布（檔名 morning-report-${date}.html：把 markdown 轉成簡潔 HTML 頁，title「晨報 ${date}」，icon "report"${existingUrl ? '，url 參數填 ' + existingUrl + ' 更新同一頁' : ''}），回 URL。
4. 回傳 md_path／gate_rc／gate_output／url／fact_count。不要在回覆裡貼整份報告（抽驗樣本由 orchestrator 用 gate 的 --sample 自己抽，你不必提供）。`,
  { label: 'compose', phase: 'Compose', model: 'haiku', schema: COMPOSE_SCHEMA },
)

if (!composed) throw new Error('彙整員失敗（null）')
if (composed.gate_rc !== 0) log(`⚠ cite gate 紅（rc=${composed.gate_rc}），未發布：${composed.gate_output.slice(0, 300)}`)
else log(`晨報已發布：${composed.url}（${composed.fact_count} 條事實）`)

return { date, ...composed, lanes_ok: LANES.length - missing.length, git_ok: !!git }
