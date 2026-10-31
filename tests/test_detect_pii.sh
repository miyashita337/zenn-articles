#!/usr/bin/env bash
# tests/test_detect_pii.sh — hooks/lib/detect-pii.sh の最小回帰テスト
# 実行: bash tests/test_detect_pii.sh   (exit 0 = 全 PASS)
# Go 版 yq（mikefarah）でも python-yq でも同じ結果になること（#30）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/hooks/lib/detect-pii.sh"
TMP="$(mktemp -d)"
trap 'rm -r -- "$TMP"' EXIT
fails=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi
}
run() { # $1=blocklist $2=file → exit code
  ZENN_PII_BLOCKLIST="$1" bash "$SCRIPT" "$2" >/dev/null 2>&1
  echo $?
}

printf 'ssh user@My-Test-Host\n' > "$TMP/host.md"
printf 'mail: someone@example.org\n' > "$TMP/mail.md"
printf 'ssh user@hostname\n' > "$TMP/clean.md"

# 値あり・空配列・null・キーなしが混在する blocklist
cat > "$TMP/mixed.yaml" <<'YAML'
hostnames:
  - my-test-host
ips: []
emails:
  - someone@example.org
usernames:
YAML

check "T1 hostname hit (case-insensitive)" "1" "$(run "$TMP/mixed.yaml" "$TMP/host.md")"
check "T2 email hit" "1" "$(run "$TMP/mixed.yaml" "$TMP/mail.md")"
check "T3 clean file" "0" "$(run "$TMP/mixed.yaml" "$TMP/clean.md")"

out="$(ZENN_PII_BLOCKLIST="$TMP/mixed.yaml" bash "$SCRIPT" "$TMP/host.md" 2>&1 >/dev/null)"
check "T4 hit report format" "1" "$(echo "$out" | grep -c '^\[HOSTNAME\] .*host.md:1: my-test-host → hostname$')"

# 読み込みに失敗した blocklist は素通りさせず exit 2（#30 の握りつぶし）
printf 'hostnames: [unclosed\n' > "$TMP/broken.yaml"
check "T5 broken blocklist exits 2" "2" "$(run "$TMP/broken.yaml" "$TMP/host.md")"

# 全カテゴリ空は設定不足ではないので PASS 扱い（既存仕様）
printf 'hostnames: []\nemails: []\n' > "$TMP/empty.yaml"
check "T6 all-empty blocklist passes" "0" "$(run "$TMP/empty.yaml" "$TMP/host.md")"

check "T7 missing blocklist exits 2" "2" "$(run "$TMP/none.yaml" "$TMP/host.md")"

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
