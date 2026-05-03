# zenn-articles

[Zenn](https://zenn.dev/harieshokunin) で公開している技術記事のソース管理リポジトリ。

## ディレクトリ構成

```
.
├── articles/                # Zenn 記事 (slug.md)
├── books/                   # Zenn 本 (今は未使用)
├── images/                  # 記事に貼る画像 (slug 配下)
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
```
