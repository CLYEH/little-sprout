#!/bin/bash
# qa-driver-gate-check.sh 的自測（LS-232）。CI rules job「Gate 腳本自測」step 跑。
# 合成目錄樹（不需要 git——本 gate 純掃描檔案內容，不依賴版本控制歷史）：
#   ① 宣告的 gate 有對應 QADriver 標記處理 → 綠
#   ② 宣告的 gate 缺 QADriver 標記 → 紅，列出漏掉的 View 名＋修法提示
#   ③ mutation：②的 fixture 補上 `// QA-GATE-HANDLED:` 標記後先驗證轉綠，再拿掉標記驗證轉回紅
#      （比照票文「fixture 拿掉 QADriver 的處理 → 紅」）
#   ④ 備援掃描：`.fullScreenCover` 綁定但沒有 `// QA-GATE:` 標記 → 印 ⚠，但不影響 exit code
#      （candidate 不在宣告清單內，不算「缺漏」；同真 repo 現況的 `CreateChildView` 若拿掉標記
#      會落入的形狀）
#   ⑤ 多個 gate 各自獨立判定：一個有標記一個沒有 → 只列出沒標記的那個，不誤列已處理的
#   ⑥ 參數／環境 fail closed：--repo 指到不存在目錄／找不到 RootView*.swift／找不到
#      QADriver*.swift／`--repo` 缺值／未知參數 → exit 2
#   ⑦ --help → exit 0
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

# ---- ④ 備援掃描 ⚠：CreateChildView modifier 沒有 `// QA-GATE:` 標記 → 印 ⚠，exit 仍 0（不在宣告
#      清單內，不算缺漏）----
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
expect 0 "④備援掃描印警告不轉紅" "⚠" "" --repo "$R"
out="$(bash "$check" --repo "$R" 2>&1)"
if printf '%s' "$out" | grep -qF "CreateChildView"; then
  echo "✓ ④備援掃描點名CreateChildView"
else
  echo "✗ ④備援掃描應點名CreateChildView（實得：${out}）" >&2; fail=1
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

if [ "$fail" -eq 0 ]; then
  echo "qa-driver-gate-check.test.sh：全部通過"
else
  echo "qa-driver-gate-check.test.sh：有失敗" >&2
fi
exit "$fail"
