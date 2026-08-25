# 萌芽日記 Little Sprout

私密家庭相簿與日記 iOS app（SwiftUI + Supabase）。協作規約見 `CLAUDE.md` 與 `docs/COLLABORATION.md`，產品與架構見 `docs/PLAN.md`。

## 本機 demo（在模擬器上看目前進度）

前提：`supabase start` 已跑、Xcode 可用。

```bash
bash scripts/ops/demo-refresh.sh              # 把 .claude/worktrees/demo 移到最新 origin/main，重建並裝進 demo-iPhone17Pro 啟動
bash scripts/ops/demo-refresh.sh origin/test  # 看 QA 中的版本
bash scripts/ops/demo-otp.sh 你的email          # 取 6 碼 Email OTP（本機信件沒有 6 碼；不寄信、不吃額度）
```

Sign in with Apple 在模擬器不能用（需 Apple Developer 帳號），請走 Email OTP。看完記得關模擬器：`xcrun simctl shutdown <UDID>`（腳本結尾會印）。
