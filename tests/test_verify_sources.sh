#!/usr/bin/env bash
# tests/test_verify_sources.sh — scripts/verify-sources.sh の最小回帰テスト
# 実行: bash tests/test_verify_sources.sh   (exit 0 = 全 PASS)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/verify-sources.sh"
TMP="$(mktemp -d)"
trap 'rm -r -- "$TMP"' EXIT
fails=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] got [$3]"; fails=$((fails + 1)); fi
}

touch "$TMP/exists.txt"
cat > "$TMP/fixture.yaml" <<YAML
slug: fixture
sources:
  - id: S01
    claim: echo が 42 を返す
    kind: cmd
    cwd: "\$HOME"
    cmd: "echo 42"
    expect: "42"
  - id: S02
    claim: わざと不一致
    kind: cmd
    cwd: "$TMP"
    cmd: "echo 1"
    expect: "2"
  - id: S03
    claim: 手作業の出典
    kind: manual
    note: レシートで確認
  - id: S04
    claim: ファイル存在
    kind: file
    path: "$TMP/exists.txt"
YAML
cat > "$TMP/article.md" <<MD
本文 1
出典: なにか (S01)
出典: id なしの行
MD

# T1: FAIL を含む → exit 1、集計行
out="$(SOURCES_FILE="$TMP/fixture.yaml" ARTICLE_FILE="$TMP/article.md" bash "$SCRIPT" fixture 2>"$TMP/err")"; rc=$?
check "T1 exit code with FAIL" "1" "$rc"
check "T1 summary" "PASS 2 / FAIL 1 / SKIP 1" "$(echo "$out" | grep '^PASS ')"
check "T1 S02 row is FAIL" "1" "$(echo "$out" | grep -c '^| S02 .* FAIL |$')"
check "T1 WARN yaml ids missing in article" "1" "$(grep -c 'S02,S03,S04' "$TMP/err")"
check "T1 WARN id-less 出典 line" "1" "$(grep -c 'id の無い出典行: 1 行' "$TMP/err")"

# T2: --only で PASS だけ選ぶ → exit 0
SOURCES_FILE="$TMP/fixture.yaml" ARTICLE_FILE="$TMP/article.md" bash "$SCRIPT" fixture --only S01,S04 >/dev/null 2>&1; rc=$?
check "T2 --only exit code" "0" "$rc"

# T3: yaml 不在 → exit 2
SOURCES_FILE="$TMP/nope.yaml" bash "$SCRIPT" fixture >/dev/null 2>&1; rc=$?
check "T3 missing yaml exit code" "2" "$rc"

# T4: 引数なし → exit 2
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
check "T4 no slug exit code" "2" "$rc"

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
