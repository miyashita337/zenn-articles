# zenn-articles

[Zenn](https://zenn.dev/harieshokunin) で公開している技術記事のソース管理リポジトリ。

## ディレクトリ構成

```
.
├── articles/                # Zenn 記事 (slug.md)
├── books/                   # Zenn 本 (今は未使用)
├── images/                  # 記事に貼る画像 (slug 配下)
├── hooks/                   # git hooks (PII 検知: pre-push, lib/detect-pii.sh)
└── package.json             # zenn-cli
```

## 公開フロー

1. `articles/<slug>.md` を編集
2. `images/<slug>/*.png` に画像配置
3. `npx zenn preview` でローカル確認 (http://localhost:8000)
4. frontmatter `published: true` に変更
5. `git push origin main` → Zenn が webhook で 30 秒以内に自動公開

## 関連リポジトリ

- [openclaw-rpi5-ops](https://github.com/miyashita337/openclaw-rpi5-ops) — RaspberryPi5 + OpenClaw 運用本体 (記事のネタ元)

## ローカルセットアップ

```bash
git clone git@github.com:miyashita337/zenn-articles.git
cd zenn-articles
npm install                  # zenn-cli を入れる
npx zenn preview             # http://localhost:8000

# pre-push hook (PII 自動ブロック) を有効化
git config core.hooksPath hooks
cp hooks/zenn-pii-blocklist.yaml.example ~/.config/zenn-pii-blocklist.yaml
$EDITOR ~/.config/zenn-pii-blocklist.yaml   # 実 PII 値を追加 (リポにはコミットされない)
brew install python-yq                       # yq (kislyuk 版) が無ければ
```

## PII 漏洩防止 (pre-push hook)

push 前に articles 配下の md (および .txt/.yaml/.yml/.json) を scan し、blocklist に登録した実ホスト名 / 実 IP / 実メアド / 実ユーザー名 / トークンを含む場合は **push をブロック** する。

| 種別 | 推奨マスク (CLAUDE.md 規約) |
| --- | --- |
| ホスト名 | `hostname` |
| ユーザー名 | `user` |
| メアド | `user@example.com` |
| IP | `198.51.100.x` (RFC 5737) |

```bash
# 通常 push (PII が検出されたら exit 1 で停止)
git push

# 緊急回避 (意図的に通したい場合のみ)
ZENN_PII_OVERRIDE=1 git push
```

blocklist は `~/.config/zenn-pii-blocklist.yaml` (リポ外) に置き、**リポにはコミットしない**。実 PII 値そのものが漏れるため。

画像 OCR と `zenn-mask` コマンドは Phase 2 (別 PR) で対応予定。詳細仕様: [Issue #1](https://github.com/miyashita337/zenn-articles/issues/1)
