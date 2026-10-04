---
name: "zenn-article"
description: "Issue番号指定→実測収集→ヒアリング（記録保存）→AC確定→下書き（一人称部分もClaudeが書く）→検証→published:false でPRまでのZenn記事コマンド"
version: "1.0"
---

# Zenn 記事作成フロー

引数: $ARGUMENTS（Issue 番号。例: `/zenn-article 17`）

## 位置づけ

- `articles/*.md` を書くときは `/impl` ではなく本コマンドを使う。`/impl` は「会長が書く部分」を空欄で残す構造になりやすく、2026-09-20 に記事 #17 で差し戻された
- 参考にした型: team_salary の `write-article.md`（Phase 1 ヒアリング → AC → 下書き → 検証）。note 固有の部分（テーブル禁止・5 人レビュー・note 投稿）は持ち込まない
- 会長の役割は **ヒアリングに答える → 下書きを直す → 公開 OK を出す** の 3 つだけ。空欄を埋める作業を会長に渡さない

## 全 Phase 共通ルール（BLOCKING）

- **推論で数字を書かない**。数値を含む段落の直後に `出典: …（Sxx）` の 1 行を置き、`sources/<slug>.yaml` の id と対応させる
  - 例外（会長判断のみ）: 出典の大半が非公開 repo 由来で読者が追えないときは本文の出典行を省略できる。その場合 yaml の先頭に `citations_in_article: false` と `citations_note: <理由>` を書き、yaml を PR 添付の検証記録として commit する。`verify-sources.sh` はこの宣言があるときだけ記事⇄yaml の突合を INFO 表示にする（宣言が無ければ不整合は FAIL）。例: 記事 #17（PR #18）
- **`<!-- 会長: … -->` 型の空欄プレースホルダを記事に残さない**。会長の言葉が要る節は Phase 2 で聞き、Phase 4 で Claude が書く。書いた節の先頭に `<!-- hearing:Hn -->` を置く（会長がどこを直せばよいか分かるように）
- AI 関与の開示は**書かない**（既定。H5 で会長が変えたときだけ書く）
- 文体・構成・NG 表現は `docs/style-guide.md` に従う。文体は「です・ます」（H6 で変更可）
- PII は CLAUDE.md の規約どおり（ユーザー名 `user`、ホスト名 `hostname`、メール不記載）。`/Users/…` の絶対パス、17〜20 桁の ID、`_TOKEN` / `WEBHOOK` / `API_KEY` を含む文字列は書かない
- 禁止表現: 「初心者向け」「ジュニアエンジニア向け」など読者を見下ろすラベル（memory: `feedback_no_junior_engineer_framing`）
- frontmatter は `published: false` のまま PR を出す。`true` にするのは会長（Phase 7）
- error loop（同一エラー 3 回）で停止して報告する。黙って別手段に切り替えない

## Phase 0: Issue 取得・排他（BLOCKING）

1. `gh issue view <N> --json title,body,labels` で要件を読み、タイトル案・読者・素材の指定・ガードを整理して表示する
   - テーマが決まっていない（Issue が候補を並べているだけ等）ときは、how-to 型（手順・構築・トラブル解決）の候補を推奨案として先頭に出す（根拠: `docs/style-guide.md` 1 章）
2. `in-progress` ラベルが無ければ付ける。既にあれば他セッション作業中の可能性を警告して会長に確認する
3. 前提確認（無ければ止まる）: `~/.config/zenn-pii-blocklist.yaml`、`yq` / `jq`、`python3 -c "import matplotlib"`、`npx zenn preview --port 8000` を起動（`curl -sf localhost:8000/api/articles` が応答するまで）
4. ブランチ `article/<slug>` を `origin/main` から作る（slug は 12〜50 文字、`a-z0-9-`）

## Phase 1: 実測収集 → `sources/<slug>.yaml`

Issue が指す素材（corp の reports / dispatches / registry、agent-base の rules / hooks、GitHub API、Zenn API 等）を**実行して**数値を集め、`sources/<slug>.yaml` に 1 出典 1 エントリで書く。

```yaml
slug: <slug>
measured_at: "YYYY-MM-DD"
# citations_in_article: false   # 本文に出典行を置かない例外（会長判断）。citations_note に理由を書く
# citations_note: "..."
sources:
  - id: S01
    claim: "記事に書く主張（数値込み）"
    kind: cmd          # cmd | file | manual
    cwd: "$CORP_DIR"   # 環境変数で書く。/Users/… は書かない
    cmd: |
      <再実行可能なコマンド>
    expect: "<trim した stdout>"
```

- コマンドは**日付範囲・commit で閉じる**（`merged:A..B`、`select(.date<="…")`、`git show <sha>:…`）。翌日再実行しても同じ値になること。現在のファイルの状態を読む出典（registry の status 等）は測定日の commit に固定する
- `cwd` / `path` で使える環境変数は `HOME` / `CORP_DIR` / `AGENT_BASE_DIR` / `CONVERT_SERVICE_DIR` / `REPO_ROOT` のみ（`verify-sources.sh` は eval しない。`$(…)` や他の変数は FAIL）。yaml の `cmd` はそのまま実行されるので、他人の branch の yaml を実行する前に `git diff origin/main -- sources/` を読む
- 自動再実行できない出典（レシート・ローカルのレビュー記録）は `kind: manual` + `note`
- 書き終えたら `bash scripts/verify-sources.sh <slug>` を実行し、FAIL 0 を確認してから次へ
- `.gitignore` の `.hearings/` 以外は public になる前提で書く（yaml は commit する）

## Phase 2: ヒアリング（BLOCKING・下書きの前）

Phase 1 の実測から候補を作り、`rules/general/option-presentation.md` に従って **`### 前提` を本文に出してから** AskUserQuestion で聞く。1 回 4 問以内、候補 + 「その他」（自由記述）。会長の記憶と違えば自由記述を優先する。

| ID | 質問 | 必須 | 候補の作り方 |
|---|---|---|---|
| H1 | 読者定義 1 行（誰の・どの反復的な損失を減らすか） | 必須 | Issue の案 + 実測から 2 案 |
| H2 | なぜ書くか / なぜやったか（動機） | 必須 | Issue 背景・事業プランから 3〜4 案 |
| H3 | どこで困ったか（一人称） | 必須 | 実測から 3〜4 案、複数選択 |
| H4 | 何を失敗と見たか・次の一手 | 必須 | 実測から 3〜4 案 + 「失敗ではなく途中」 |
| H5 | AI 関与の開示 | 必須 | 本文 1 文 / 冒頭 message / 書かない（既定: 書かない） |
| H6 | 文体 | 任意 | です・ます（既定）/ だ・である |
| H7 | 公開範囲（repo 名・GitHub ID・金額・社名） | 必須 | 記事に出る固有名詞・金額をチェックリストにして「出してよいもの」を選ぶ |
| H8 | タイトル最終案 | 任意 | 本文確定後に生成（issue-creation Step 1「題名は最後」） |

回答が揃ったら `.hearings/<slug>.md` に保存する（質問・候補・回答・不採用候補・日時。git 管理外）。既に必須が揃った記録があれば Phase 2 は skip してよい。

## Phase 3: AC 確定 [確認]

基本 AC（下記 Phase 5 の表）に記事固有の AC（例: 図の枚数、出典 id の数、H7 で外した語が 0 件）を足して提示し、会長の OK を得る。auto mode（`PDCA_AUTO_MODE=1`）では推奨案を採用して進む。

## Phase 4: 下書き

- Claude が**全節**を書く。一人称節（H2〜H4）は回答の語をそのまま使い、先頭に `<!-- hearing:Hn -->`。回答に無い体験を創作しない
- 数値段落の直後に `出典: …（Sxx）`
- 図: フローは本文内 mermaid、数値グラフは `scripts/figures/<slug>-NN.py`（matplotlib、Agg、`Hiragino Sans`、データはインライン、出力 `images/<slug>/NN-*.png`）。図番号は読み順
- H7 で「出さない」とした固有名詞・金額は本文にも yaml にも書かない
- 末尾に `<!-- 出典の再検証: bash scripts/verify-sources.sh <slug> -->` を 1 行

## Phase 5: 検証（BLOCKING）

| AC | 検証内容 | コマンド | 期待 |
|---|---|---|---|
| 1 | 空欄プレースホルダ 0 | `grep -c "<!-- 会長:" articles/<slug>.md` | 0 |
| 2 | 一人称節（H2〜H4）にヒアリング印 | `for h in H2 H3 H4; do grep -c "<!-- hearing:$h -->" articles/<slug>.md; done` | 各 1 以上（会長が本文を自筆した記事は N/A） |
| 3 | 記事⇄yaml の出典 id 突合 | `bash scripts/verify-sources.sh <slug> 2>&1 \| grep -c "^FAIL:"` | 0（`citations_in_article: false` の記事は INFO 行が出る） |
| 4 | 出典の再実行 | `bash scripts/verify-sources.sh <slug>` | exit 0（コマンド不一致・突合不整合のどちらも exit 1） |
| 5 | PII | `bash hooks/lib/detect-pii.sh articles/<slug>.md sources/<slug>.yaml` | exit 0 |
| 6 | 禁止表現・機密 | `grep -cE "初心者向け\|ジュニアエンジニア向け\|[0-9]{17,20}\|_TOKEN\|WEBHOOK\|/Users/" articles/<slug>.md sources/<slug>.yaml` | 0 |
| 7 | 非公開のまま | `grep -c "^published: false" articles/<slug>.md` | 1 |
| 8 | Zenn パース | `curl -sf localhost:8000/api/articles/<slug> \| jq -e '.article.slug=="<slug>" and .article.published==false'` | exit 0 |
| 9 | 図の再現（記事が参照する全図） | `for f in scripts/figures/<slug>-*.py; do n=${f##*-}; python3 "$f" && ls images/<slug>/${n%.py}-*.png \|\| exit 1; done` | exit 0（生成できない図が 1 つでもあれば exit 1） |
| 9b | style-guide の NG 表現 | `grep -cE "成立させる\|を成立する\|採った\|事実関係が\|記事の山場\|初心者が挑む" articles/<slug>.md` + `grep -c '^title: "# ' articles/<slug>.md`（本文 h1 は code block 内のコメントと区別できないため目視） | 0 / 0 |
| 10 | pre-git-check | `make -C ~/agent-base pre-git-check` | PASS |

FAIL → 修正 → 再実行（3 回まで）。全 PASS 後、`npx zenn preview` を会長に見せる（`open http://localhost:8000/articles/<slug>`）。

## Phase 6: commit / PR [確認]

- 対象ファイルを**個別に** `git add`（`git add .` 禁止）: 記事・`images/<slug>/`・`sources/<slug>.yaml`・`scripts/figures/<slug>-*.py`
- commit message は Conventional Commits、日本語、**backtick / `$(` / 改行を含めない**
- 会長の OK を得てから push（pre-push hook が PII を検査する）
- `gh pr create --base main --title "..." --body-file <file>`。本文: `Refs #N`（Closes にしない。公開は会長作業）、ヒアリング要約（質問 ID と採用候補のみ。生の回答は書かない）、AC 表、`verify-sources.sh` の結果表
- 会長の判断で Issue 本文と違う決定をした場合（例: 金額を伏せた）は PR 本文に明記して逆転可能にする

## Phase 7: 会長レビュー → 公開（Claude は指示待ち）

1. 会長が本文を直す（`<!-- hearing:Hn -->` の節が中心）→ `published: true` → main へ merge
2. Claude は会長の指示で `curl -s 'https://zenn.dev/api/articles?username=<Zenn ユーザー名>&order=latest&count=1' | jq -r '.articles[0].title'` を実行し、タイトル一致を確認 → Issue に結果をコメントして close
3. `.hearings/<slug>.md` はローカルに残す（削除しない）

## 再入

- `articles/<slug>.md` がある: Phase 1 は `verify-sources.sh` の再実行のみ
- `.hearings/<slug>.md` に必須（H1〜H5, H7）が揃っている: Phase 2 は skip
- PR がある: Phase 6 は `git push` と PR 本文更新のみ
