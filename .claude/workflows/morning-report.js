// .claude/workflows/morning-report.js — Haiku 日報產線（LS-429）
// 用法：Workflow({name: 'morning-report', args: {date: 'YYYY-MM-DD', now: 'HH:MM', scratch: '<scratchpad 絕對路徑>', url?: '<既有 artifact URL>'}})
// 由巡檢 cron 在每天 08:00 後第一輪印「→ 晨報」動作時觸發（scripts/ops/patrol.sh 晨報段）。
// Phase Collect：7 支 Haiku 收集員並行（lane×5＋git／PR／CI＋成果素材），只回帶 id／路徑的事實；Phase Compose：1 支 Haiku 彙整員寫 markdown、
// 跑 scripts/gates/report-cite-check.sh、用 Artifact 工具發布。LS-495 改版五段：待你決策→成果→正在做→風險與需要你注意→事實列（舊五段全進事實列）。
// args 形狀與 LS-429 相同，改版不新增 args。orchestrator 收到結果後自己跑 `report-cite-check.sh <md_path> --sample 2`
// 取腳本隨機抽的 2 條（R1 M1：不用 Haiku 自報的樣本）反查（get_issue／list_comments／git show）再把當日標記檔 touch 掉；
// 抽到錯就同 args 重跑（Workflow resume 會快取沒變的 agent）。
// Date.now()／new Date() 在 workflow 內不可用，日期一律由 args 帶入。

export const meta = {
  name: 'morning-report',
  description: 'Haiku 晨報：7 支收集員（lane×5＋git/PR/CI＋成果素材）並行收事實，1 支彙整員出五段 artifact（待你決策／成果／正在做／風險／事實列），經 report-cite-check gate',
  whenToUse: '每天 08:00 後第一輪巡檢印「→ 晨報」時由 orchestrator 觸發；或使用者要求重出當日進度報告',
  phases: [
    { title: 'Collect', detail: '每 lane 一支 Haiku 讀 Linear 近 24h 事件；一支讀 git／PR／CI；一支收成果素材（截圖路徑／release 內容／milestone 完成率）', model: 'haiku' },
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
          title: { type: 'string', description: '票標題冒號前的主句原文（沒有冒號就取前 40 字）' },
          state: { type: 'string', description: 'Linear 狀態名，如 In Progress／QA／Done' },
          event: { type: 'string', description: '近 24h 最新一件事，一句，≤60 字；沒有就寫「近 24h 無新 comment」' },
          cite: { type: 'string', description: '該事件的引據：Linear comment id 前 8 碼、PR #號、或 commit sha；沒有事件時寫票號＋狀態' },
          needs_user: { type: 'boolean', description: 'comment 中有「待使用者／請裁／回覆」字樣' },
          user_question: { type: 'string', description: 'needs_user 時逐字抄問句（含選項）；否則空字串' },
          user_background: { type: 'string', description: 'needs_user 時 comment 裡「為什麼要裁」的那一句，逐字；comment 沒寫就空字串' },
          user_recommendation: { type: 'string', description: 'needs_user 時 comment 裡 orchestrator／agent 的建議，逐字；沒寫就空字串' },
          user_consequence: { type: 'string', description: 'needs_user 時 comment 裡「不裁會擋住什麼」，逐字；沒寫就空字串' },
          hold_user: { type: 'boolean', description: '票 labels 含 hold:user' },
          next_step: { type: 'string', description: '在飛票 comment 裡明寫的「下一步」，逐字 ≤60 字；沒寫就空字串（不推測）' },
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

const RESULT_SCHEMA = {
  type: 'object',
  properties: {
    done: {
      type: 'array',
      description: '近 24h Done 的票（全 lane）',
      items: {
        type: 'object',
        properties: {
          ticket: { type: 'string' },
          title: { type: 'string', description: '票標題前 40 字' },
          completed_at: { type: 'string' },
          qa_comment_id: { type: 'string', description: 'QA／收尾 comment id 前 8 碼；沒有就空字串' },
          acceptance: { type: 'string', description: 'QA comment 裡驗收結論那一句，逐字 ≤60 字；沒有就空字串' },
          screenshots: { type: 'array', items: { type: 'string' }, description: 'QA comment 提到、且 test -f 確認存在的截圖絕對路徑；沒有就空陣列' },
        },
        required: ['ticket', 'completed_at', 'qa_comment_id', 'acceptance', 'screenshots'],
      },
    },
    releases: {
      type: 'array',
      description: '近 24h 建立的 release tag（vX.Y.Z）',
      items: {
        type: 'object',
        properties: {
          tag: { type: 'string' },
          prev_tag: { type: 'string' },
          log_first: { type: 'string', description: '`git log --oneline <prev_tag>..<tag>` 的第一行原文' },
          log_lines: { type: 'array', items: { type: 'string' }, description: '同一指令前 8 行原文' },
        },
        required: ['tag', 'prev_tag', 'log_first', 'log_lines'],
      },
    },
    milestones: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          done: { type: 'number', description: 'Linear 沒給票數就省略此欄' },
          total: { type: 'number', description: 'Linear 沒給票數就省略此欄' },
          pct: { type: 'number', description: '完成率整數百分比；Linear 沒給就用 done／total 算' },
        },
        required: ['name', 'pct'],
      },
    },
    cycle: {
      type: 'object',
      properties: { number: { type: 'number' }, done: { type: 'number' }, total: { type: 'number' } },
      required: ['number', 'done', 'total'],
    },
    testflight_build: { type: 'string', description: '近 24h Done 票或其 comment 逐字出現的 TestFlight build 號（附 comment id 前 8 碼）；沒看到就空字串' },
    artifact_links: {
      type: 'array',
      description: '近 24h 票 comment 裡出現的 claude.ai/artifact 連結',
      items: { type: 'object', properties: { url: { type: 'string' }, cite: { type: 'string', description: 'comment id 前 8 碼＋票號' } }, required: ['url', 'cite'] },
    },
    roadmap_steps: { type: 'array', items: { type: 'string' }, description: 'docs/PLAN.md §6「Phase 1」小節的編號步驟標題行，逐字' },
    notes: { type: 'string' },
  },
  required: ['done', 'releases', 'milestones', 'cycle', 'testflight_build', 'artifact_links', 'roadmap_steps', 'notes'],
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
log(`晨報 ${date}：7 支 Haiku 收集員並行`)

const laneTasks = LANES.map(lane => () => agent(
  `${COMMON}
範圍：lane:${lane}。用 list_issues（team LS）列狀態 Ready／In Progress／In Review／QA 的票，加上近 24h 變成 Done／Canceled 的票——**只算 completedAt／canceledAt 在 ${date} 前 24h 內的**（用 get_issue 看 completedAt；舊的 Done 票一律不列），只留 labels 含 lane:${lane} 的。每張票 list_comments 取近 24h 最新一則（作者＋時間＋一句摘要＋id 前 8 碼）；近 24h 沒有 comment 的在飛票 event 寫「近 24h 無新 comment」；comment 含「待使用者」「請裁」「回覆用」「a／b／c」這類字樣就 needs_user=true 並逐字抄問句與選項。超過 12 張票只列最新更新的 12 張，其餘在 notes 寫「另有 N 張未列」。
**讀 comment 原文填欄位（schema 欄位不會自己有值，必須讀）**：對每張 needs_user=true 或 hold_user=true 的票，用 mcp__linear__list_comments 讀被引用的那則 comment 原文（每 lane 最多讀 5 則、每則只看前 1500 字），逐字摘出：user_background＝為什麼要裁的一句；user_question＝問句與選項（a／b 或 核可／退回）；user_recommendation＝orchestrator／agent 的建議；user_consequence＝不裁會擋住什麼。comment 真的沒有該段就填「comment 無此段」（不要填「未載」、不要自己補寫）。對每張在飛票，next_step 摘 comment 裡「→」或「下一步」之後的那句（逐字 ≤60 字）；沒有就填「comment 無此段」。hold_user 看票的 labels 是否含 hold:user。`,
  { label: `collect:${lane}`, phase: 'Collect', model: 'haiku', schema: LANE_SCHEMA },
))

const gitTask = () => agent(
  `${COMMON}
範圍：git／PR／CI。在 repo 根目錄用 Bash（唯讀）：\`git fetch -q origin\`；\`git rev-parse --short origin/main origin/test origin/development\`；\`git describe --tags --abbrev=0 origin/main\`；\`git rev-list --count origin/main..origin/development\` 等三個落後數；\`gh pr list --state open --json number,title,headRefName,baseRefName,statusCheckRollup\`；每個 open PR 的 head sha 用 \`gh api repos/{owner}/{repo}/commits/<sha>/status --jq '.statuses[] | "\\(.context)=\\(.state)"'\` 看 merge-review／qa；\`gh pr list --state merged --search "merged:>=${date}T00:00" --json number,title,mergeCommit\`；\`git tag --sort=-creatordate | head -5\` 配 \`git log -1 --format=%ci <tag>\` 判斷 24h 內；\`git worktree list\`。失敗的命令寫進 notes。`,
  { label: 'collect:git-pr-ci', phase: 'Collect', model: 'haiku', schema: GIT_SCHEMA },
)

// LS-495：成果素材收集員——只收「可直接看的東西」與進度數字，不寫成果句（成果句由彙整員只依素材改寫）
const resultTask = () => agent(
  `${COMMON}
範圍：成果素材。只回 id／路徑／數字，不評價、不改寫。
1. done：用 list_issues（team LS）找 completedAt 在 ${date} 前 24h 內的 Done 票（用 get_issue 確認 completedAt；舊 Done 一律不列）。每張 list_comments 找 QA／收尾 comment（內文含 PASS／QA／收尾／Done 字樣的最新一則），回 id 前 8 碼、驗收結論一句（逐字 ≤60 字），以及 comment 內寫到的截圖路徑（形如 \`.claude/evidence/<票>/qa1/*.png\`、scratchpad 的 \`LS-<n>-evidence/\`）——每個路徑用 Bash \`test -f\` 確認存在（相對路徑從 repo 根目錄起算，回報時轉成以 / 開頭的完整絕對路徑，screenshots 欄不可只回檔名），不存在的丟掉。
2. releases：\`git fetch -q origin --tags\`；\`git tag --sort=-creatordate | head -8\` 配 \`git log -1 --format=%ci <tag>\` 判斷 ${date} 前 24h 內建立的 vX.Y.Z；每個 tag 的 prev_tag 是 \`git tag --sort=-v:refname\` 排序裡它的前一個；\`git log --oneline <prev_tag>..<tag> | head -8\` 原文貼進 log_lines，第一行貼 log_first。
3. milestones：mcp__linear__list_milestones（先 list_projects 取 project，對每個 project 查）；回名稱與完成票數／總票數（Linear 有 progress 欄位就用它的整數百分比，沒有就用 list_issues 該 milestone 的 Done／總數算）。
4. cycle：list_cycles（teamId 020782d9-b525-46e1-8805-965cff30d7d2）取 current cycle 的 number；list_issues 該 cycle 的票數與其中 Done 數。
5. testflight_build：只在上面 Done 票的 comment 裡逐字找「TestFlight」旁的 build 號（例如「3514」），附 comment id 前 8 碼；找不到就空字串，不要去別處推。
6. artifact_links：上面 Done 票與近 24h 有動靜的設計票 comment 內逐字出現的 claude.ai/artifact 連結。
7. roadmap_steps：用 Bash \`sed -n '/^### Phase 1/,/^### Phase 2/p' docs/PLAN.md | grep -E '^[0-9]+\\. '\` 的原文每行一筆。
查不到的段落留空陣列／空字串並在 notes 寫「查無：<段落>」。`,
  { label: 'collect:results', phase: 'Collect', model: 'haiku', schema: RESULT_SCHEMA },
)

// 彙整需要全部收集結果一起排版（跨 lane 的「待使用者」要合併成一段）→ 這裡的 barrier 是必要的
const results = await parallel([...laneTasks, gitTask, resultTask])
const lanes = results.slice(0, LANES.length).filter(Boolean)
const git = results[LANES.length]
const outcome = results[LANES.length + 1]
const missing = LANES.filter((l, i) => !results[i])
if (missing.length) log(`⚠ 收集員失敗：${missing.join('、')}（彙整會標「本 lane 查無」）`)
if (!git) log('⚠ git／PR／CI 收集員失敗（狀態表會標「查無」）')
if (!outcome) log('⚠ 成果素材收集員失敗（成果段只列 git 收集員的 tag／併入 PR）')

phase('Compose')
log('彙整員寫 markdown → cite gate → artifact')

const mdPath = `${scratch}/morning-report-${date}.md`
const imgDir = `${scratch}/morning-report-${date}-img`
const composed = await agent(
  `今天是 ${date}${now ? ' ' + now : ''}。你是 Little Sprout 晨報的彙整員。下面是七支收集員的原始資料（JSON），你只做排版、合併與「把素材改寫成使用者語言」，不新增任何資料裡沒有的事實，不自己發明選項、建議或後果。

收集結果：
${JSON.stringify({ lanes, git, outcome, missing }, null, 2)}

固定版型（markdown，繁體中文，標題照抄，順序不可換；使用者先看到要他決定的事，再看到成果）：
# 晨報 ${date}
## 待你決策
把所有 needs_user=true 或 hold_user=true 的票，合併成一題一個編號項。每題固定四要素（逐字取自收集資料，不要改寫選項）：
1. <題目一句，取 user_question 的主旨>（<票號>）
   - 背景：user_background
   - 選項：user_question 裡的 a／b／c 或「核可／退回」逐字
   - 建議：user_recommendation
   - 不裁的後果：user_consequence
   某一欄是空字串或「comment 無此段」：該欄整行省略，並在這題最後多一行「（comment 未寫的欄位，由 orchestrator 補）」——每題最多這一行、不是每個缺的欄各印一次。四欄都缺的題只印題目行加這一行。
   hold_user=true 但沒有問句的票，題目寫「<票標題>：標 hold:user 等你處置」，其餘照上面規則。沒有任何待決項就整段只寫一列「無」。本段每題來源票號放在題目行括號尾，並在題目行附對應 comment id 前 8 碼（來源是 cite 欄）。
## 成果
**扁平清單，不要在本段加子標題**。依序寫：
- 昨夜版本：outcome.releases（沒有就用 git.tags_24h）每個 tag 一列：「v0.27.70 讓 TestFlight 版能用 Apple 登入（LS-498）」——**用使用者語言寫它能做什麼**（只能改寫該 tag 的 log_lines 與 outcome.done 對應票標題，不加素材沒寫的功能；不用票號當句子主詞）；每列必含該 tag 與對應 Done 票號（票號從 log_lines／done 找；找不到票號的 tag 就寫「v0.27.x 含 <log_first 原文>」並附 commit sha）。
- 可看：每個值得看的東西一列，列首固定「可看：」——outcome.done 的 screenshots **完整絕對路徑**（不可只印檔名；附一句 acceptance 逐字與票號）、outcome.artifact_links 的 url（附 cite）、outcome.testflight_build（若非空）。沒有就整段不寫此類列。
- 里程碑進度：outcome.milestones 每個一列「里程碑進度：<名稱> <pct>%」；done 與 total 兩欄都有才在尾巴加「（<done>/<total> 票）」，沒有就什麼都不加——絕不印「票數查無」。若所有里程碑都沒有票數，只在事實列「風險與查無」寫一列「查無：里程碑票數」。
- Cycle 進度：「Cycle 進度：cycle <number> 完成 <done>/<total> 票」。
- 路線圖位置：「路線圖位置：Phase 1 共 <roadmap_steps 筆數> 步（docs/PLAN.md §6）；進行中里程碑 <完成率最高但未滿 100% 的名稱>」——只陳述數字與名稱，不判斷「現在在第幾步」。
outcome 為 null 時成果段只寫「昨夜版本」列（來源 git），並在事實列的「風險與查無」寫一列固定句：「查無：成果素材收集員失敗（成果段只列 git 來源的 tag）」（句首必須是「查無：」，這樣才符合 gate 缺席句型）。
## 正在做
依 lane 順序列所有在飛票（Ready 以外的 In Progress／In Review／QA），一票一列：「LS-<n> <Linear 狀態名>：<event 一句使用者語言>；下一步：<next_step>（<cite>）」；next_step 是空字串或「comment 無此段」就省略「；下一步：…」整段，不要印「未載」。<event 一句>＝取票 title 冒號前的主句（收集員 title 欄），不自行改寫根因或原因，只可把它換成使用者看得懂的詞。lane 沒有在飛票時不寫任何句子。
## 風險與需要你注意
只列：state 或 event 含 BLOCKED 的票、hold_user 的票、收集員 notes 裡的失敗。每列：「LS-<n> <Linear 狀態名>：<一句原因>（<cite>）」。沒有就整段只寫「無」。（lane 無在飛票、收集員失敗這類缺席陳述一律放事實列的「風險與查無」，不要寫在這段。）
## 事實列
（以下為現行晨報全部內容，供查證與 report-cite-check；本段與其下各小節每行都要有引據）
### 狀態表
表格：main／test／development（sha＋tag）、分支漂移、open PR（每個 PR 一列：#號 標題 head→base CI 審查狀態）。
### 近 24h 完成
清單：只列收集員標為近 24h 內 Done／Canceled 的票（event 不是「近 24h 無新 comment」）與併入 main 的 PR、tag，每列帶 cite；資料裡沒有就寫一列「近 24h 無完成票」。
### 在飛
依 lane 分小標（#### lane:harness …），每票一列：票號 狀態，事件（cite）。lane 沒有在飛票或收集員失敗時**不要在這段寫任何句子**（連小標都省），改寫進「風險與查無」。
### 待使用者
把所有 needs_user 的票列出：票號＋逐字問句與選項，一列一題（本段豁免 cite gate，但仍附 comment id）。
### 風險與查無
（本段是 gate 的缺席句豁免段，專放沒有 id 可引的缺席陳述）收集員 notes 裡的「查無／失敗」、「lane:<x> 無在飛票」、「收集員失敗：無」逐條列出，帶來源 lane；其他段落一律不得出現這類句子。

規則：
1. 除了「待你決策」整段與「成果」段內以「里程碑進度：／Cycle 進度：／路線圖位置：／可看：」開頭、且沒有 id 的標籤列（gate 的段落標題白名單，豁免這兩類）之外，**每一行**（清單列含編號／縮排、表格資料列、段落句）都是事實列，必含引據：comment id 前 8 碼、PR #號、commit sha，或「LS-<n>＋狀態詞」（狀態詞＝Linear 狀態名、PASS／FAIL／BLOCKED／merged、或 tag 形如 v0.27.70）。資料裡沒有 id 的事件改寫成「LS-<n> <狀態>」。
2. 用 Write 寫到 ${mdPath}，然後跑 \`bash ${gate} ${mdPath}\`；rc≠0 就只修被點名的那幾行（補 id 或改成票號＋狀態）再跑一次，最多 3 次；仍紅就停止、不發布，回報 gate 原文。
3. gate 綠後用 Skill 載入 artifact-design，再用 Artifact 工具發布（檔名 morning-report-${date}.html：把 markdown 轉成簡潔 HTML 頁，title「晨報 ${date}」，icon "report"${existingUrl ? '，url 參數填 ' + existingUrl + ' 更新同一頁' : ''}），回 URL。「待你決策」做成最醒目的第一區塊。**截圖必須看得到**：artifact 讀不到本機路徑，所以「可看」列的 png 先 \`mkdir -p ${imgDir}\`，用 \`sips -Z 720 <png> --out ${imgDir}/<檔名>.png\` 縮到長邊 720，再用 python3 轉 base64 以 \`<img src="data:image/png;base64,…" alt="<票號>">\` 內嵌（最多 6 張，總量 ≤6MB，超過再縮到 540；檔案不存在就只留文字路徑並在路徑後加「（檔已清）」，不要中止）。
4. 回傳 md_path／gate_rc／gate_output／url／fact_count。不要在回覆裡貼整份報告（抽驗樣本由 orchestrator 用 gate 的 --sample 自己抽，你不必提供）。`,
  { label: 'compose', phase: 'Compose', model: 'haiku', schema: COMPOSE_SCHEMA },
)

if (!composed) throw new Error('彙整員失敗（null）')
if (composed.gate_rc !== 0) log(`⚠ cite gate 紅（rc=${composed.gate_rc}），未發布：${composed.gate_output.slice(0, 300)}`)
else log(`晨報已發布：${composed.url}（${composed.fact_count} 條事實）`)

return { date, ...composed, lanes_ok: LANES.length - missing.length, git_ok: !!git, outcome_ok: !!outcome }
