#!/bin/bash
# qa-driver-gate-check.sh 的自測（LS-232）。CI rules job「Gate 腳本自測」step 跑。
# 合成目錄樹（①～⑩不需要 git——本 gate 純掃描檔案內容，不依賴版本控制歷史；⑪⑫是 LS-232 R2
# 新增的例外，刻意用 `git show <sha>:<path>` 讀真實歷史 SHA 的內容當 fixture，見該段說明）：
#   ① 宣告的 gate 有對應 QADriver 標記處理 → 綠
#   ② 宣告的 gate 缺 QADriver 標記 → 紅，列出漏掉的 View 名＋修法提示
#   ③ mutation：②的 fixture 補上 `// QA-GATE-HANDLED:` 標記後先驗證轉綠，再拿掉標記驗證轉回紅
#      （比照票文「fixture 拿掉 QADriver 的處理 → 紅」）
#   ④ 備援掃描（LS-232 R2 M1 翻面）：`.fullScreenCover` 綁定但沒有 `// QA-GATE:` 標記 → 紅，
#      列出候選 View 名＋位置＋修法提示（原本只印 ⚠、不影響 exit code——對「未 patch 的事故
#      head」會誤判成綠，merge-review R1 M1 指出這是放行了 gate 要擋的那個 commit，見⑪⑫）
#   ⑤ 多個 gate 各自獨立判定：一個有標記一個沒有 → 只列出沒標記的那個，不誤列已處理的
#   ⑥ 參數／環境 fail closed：--repo 指到不存在目錄／找不到 RootView*.swift／找不到
#      QADriver*.swift／`--repo` 缺值／未知參數 → exit 2
#   ⑦ --help → exit 0
#   ⑧ 真 repo（本 PR head）通過
#   ⑨ `// QA-GATE-EXEMPT:` 豁免（LS-232 R2 M1）：備援掃描候選有豁免標記 → 綠，不列入未標記
#   ⑩ `CONTAINER_EXCLUDE` 負樣本（LS-232 R2 m1）：`.sheet { Text(…) }` 這種非 gate 內容不得被
#      備援掃描當候選、不得誤紅（merge-review R1 m1 實測樣本）
#   ⑪⑫ 真實歷史快照回歸（LS-232 R2）：對 LS-217 事故當下「未經任何 patch」的 development head
#      `938e854`／`ebe390a` 各跑一次——兩者的 RootView.swift 內容逐字相同（皆無任何
#      `// QA-GATE` 標記），此處刻意兩個都驗，證明「有沒有寫標記」才是判準，不因為 QADriver
#      當時是否已存在對應的處理程式碼（`ebe390a` 已有 `dismissPushPrepromptIfPresent()`）而
#      放行——這正是 merge-review R1 M1 指出「備援掃描只印 ⚠、不影響 exit code」時的 fail-open
#      案例（修法前對 `938e854` 實測是綠 exit 0）。
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="${root}/scripts/gates/qa-driver-gate-check.sh"
fail=0

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
R="$work/repo"

expect() {
  # expect <期望 exit> <名稱> <輸出必含|''> <輸出必不含|''> <參數…>
  local want=$1 name=$2 must=$3 mustnot=$4 out got
  shift 4
  out="$(bash "$check" "$@" 2>&1)"
  got=$?
  if [ "$got" -eq "$want" ] && { [ -z "$must" ] || printf '%s' "$out" | grep -qF -- "$must"; } && { [ -z "$mustnot" ] || ! printf '%s' "$out" | grep -qF -- "$mustnot"; }; then
    echo "✓ ${name}"
  else
    echo "✗ ${name}（期望 exit ${want}${must:+、輸出含「${must}」}${mustnot:+、輸出不含「${mustnot}」}，實得 ${got}）" >&2
    printf '%s\n' "$out" | sed 's/^/    /' >&2
    fail=1
  fi
}

reset_repo() {
  rm -rf "$R"
  mkdir -p "$R/LittleSprout/Navigation" "$R/LittleSproutUITests/QA"
}

# ---- ① 正：EULAConsentView 宣告且已標記處理 → 綠（EULAConsentView 是條件式整樹替換，不是
#      modifier 綁定——同真 repo 的實際形狀，驗證標記機制不依賴 modifier 掃描）----
reset_repo
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
import SwiftUI
struct AuthenticatedGate: View {
    var body: some View {
        if eulaStore.shouldPresent == true {
            // QA-GATE: EULAConsentView
            EULAConsentView(eulaStore: eulaStore, onDisagree: disagreeAndSignOut)
        }
    }
}
EOF
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    // QA-GATE-HANDLED: EULAConsentView
    var eulaHeading: XCUIElement { app.staticTexts["使用條款更新"].firstMatch }
}
EOF
expect 0 "①宣告且已處理-綠" "宣告的 1 個登入後全屏 gate" "⚠" --repo "$R"

# ---- ② 負：PushPrepromptView 宣告（modifier 綁定）但 QADriver 沒有標記處理 → 紅 ----
reset_repo
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
import SwiftUI
struct AuthenticatedRootView: View {
    var body: some View {
        Group { SectionTabView() }
        // QA-GATE: PushPrepromptView
        .fullScreenCover(isPresented: Binding(get: { pushNotificationStore.showsPreprompt }, set: { _ in })) {
            PushPrepromptView(pushNotificationStore: pushNotificationStore) {}
        }
    }
}
EOF
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    var timelineHeading: XCUIElement { app.staticTexts["時間軸"].firstMatch }
}
EOF
expect 1 "②宣告未處理-紅列出PushPrepromptView" "PushPrepromptView" "" --repo "$R"
out="$(bash "$check" --repo "$R" 2>&1)"
if printf '%s' "$out" | grep -qF '在 QADriver 加落點＋dismiss'; then
  echo "✓ ②紅訊息含修法提示"
else
  echo "✗ ②紅訊息應含修法提示（實得：${out}）" >&2; fail=1
fi

# ---- ③ mutation：②補上 `// QA-GATE-HANDLED:` 標記應轉綠；再拿掉應轉回紅 ----
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    // QA-GATE-HANDLED: PushPrepromptView
    func dismissPushPrepromptIfPresent() throws {}
}
EOF
expect 0 "③mutation補上標記後-綠" "" "" --repo "$R"
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    func dismissPushPrepromptIfPresent() throws {}
}
EOF
expect 1 "③mutation拿掉標記後-轉回紅" "PushPrepromptView" "" --repo "$R"

# ---- ④ 備援掃描（LS-232 R2 M1 翻面）：CreateChildView modifier 沒有 `// QA-GATE:` 標記 →
#      紅，列出候選＋修法提示（不再只印 ⚠、不影響 exit code）----
reset_repo
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
import SwiftUI
struct AuthenticatedRootView: View {
    var body: some View {
        Group { SectionTabView() }
        .fullScreenCover(isPresented: Binding(get: { familyStore.showsChildOnboarding }, set: { _ in })) {
            NavigationStack {
                CreateChildView(childrenStore: childrenStore)
            }
        }
    }
}
EOF
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    var timelineHeading: XCUIElement { app.staticTexts["時間軸"].firstMatch }
}
EOF
expect 1 "④備援掃描未標記轉紅" "CreateChildView" "" --repo "$R"
out="$(bash "$check" --repo "$R" 2>&1)"
if printf '%s' "$out" | grep -qF 'QA-GATE-EXEMPT'; then
  echo "✓ ④紅訊息含QA-GATE-EXEMPT豁免提示"
else
  echo "✗ ④紅訊息應含QA-GATE-EXEMPT豁免提示（實得：${out}）" >&2; fail=1
fi

# ---- ⑤ 多個 gate：一個有處理一個沒有 → 只列出沒處理的，不誤列已處理的 ----
reset_repo
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
import SwiftUI
struct RootView: View {
    var body: some View {
        // QA-GATE: EULAConsentView
        // QA-GATE: PushPrepromptView
        EmptyView()
    }
}
EOF
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    // QA-GATE-HANDLED: EULAConsentView
}
EOF
expect 1 "⑤多個gate只列缺漏那個" "PushPrepromptView" "" --repo "$R"
out="$(bash "$check" --repo "$R" 2>&1)"
if printf '%s' "$out" | grep -qF "EULAConsentView"; then
  echo "✗ ⑤不該把已處理的EULAConsentView也列進缺漏（實得：${out}）" >&2; fail=1
else
  echo "✓ ⑤不誤列已處理的EULAConsentView"
fi

# ---- ⑥ 參數／環境 fail closed ----
expect 2 "⑥repo不存在" "" "" --repo "$work/does-not-exist"
reset_repo
expect 2 "⑥找不到RootView" "" "" --repo "$R"
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
struct RootView {}
EOF
expect 2 "⑥找不到QADriver" "" "" --repo "$R"
expect 2 "⑥--repo缺值" "" "" --repo
expect 2 "⑥未知參數" "" "" --repo "$R" --bogus
expect 2 "⑥多餘位置參數" "" "" --repo "$R" extra

# ---- ⑦ --help ----
expect 0 "⑦--help" "用法" "" --help

# ---- ⑧ 真 repo（本 PR 已加標記）通過，且不需要 --repo（走 git 預設） ----
out="$(cd "$root" && bash "$check" 2>&1)"; got=$?
if [ "$got" -eq 0 ] && printf '%s' "$out" | grep -qF "CreateChildView、EULAConsentView"; then
  echo "✓ ⑧真repo（預設git頂層）通過，列出CreateChildView、EULAConsentView"
else
  echo "✗ ⑧真repo應 exit 0 且列出兩個 gate（實得 exit ${got}）" >&2
  printf '%s\n' "$out" | sed 's/^/    /' >&2
  fail=1
fi

# ---- ⑨ QA-GATE-EXEMPT 豁免（LS-232 R2 M1）：備援掃描候選有豁免標記 → 綠，不列入未標記 ----
reset_repo
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
import SwiftUI
struct AuthenticatedRootView: View {
    var body: some View {
        Group { SectionTabView() }
        // QA-GATE-EXEMPT: CreateChildView（示範用途：非登入後全屏 gate，只是舉例）
        .fullScreenCover(isPresented: Binding(get: { familyStore.showsChildOnboarding }, set: { _ in })) {
            NavigationStack {
                CreateChildView(childrenStore: childrenStore)
            }
        }
    }
}
EOF
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    var timelineHeading: XCUIElement { app.staticTexts["時間軸"].firstMatch }
}
EOF
expect 0 "⑨QA-GATE-EXEMPT豁免-綠" "" "CreateChildView" --repo "$R"

# ---- ⑩ CONTAINER_EXCLUDE 負樣本（LS-232 R2 m1）：`.sheet { Text(…) }` 不得被當候選、不得誤紅
#      （merge-review R1 m1 實測樣本：M1 把備援掃描候選轉紅之後，這種寫法若不排除就是假紅）----
reset_repo
cat > "$R/LittleSprout/Navigation/RootView.swift" <<'EOF'
import SwiftUI
struct AuthenticatedRootView: View {
    var body: some View {
        Group { SectionTabView() }
        .sheet(isPresented: $showHelp) {
            Text("說明文字")
        }
    }
}
EOF
cat > "$R/LittleSproutUITests/QA/QADriver.swift" <<'EOF'
import XCTest
final class QADriver {
    var timelineHeading: XCUIElement { app.staticTexts["時間軸"].firstMatch }
}
EOF
expect 0 "⑩Text假紅案例-綠" "" "Text" --repo "$R"

# ---- ⑪⑫ 真實歷史快照回歸（LS-232 R2）：LS-217 事故當下「未經任何 patch」的 development head
#      `938e854`／`ebe390a`，用 `git show <sha>:<path>` 取 RootView.swift／QADriver.swift 原始內容
#      建 fixture（不是合成樣本）。兩個 SHA 都是 origin/development 的祖先（FF-only 分支流向，
#      不會被 rebase／squash 移除），CI `rules` job `fetch-depth: 0` 抓得到全部分支歷史。----
snap="$work/snap"
for sha in 938e854 ebe390a; do
  rm -rf "$snap"
  mkdir -p "$snap/LittleSprout/Navigation" "$snap/LittleSproutUITests/QA"
  if ! git -C "$root" show "${sha}:LittleSprout/Navigation/RootView.swift" > "$snap/LittleSprout/Navigation/RootView.swift" 2>/dev/null \
    || ! git -C "$root" show "${sha}:LittleSproutUITests/QA/QADriver.swift" > "$snap/LittleSproutUITests/QA/QADriver.swift" 2>/dev/null; then
    echo "✗ ⑪⑫讀不到 ${sha} 的快照內容（git show 失敗，fetch-depth 是否夠？）" >&2
    fail=1
    continue
  fi
  expect 1 "⑪⑫真實快照${sha}未patch轉紅列PushPrepromptView" "PushPrepromptView" "" --repo "$snap"
done

if [ "$fail" -eq 0 ]; then
  echo "qa-driver-gate-check.test.sh：全部通過"
else
  echo "qa-driver-gate-check.test.sh：有失敗" >&2
fi
exit "$fail"
