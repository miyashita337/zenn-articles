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
# 環境変数（yaml の cwd / path から参照できるのは下の ALLOWED_VARS だけ。/Users/... を yaml に書かないための間接化）:
#   HOME
#   CORP_DIR            (default: ~/corp)
#   AGENT_BASE_DIR      (default: ~/agent-base)
#   CONVERT_SERVICE_DIR (default: ~/convert-service)
#   REPO_ROOT           (この repo のルート)
#   GH_OWNER            (default: gh api user の login。cmd 内から参照する)
#   SOURCES_FILE / ARTICLE_FILE  テスト用の上書き
#
# yaml の kind:
#   cmd    … cwd で bash -c "cmd" を実行し、trim した stdout を expect と比較
#   file   … path が存在するか
#   manual … 自動再実行できない出典（レシート等）。SKIP として note を表示
#
# yaml の任意フィールド:
#   citations_in_article: false  … 本文に「出典:」行を置かない記事（出典が非公開 repo 由来で読者が追えない等、
#                                   会長判断）。citations_note に理由を書く。記事⇄yaml の突合は INFO 表示のみになる
#
# 信頼モデル（重要）:
#   kind: cmd は yaml に書かれたコマンドをそのまま実行する（それがこのスクリプトの目的）。
#   したがって sources/<slug>.yaml は tests/*.sh と同じ「実行されるコード」として扱うこと。
#   自分が書いていない branch / PR の yaml を実行する前に `git diff origin/main -- sources/` で中身を読む。
#   cwd / path は eval しない（許可した環境変数の文字列置換のみ。$(…) やバッククォートが残れば FAIL）。
#
# Exit code (hooks/lib/detect-pii.sh と同じ流儀):
#   0 = FAIL なし / 1 = FAIL あり（コマンド不一致、または記事⇄yaml の出典 id 不整合）/ 2 = 設定エラー (yaml 不在・yq 不在・--only 不正 等)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLUG="${1:-}"
[ -n "$SLUG" ] || { echo "usage: bash scripts/verify-sources.sh <slug> [--only S01,S03]" >&2; exit 2; }
shift
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only)
      # 値なし（--only 単独・空文字）は設定エラー。shift 2 が失敗して無限ループするのを防ぐ
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "verify-sources: --only requires a comma-separated id list (e.g. --only S01,S03)" >&2; exit 2
      fi
      ONLY="$2"; shift 2 ;;
    --only=*) ONLY="${1#--only=}"; shift ;;
    *) echo "verify-sources: unknown argument: $1" >&2; exit 2 ;;
  esac
done

YAML="${SOURCES_FILE:-$REPO_ROOT/sources/$SLUG.yaml}"
ARTICLE="${ARTICLE_FILE:-$REPO_ROOT/articles/$SLUG.md}"

[ -f "$YAML" ] || { echo "verify-sources: sources file not found: $YAML" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "verify-sources: yq not installed (brew install python-yq)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "verify-sources: jq not installed" >&2; exit 2; }

export HOME
export REPO_ROOT
export CORP_DIR="${CORP_DIR:-$HOME/corp}"
export AGENT_BASE_DIR="${AGENT_BASE_DIR:-$HOME/agent-base}"
export CONVERT_SERVICE_DIR="${CONVERT_SERVICE_DIR:-$HOME/convert-service}"
if [ -z "${GH_OWNER:-}" ]; then
  GH_OWNER="$(gh api user -q .login 2>/dev/null || true)"
fi
export GH_OWNER

# cwd / path で参照できる環境変数の許可リスト。eval は使わない
ALLOWED_VARS="HOME CORP_DIR AGENT_BASE_DIR CONVERT_SERVICE_DIR REPO_ROOT"
expand_vars() { # $1=yaml の値 → 置換後を stdout。許可外の展開が残れば return 1
  local s="$1" v
  for v in $ALLOWED_VARS; do
    s="${s//\$\{$v\}/${!v}}"
    s="${s//\$$v/${!v}}"
  done
  case "$s" in
    *'$'*|*'`'*)
      echo "verify-sources: unsupported expansion in yaml value: $1 (allowed: $ALLOWED_VARS)" >&2
      return 1 ;;
  esac
  printf '%s' "$s"
}

field() { # $1=index $2=key
  yq -r ".sources[$1].$2 // \"\"" "$YAML"
}

n="$(yq -r '.sources | length' "$YAML")"
[ "$n" -gt 0 ] 2>/dev/null || { echo "verify-sources: no sources in $YAML" >&2; exit 2; }
ids_yaml="$(yq -r '.sources[].id' "$YAML" | sort -u)"

# --only の id が yaml に実在するか（未知 id を PASS 0 で成功扱いしない）
if [ -n "$ONLY" ]; then
  unknown_only=""
  selected=0
  IFS=',' read -ra only_ids <<< "$ONLY"
  for oid in "${only_ids[@]}"; do
    [ -n "$oid" ] || continue
    if grep -qx -- "$oid" <<< "$ids_yaml"; then selected=$((selected + 1)); else unknown_only="$unknown_only,$oid"; fi
  done
  [ -z "$unknown_only" ] || { echo "verify-sources: --only に yaml に無い id: ${unknown_only#,}" >&2; exit 2; }
  [ "$selected" -gt 0 ] || { echo "verify-sources: --only で 1 件も選択されていません" >&2; exit 2; }
fi

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
      if ! cwd_expanded="$(expand_vars "${cwd:-$REPO_ROOT}")"; then
        actual="(bad cwd)"; verdict="FAIL"
      elif actual="$(cd "$cwd_expanded" 2>/dev/null && bash -c "$cmd" 2>/dev/null)"; then
        actual="$(printf '%s' "$actual" | tr -d '\r' | sed -e 's/[[:space:]]*$//')"
        if [ "$actual" = "$expect" ]; then verdict="PASS"; else verdict="FAIL"; fi
      else
        actual="(command failed)"; verdict="FAIL"
      fi
      ;;
    file)
      path="$(field "$i" path)"
      expect="exists"
      if ! path_expanded="$(expand_vars "$path")"; then
        actual="(bad path)"; verdict="FAIL"
      elif [ -e "$path_expanded" ]; then actual="exists"; verdict="PASS"; else actual="missing"; verdict="FAIL"; fi
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

# 記事との突合（不整合は FAIL。--only 指定時と記事が無い場合は省略）
xfail=0
if [ -f "$ARTICLE" ] && [ -z "$ONLY" ]; then
  # jq の // は false も既定値に倒すので、== false で明示比較する
  if [ "$(yq -r 'if .citations_in_article == false then "false" else "true" end' "$YAML")" = "false" ]; then
    echo "INFO: 本文の出典行は非掲載（citations_in_article: false）: $(yq -r '.citations_note // "理由未記入"' "$YAML")"
  else
    ids_article="$(grep '^出典:' "$ARTICLE" | grep -oE 'S[0-9]{2}' | sort -u)"
    missing_in_article="$(comm -23 <(echo "$ids_yaml") <(echo "$ids_article") | paste -sd, -)"
    unknown_in_article="$(comm -13 <(echo "$ids_yaml") <(echo "$ids_article") | paste -sd, -)"
    no_id_lines="$(grep -c '^出典:' "$ARTICLE" | tr -d ' ')"
    with_id_lines="$(grep -cE '^出典:.*S[0-9]{2}' "$ARTICLE" | tr -d ' ')"
    if [ -n "$missing_in_article" ]; then
      echo "FAIL: yaml にあるが記事の出典行に無い id: $missing_in_article" >&2; xfail=1
    fi
    if [ -n "$unknown_in_article" ]; then
      echo "FAIL: 記事にあるが yaml に無い id: $unknown_in_article" >&2; xfail=1
    fi
    if [ "$no_id_lines" != "$with_id_lines" ]; then
      echo "FAIL: id の無い出典行: $((no_id_lines - with_id_lines)) 行" >&2; xfail=1
    fi
  fi
fi

[ "$fail" -eq 0 ] && [ "$xfail" -eq 0 ]
