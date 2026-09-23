#!/usr/bin/env bash
#
# verify-sources.sh — 記事の出典 (sources/<slug>.yaml) を再実行し、期待値と一致するか検査する
#
# 記事の各「出典:」行は sources/<slug>.yaml の 1 エントリ (id: Sxx) に対応する。
# 会長が出典コマンドを 1 つずつ手で叩かなくても、この 1 コマンドで全出典を再検証できる。
#
# 使い方:
#   bash scripts/verify-sources.sh <slug> [--only S01,S03]
#
# 環境変数（yaml の cwd / cmd から参照する。/Users/... を yaml に書かないための間接化）:
#   CORP_DIR            (default: ~/corp)
#   AGENT_BASE_DIR      (default: ~/agent-base)
#   CONVERT_SERVICE_DIR (default: ~/convert-service)
#   GH_OWNER            (default: gh api user の login)
#   SOURCES_FILE / ARTICLE_FILE  テスト用の上書き
#
# yaml の kind:
#   cmd    … cwd で bash -c "cmd" を実行し、trim した stdout を expect と比較
#   file   … path が存在するか
#   manual … 自動再実行できない出典（レシート等）。SKIP として note を表示
#
# Exit code (hooks/lib/detect-pii.sh と同じ流儀):
#   0 = FAIL なし / 1 = FAIL あり / 2 = 設定エラー (yaml 不在・yq 不在 等)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLUG="${1:-}"
[ -n "$SLUG" ] || { echo "usage: bash scripts/verify-sources.sh <slug> [--only S01,S03]" >&2; exit 2; }
shift
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    *) echo "verify-sources: unknown argument: $1" >&2; exit 2 ;;
  esac
done

YAML="${SOURCES_FILE:-$REPO_ROOT/sources/$SLUG.yaml}"
ARTICLE="${ARTICLE_FILE:-$REPO_ROOT/articles/$SLUG.md}"

[ -f "$YAML" ] || { echo "verify-sources: sources file not found: $YAML" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "verify-sources: yq not installed (brew install python-yq)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "verify-sources: jq not installed" >&2; exit 2; }

export CORP_DIR="${CORP_DIR:-$HOME/corp}"
export AGENT_BASE_DIR="${AGENT_BASE_DIR:-$HOME/agent-base}"
export CONVERT_SERVICE_DIR="${CONVERT_SERVICE_DIR:-$HOME/convert-service}"
if [ -z "${GH_OWNER:-}" ]; then
  GH_OWNER="$(gh api user -q .login 2>/dev/null || true)"
fi
export GH_OWNER

field() { # $1=index $2=key
  yq -r ".sources[$1].$2 // \"\"" "$YAML"
}

n="$(yq -r '.sources | length' "$YAML")"
[ "$n" -gt 0 ] 2>/dev/null || { echo "verify-sources: no sources in $YAML" >&2; exit 2; }

pass=0; fail=0; skip=0
echo "## 出典再検証: $SLUG ($(date +%F))"
echo
echo "| id | claim | expect | actual | 判定 |"
echo "|---|---|---|---|---|"

for ((i = 0; i < n; i++)); do
  id="$(field "$i" id)"
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$id,"* ]]; then continue; fi
  kind="$(field "$i" kind)"
  claim="$(field "$i" claim)"
  expect="$(field "$i" expect)"
  actual=""
  verdict=""
  case "$kind" in
    cmd)
      cwd="$(field "$i" cwd)"
      cmd="$(field "$i" cmd)"
      eval "cwd_expanded=\"${cwd:-$REPO_ROOT}\""
      if actual="$(cd "$cwd_expanded" 2>/dev/null && bash -c "$cmd" 2>/dev/null)"; then
        actual="$(printf '%s' "$actual" | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
        if [ "$actual" = "$expect" ]; then verdict="PASS"; else verdict="FAIL"; fi
      else
        actual="(command failed)"; verdict="FAIL"
      fi
      ;;
    file)
      path="$(field "$i" path)"
      eval "path_expanded=\"$path\""
      if [ -e "$path_expanded" ]; then actual="exists"; verdict="PASS"; else actual="missing"; verdict="FAIL"; fi
      expect="exists"
      ;;
    manual)
      actual="$(field "$i" note)"
      verdict="SKIP"
      ;;
    *)
      actual="unknown kind: $kind"; verdict="FAIL"
      ;;
  esac
  case "$verdict" in
    PASS) pass=$((pass + 1)) ;;
    FAIL) fail=$((fail + 1)) ;;
    SKIP) skip=$((skip + 1)) ;;
  esac
  # 表のセルではパイプを潰す
  printf '| %s | %s | %s | %s | %s |\n' "$id" "${claim//|/／}" "${expect//|/／}" "${actual//|/／}" "$verdict"
done

echo
echo "PASS $pass / FAIL $fail / SKIP $skip"

# 記事との突合（WARN のみ。記事が無い場合は省略）
if [ -f "$ARTICLE" ] && [ -z "$ONLY" ]; then
  ids_yaml="$(yq -r '.sources[].id' "$YAML" | sort -u)"
  ids_article="$(grep '^出典:' "$ARTICLE" | grep -oE 'S[0-9]{2}' | sort -u)"
  missing_in_article="$(comm -23 <(echo "$ids_yaml") <(echo "$ids_article") | paste -sd, -)"
  unknown_in_article="$(comm -13 <(echo "$ids_yaml") <(echo "$ids_article") | paste -sd, -)"
  no_id_lines="$(grep -c '^出典:' "$ARTICLE" | tr -d ' ')"
  with_id_lines="$(grep -cE '^出典:.*S[0-9]{2}' "$ARTICLE" | tr -d ' ')"
  [ -n "$missing_in_article" ] && echo "WARN: yaml にあるが記事の出典行に無い id: $missing_in_article" >&2
  [ -n "$unknown_in_article" ] && echo "WARN: 記事にあるが yaml に無い id: $unknown_in_article" >&2
  if [ "$no_id_lines" != "$with_id_lines" ]; then
    echo "WARN: id の無い出典行: $((no_id_lines - with_id_lines)) 行" >&2
  fi
fi

[ "$fail" -eq 0 ]
