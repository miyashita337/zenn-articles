# zenn-articles — Cowork / Claude 利用ガイド

## このリポでClaude(Cowork含む)が必ず守ること

### 1. 公開フロー

- `articles/<slug>.md` の `published: true` への切替 + `git push origin main` で Zenn が自動公開
- `npx zenn preview` で必ずローカル確認してから push する
- 画像は `images/<slug>/<file>.png` に配置 (記事内パスは `/images/<slug>/<file>.png`)

### 2. 個人情報マスキング(本リポは public/private いずれも)

- 実ホスト名・実ユーザー名・Tailnet IP は記事に書かない
- プレースホルダ: ユーザー名 = `user`, ホスト名 = `hostname` (例: `ssh user@hostname`)
- メアドは記事に出さない
- スクショの中に映ったホスト名/メアド類は公開前に視認チェック

### 3. シリーズ命名規則

連載「OpenClaw 自動化サーバー構築記」のタイトル形式:
`OpenClaw自動化サーバー構築記 #N サブタイトル`

既存:
- #1 Raspberry Pi 5 + NVMe SSD 編
- #2 Tailscale 設定 ssh できるまで
- #3 リモートデスクトップ (TigerVNC vs Pi Connect)

### 4. Zenn 連携

- Zenn dashboard → GitHub 連携 → `miyashita337/zenn-articles` (main ブランチ)
- 1 アカウント = 1 連携 repo (公式制約)
- dashboard 直編集よりも repo 主導 (dashboard 編集は次 push で上書き)

### 5. 関連リポ

- 記事 #1〜#3 のネタ元: [openclaw-rpi5-ops](https://github.com/miyashita337/openclaw-rpi5-ops)
- スクリプトや config を引用するときは raw.githubusercontent の URL を直接貼る
