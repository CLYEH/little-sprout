#!/bin/bash
# 本機 demo（LS-102）：向本機 GoTrue Admin API 取一組 6 碼 Email OTP（不寄信、不吃 email 額度；
# 本機信件模板自 LS-93 起已含明文 6 碼，此腳本仍走 Admin API 是為了在 demo 時不必真的寄信）。
# 用法：bash scripts/ops/demo-otp.sh <email>     只對本機 127.0.0.1:54321；service_role 從 `supabase status` 讀取、不印出。
set -uo pipefail
email=${1:?用法：demo-otp.sh <email>}
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "✗ 不在 git repo 內" >&2; exit 2; }
cd "$ROOT" || exit 2
key=$(supabase status -o env 2>/dev/null | grep -E '^SERVICE_ROLE_KEY=' | cut -d= -f2- | tr -d '"')
[ -n "$key" ] || { echo "✗ 取不到本機 service_role key（supabase 有跑嗎？）" >&2; exit 2; }
resp=$(curl -s -X POST http://127.0.0.1:54321/auth/v1/admin/generate_link \
  -H "apikey: $key" -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -d "{\"type\":\"magiclink\",\"email\":\"$email\"}")
code=$(printf '%s' "$resp" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("email_otp") or "")' 2>/dev/null)
if [ -n "$code" ]; then echo "OTP for $email: $code"; else echo "✗ 失敗：$(printf '%s' "$resp" | cut -c1-200)" >&2; exit 1; fi
