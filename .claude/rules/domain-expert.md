# ドメインエキスパート: Zenn 技術記事（貼り絵職人アカウント）

## プロジェクト概要

`zenn-articles` は Zenn（GitHub 連携、main ブランチ）に公開する記事の正本。`articles/<slug>.md` の frontmatter `published: true` を main に push すると公開される。public リポなので下書きも GitHub 上では見える。

## ドメイン知識

- 連載「OpenClaw 自動化サーバー構築記 #N サブタイトル」（#1〜#7 公開済み）と、2026-09 からの副業トラック（一人 AI 会社の設計図、有料本への導線）の 2 系統
- 読者が反応するのは実践 how-to と実測データ。ニュース評論は伸びない
- 記事の一人称部分（動機・困った点・失敗）は会長の言葉。`/zenn-article` の Phase 2 ヒアリングで聞いてから Claude が下書きする
- 数値は全て出典付き（`sources/<slug>.yaml` + `scripts/verify-sources.sh`）。換算値と実請求を混同しない

## 技術スタック

- zenn-cli（`npx zenn preview`、port 8000）、Markdown + mermaid、画像は `images/<slug>/`
- PII 検査: `hooks/pre-push` → `hooks/lib/detect-pii.sh`（blocklist `~/.config/zenn-pii-blocklist.yaml`）
- 図: matplotlib（`scripts/figures/`、Hiragino Sans）

## レビュー時の重点チェック項目

- 実ホスト名・実ユーザー名・メール・Tailnet IP・`/Users/` パスが本文とスクショに無いか
- 「初心者向け」「ジュニアエンジニア向け」など読者を見下ろす表現が無いか
- 数値段落に `出典:` があり、`verify-sources.sh` が FAIL 0 か
- `<!-- 会長: -->` 型の空欄を会長に丸投げしていないか
- `published: false` のまま PR を出しているか（公開は会長の操作）
