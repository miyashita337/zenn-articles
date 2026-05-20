#!/usr/bin/env bash
#
# detect-pii.sh — テキスト PII 検出ライブラリ
#
# Issue #1: 記事 push 前の PII 漏洩を pre-push hook で自動ブロック
#
# 使い方:
#   bash hooks/lib/detect-pii.sh <file> [<file> ...]
#
# 環境変数:
#   ZENN_PII_BLOCKLIST  blocklist パス (default: ~/.config/zenn-pii-blocklist.yaml)
#
# Exit code:
#   0 = 検出なし
#   1 = PII 検出
#   2 = 設定エラー (blocklist 不在 / yq 不在 等)
#
# 出力フォーマット (検出時, 1 行 1 件, stderr):
#   [TYPE] path:line: 検出値 → 推奨マスク

set -uo pipefail

BLOCKLIST="${ZENN_PII_BLOCKLIST:-$HOME/.config/zenn-pii-blocklist.yaml}"

if [ ! -f "$BLOCKLIST" ]; then
  echo "detect-pii: blocklist not found: $BLOCKLIST" >&2
  echo "  setup: cp hooks/zenn-pii-blocklist.yaml.example $BLOCKLIST" >&2
  exit 2
fi

if ! command -v yq >/dev/null 2>&1; then
  echo "detect-pii: yq not installed (brew install python-yq)" >&2
  exit 2
fi

# 種別ごとの推奨マスク値 (CLAUDE.md 規約準拠)
mask_for() {
  case "$1" in
    HOSTNAME) echo "hostname" ;;
    USERNAME) echo "user" ;;
    EMAIL)    echo "user@example.com" ;;
    IP)       echo "198.51.100.x  # RFC 5737 documentation range" ;;
    TOKEN)    echo "<REDACTED_TOKEN>" ;;
    *)        echo "<MASKED>" ;;
  esac
}

# blocklist から種別の値配列を取得 (空配列・null 安全)
load_values() {
  local key="$1"
  local out
  if ! out=$(yq -r ".${key}[]? // empty" "$BLOCKLIST" 2>&1); then
    echo "detect-pii: error loading $key from $BLOCKLIST: $out" >&2
    exit 2
  fi
  echo "$out"
}

HOSTNAMES="$(load_values hostnames)"
IPS="$(load_values ips)"
EMAILS="$(load_values emails)"
USERNAMES="$(load_values usernames)"
TOKENS="$(load_values tokens)"

if [ -z "$HOSTNAMES$IPS$EMAILS$USERNAMES$TOKENS" ]; then
  # blocklist は存在するが全て空 → 何もしない (設定不足ではないので PASS 扱い)
  exit 0
fi

# ファイルを 1 件ずつ走査
hits=0
scan_file() {
  local file="$1"
  [ -f "$file" ] || return 0

  scan_type() {
    local type="$1"
    local values="$2"
    [ -z "$values" ] && return 0
    local mask
    mask="$(mask_for "$type")"
    while IFS= read -r value; do
      [ -z "$value" ] && continue
      # 大文字小文字を区別しない検索 (-i)。完全一致 (-F)。行番号付き (-n)。
      while IFS=: read -r line content; do
        [ -z "$line" ] && continue
        # コメント行 (yaml/md 内の HTML コメント) や本ファイル自体の例示はスキップしない
        # — false negative 防止のため
        printf '[%s] %s:%s: %s → %s\n' \
          "$type" "$file" "$line" "$value" "$mask" >&2
        hits=$((hits + 1))
      done < <(grep -niF -- "$value" "$file" 2>/dev/null || true)
    done <<< "$values"
  }

  scan_type HOSTNAME "$HOSTNAMES"
  scan_type IP       "$IPS"
  scan_type EMAIL    "$EMAILS"
  scan_type USERNAME "$USERNAMES"
  scan_type TOKEN    "$TOKENS"
}

for f in "$@"; do
  scan_file "$f"
done

if [ "$hits" -gt 0 ]; then
  echo "" >&2
  echo "detect-pii: ${hits} 件の PII を検出しました。マスクしてから再 push してください。" >&2
  echo "  bypass: ZENN_PII_OVERRIDE=1 git push  (意図明示が必要な場合のみ)" >&2
  exit 1
fi

exit 0
