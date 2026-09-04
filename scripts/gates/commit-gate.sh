#!/bin/bash
# Commit gate（pre-commit）：保護分支、branch 命名、secrets 掃描、已追蹤檔不得命中 .gitignore、
# staged 新增行不得含衝突標記、審查取證不進版控、staged .pen 落地檢查、staged Swift 檔 lint。
# 規約見 docs/COLLABORATION.md §4、§7。
set -euo pipefail

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "DETACHED")

case "$branch" in
  main|test|development)
    if [ "${ALLOW_PROTECTED:-0}" != "1" ]; then
      echo "✗ commit gate：禁止直接 commit 到 ${branch}。請開 feature/fix/hotfix branch 走 PR。" >&2
      exit 1
    fi
    echo "⚠ commit gate：ALLOW_PROTECTED=1 覆寫，直接 commit 到 ${branch}" >&2
    ;;
  DETACHED)
    # rebase／cherry-pick 進行中，跳過命名檢查
    ;;
  *)
    if ! printf '%s' "$branch" | grep -qE '^(feature|fix|hotfix)/LS-[1-9][0-9]*-[a-z0-9][a-z0-9-]*$'; then
      echo "✗ commit gate：branch 名稱「${branch}」不符 (feature|fix|hotfix)/LS-<n>-<slug> 規約。" >&2
      exit 1
    fi
    ;;
esac

# Secrets 掃描（staged 新增行；pattern 與 CI 共用 scan-secrets.sh，無路徑盲區）
# grep 需 || true 守衛：純刪除的 commit 沒有新增行，pipefail 下會靜默炸掉整個 gate
added=$(git diff --cached --diff-filter=ACM --unified=0 | grep '^+' | grep -v '^+++' || true)
printf '%s\n' "$added" | bash "$(git rev-parse --show-toplevel)/scripts/gates/scan-secrets.sh"

# 已追蹤檔不得命中 .gitignore（LS-51：設計畫布執行產物——ignore 規則管不到已追蹤／git add -f 硬加的檔）
bash "$(git rev-parse --show-toplevel)/scripts/gates/tracked-ignored-check.sh"

# 衝突標記（LS-157）：staged 新增行以 <<<<<<< ／=======（整行）／>>>>>>> 開頭即擋——解衝突解一半就 commit
# （LS-154 back-merge 實際踩到，靠 push 前自查才抓回）
bash "$(git rev-parse --show-toplevel)/scripts/gates/conflict-marker-check.sh"

# 審查取證不得進版控（LS-61：staged 路徑任一目錄層命中 review*／*-review*／ls[0-9]*、或 *.png 不在 design/／
# LittleSprout/Assets.xcassets/／LittleSprout/Preview Content/／docs/img/ 白名單即擋（大小寫不敏感）——.gitignore 只認固定位置 .claude/evidence/，散落路徑沒規則可 ignore）
bash "$(git rev-parse --show-toplevel)/scripts/gates/evidence-path-check.sh"

# design/ 大檔二進位體積 gate（LS-74）：design/ 下新增／修改的二進位檔 >500 KB 即擋，文字檔（.pen JSON、
# design/evidence/*.json）不限——只擋這次 diff 觸碰到的檔，既有未動的大檔不受影響
bash "$(git rev-parse --show-toplevel)/scripts/gates/design-asset-size-check.sh"

# staged .pen 設計稿落地檢查（LS-26：機械觸發點——不靠 agent 記得跑收工程序）
# for 迴圈而非 pipe|while：檢查失敗要能中止整個 gate，不被 subshell 吞掉
staged_pen=$(git -c core.quotePath=false diff --cached --name-only --diff-filter=ACM | grep '\.pen$' || true)
if [ -n "$staged_pen" ]; then
  root=$(git rev-parse --show-toplevel)
  while IFS= read -r p; do
    bash "${root}/scripts/gates/design-landing-check.sh" "${root}/${p}"
  done <<< "$staged_pen"
fi

# staged Swift 檔 lint（fail loud：有 Swift 變更但沒裝 SwiftLint 就擋下，不靜默跳過）
staged_swift=$(git diff --cached --name-only --diff-filter=ACM | grep '\.swift$' || true)
if [ -n "$staged_swift" ]; then
  if ! command -v swiftlint >/dev/null 2>&1; then
    echo "✗ commit gate：有 Swift 變更但未安裝 SwiftLint（brew install swiftlint）。" >&2
    exit 1
  fi
  echo "$staged_swift" | xargs swiftlint lint --strict --quiet
fi

echo "✓ commit gate 通過"
