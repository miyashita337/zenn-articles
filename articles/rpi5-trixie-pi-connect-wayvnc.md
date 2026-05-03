---
title: "OpenClaw自動化サーバー構築記 #3 リモートデスクトップ(TigerVNC vs Pi Connect)"
emoji: "🖥️"
type: "tech"
topics: ["raspberrypi", "vnc", "remotedesktop", "tailscale", "wayland"]
published: false  # 公開前に true に
---

## TL;DR

1. Raspberry Pi OS 13 (trixie) で **RealVNC / xrdp の解説記事は 8 割腐っている** — Wayland (labwc) 移行で前提が変わったため
2. 公式 **Raspberry Pi Connect** はブラウザだけで届く・個人は完全無料・サブスク化なし(2026-05時点)
3. **裏で動いているのは WayVNC** — `rpi-connect-wayvnc.service` が enabled で port 5900 を listen している
4. **Tailscale + TigerVNC で WayVNC 直結** すれば中継なしの最速接続、ただし自己署名証明書の警告が 2 回出る
5. trixie + Pi5 + labwc 0.9.2 + wayvnc 0.9.1 の組み合わせで **[Issue #70「黒画面」](https://github.com/raspberrypi/trixie-feedback/issues/70)は未再現**(2026-05-03 検証)

![Pi Connect と TigerVNC で同じ hostname デスクトップが映っている比較スクショ](/images/rpi5-trixie-pi-connect-wayvnc/00-hero-comparison.png)

## はじめに

[前回の記事](https://zenn.dev/harieshokunin/articles/rpi5-tailscale-ssh-magicdns) で Raspberry Pi 5 (`hostname`) に Tailscale を入れて、外出先からの SSH を 5 分で実現した。
今回はその次のレイヤとして、**GUI が必要な場面でリモートデスクトップを動かす** ところまで進める。

OpenClaw など定期実行系のタスクを RPi5 に任せる前提だと、本番運用は SSH で十分で、GUI は基本不要だ。それでも

- Chromium で初回ログインが必要なサービスにブラウザから入りたい
- raspi-config の GUI モードを触りたい
- スクショを撮って記事化したい(これが本記事の動機)

といった「**たまに必要だが、常時要らない**」ニーズが必ず出てくる。
そして trixie + Pi5 環境では、**Wayland コンポジタ labwc への移行で従来手順がほぼ全滅** している。本記事では Pi Connect と WayVNC 直結の 2 ルートを実機検証し、選択基準と落とし穴をまとめる。

## なぜ「RealVNC を入れる」古い記事はもう動かないのか

Pi OS 12 (Bookworm) 時代までは、**`raspi-config` で VNC を ON → RealVNC Server がポート 5900 を握る → Mac から VNC Viewer で接続**、で完結していた。
しかし Pi OS 13 (trixie) は **デフォルトのコンポジタが labwc (Wayland)** になり、X11 前提で書かれた RealVNC Server / xrdp / TigerVNC Server が **そのままでは動かない / 非常に手間がかかる** 状態になった。

| ツール | trixie + labwc での状況 | 備考 |
|---|---|---|
| RealVNC Server | ✕ Wayland 非対応(X11 にダウングレードすれば動くが trixie 既定を壊す) | apt パッケージは入るが起動しない |
| xrdp | ✕ Wayland 非対応(同上) | RDP プロトコルは強いが trixie で動かすには Xorg 復活が必要 |
| TigerVNC Server | ✕ Wayland 非対応 | クライアント側 (TigerVNC Viewer) は今も標準 |
| **WayVNC** | ◎ labwc 標準採用、Pi OS に同梱 | wlroots 系 Wayland 専用 VNC server |
| **Raspberry Pi Connect** | ◎ 公式、内部で WayVNC を使用 | ブラウザ経由 WebRTC |

つまり、**現代の選択肢は実質「Pi Connect」と「WayVNC」の 2 つだけ**。
本記事ではこの 2 つを実機で動かして比較する。

:::message
古い記事で「`sudo raspi-config` で VNC を有効化」と書いてあっても、trixie ではメニュー項目が変わっており、X11/Wayland の選択次第で全く違うものが起動する。**コピペでハマりたくなければ、Bookworm 前提の記事は参考程度に留める**のが安全。
:::

## 候補 3 つの比較(机上)

実機検証の結果も含めた最終比較表を先に出す:

| 項目 | Pi Connect (公式 SaaS) | WayVNC + Tailscale 直結 | xrdp |
|---|---|---|---|
| 料金 (個人) | **無料** (台数無制限) | **無料** (Tailscale Free 100台まで) | **無料** |
| 料金 (商用) | $0.50/台/月 (Connect for Organisations) | 同上(Tailscale Personal Pro $5〜) | 無料 |
| Mac 側準備 | **ブラウザのみ** | TigerVNC Viewer (Homebrew) | Microsoft Remote Desktop |
| Wayland (labwc) 対応 | ◎ | ◎ | ✕ |
| 中継 | connect.raspberrypi.com (WebRTC) | なし、Tailnet IP に直接 | なし or VPN 経由 |
| 設定の手間 | 5 分(後述) | Tailscale 前提 + 証明書警告承認 | trixie に不向きで非推奨 |
| レイテンシ | 中継一段ぶん遅延 | 最速 | 最速 |
| 攻撃面 | wayvnc 常時 listen + 公式リレー | wayvnc 常時 listen + Tailnet ACL | xrdp 常時 listen |
| 推奨度 | **★★★ 最初の 1 本** | **★★ 最速・Tailnet 限定で運用** | ★(避ける) |

ここから Pi Connect → WayVNC の順に実機で立ち上げる。

## ルート 1: Raspberry Pi Connect (5 分で繋がる)

### 1. インストール

Pi 側:

```bash
sudo apt update
sudo apt install rpi-connect       # Desktop 版(Screen Sharing + Remote Shell)
# または
sudo apt install rpi-connect-lite  # Lite 構成(Remote Shell のみ)
```

`rpi-connect` (Desktop 版) を入れると依存で **wayvnc + neatvnc** も同時に入る。これが後述の「Pi Connect は内部で WayVNC を使っている」の正体。

### 2. サービス起動

```bash
rpi-connect on
```

期待される出力:

```
✓ Raspberry Pi Connect started
```

これを飛ばすと次の `signin` が `✗ Raspberry Pi Connect is not running` でこける。実際にハマった瞬間がこれ:

![rpi-connect on を忘れて signin が失敗するログ](/images/rpi5-trixie-pi-connect-wayvnc/01-not-running-error.png)

### 3. Pi ID にサインイン

```bash
rpi-connect signin
```

verify URL が出るので、**Mac 側のブラウザ** で開く:

```
Complete sign in by visiting https://connect.raspberrypi.com/verify/XXXX-XXXX
```

### 4. ⚠️ サインイン先で「Organisations」を選ばない

ここが最大の罠。Pi Connect には 2 系統ある:

- **Individual** (個人・無料・台数無制限・サブスク化なし) ← これを使う
- **Connect for Organisations** ($0.50/台/月、4 週間無料トライアル後に課金開始)

後者のページがこれ:

![Connect for Organisations の課金ページ — 個人ユーザーは押してはいけない](/images/rpi5-trixie-pi-connect-wayvnc/02-organisations-trap.png)

Individual プランには **専用の選択ボタンが存在しない**。Pi ID(Raspberry Pi アカウント)を作ってサインインするだけで自動的に Individual 扱いになる。料金プランの比較:

| プラン | 料金 | 対象 | 機能 | 台数上限 |
|---|---|---|---|---|
| **Individual** | **$0** | 個人・趣味・教育 | Screen Sharing + Remote Shell | 無制限 (non-relayed) |
| Connect for Organisations | **$0.50 / 台 / 月** | 商用・組織 | 上記 + マルチユーザー管理 | 無制限 (登録数で課金) |

:::message alert
業務アカウントで使う場合は規約上 Organisations を選ぶべきだが、**個人検証や Zenn 記事執筆のための個人 Pi なら Individual で問題ない**。会社メアドで個人プランに入ると後でグレーになるので、**個人用 Hotmail / Gmail で Pi ID を作る** のが無難。
:::

### 5. 接続

サインイン成功画面:

![Device sign in successful — hostname が個人 Pi ID に紐付いた](/images/rpi5-trixie-pi-connect-wayvnc/03-device-signin-successful.png)

Mac のブラウザで [connect.raspberrypi.com](https://connect.raspberrypi.com) を開くとデバイス一覧に `hostname` が出る。クリック → **Screen Sharing** を選ぶと、ブラウザ内に Pi のデスクトップが描画される:

![Pi Connect Screen Sharing で hostname のデスクトップ全体がブラウザに映っている](/images/rpi5-trixie-pi-connect-wayvnc/04-pi-connect-screen-sharing.png)

ここで本記事の重要な実機データ: **2026-05-03 時点で [trixie-feedback Issue #70「rpi-connect screen sharing が trixie + Pi5 で黒画面になる」](https://github.com/raspberrypi/trixie-feedback/issues/70) は再現しなかった**。Issue 内では active と扱われているが、wayvnc 0.9.1 + neatvnc 0.9.5 + labwc 0.9.2 + rpi-connect 2.11.0 の組み合わせで普通に動いた。**過去の不具合で諦めた人はもう一度試す価値あり**。

### 6. 状態確認

```bash
rpi-connect status
```

出力:

```
Signed in: yes
Subscribed to events: yes
Screen sharing: allowed (0 sessions active)
Remote shell: allowed (0 sessions active)
```

`Screen sharing: allowed` が出れば GUI 接続可、`not allowed (no Wayland session)` の場合は Lite 構成 or labwc が起動していない。

## ルート 2: WayVNC + TigerVNC + Tailscale 直結

Pi Connect が裏で WayVNC を使っているなら、**直接 WayVNC に繋げば中継一段省略できる**。これが第 2 ルート。

### 0. 重要発見: WayVNC は既に動いている

Pi Connect を入れた段階で、既に `rpi-connect-wayvnc.service` が enabled になり、wayvnc が port 5900 で listen している:

```bash
$ systemctl --user list-unit-files | grep -i wayvnc
rpi-connect-wayvnc.service                                           enabled   enabled
wayvnc.service.wants
wayvnc-control.service
wayvnc-generate-keys.service
wayvnc.service

$ ss -tlnp | grep 5900
LISTEN 0      16                               *:5900             *:*
```

つまり **追加の設定なしに、Tailnet 内からは既に 5900 で繋がる状態**。これは記事を書く前は知らなかった大きな発見だった。

:::details 実機検証スクリプトの完全ログ
```
=== WayVNC verification on hostname at 2026-05-03T23:18:43+09:00 ===
OS:           Debian GNU/Linux 13 (trixie)
Kernel:       Linux 6.12.75+rpt-rpi-2712 aarch64
labwc 0.9.2 (+xwayland +nls +rsvg +libsfdo)
wayvnc:  0.9.1
neatvnc: 0.9.5
aml:     0.3.0
rpi-connect-wayvnc.service                                           enabled   enabled
LISTEN 0      16                               *:5900             *:*
Tailscale IP: 100.72.229.19
```
検証スクリプトは [openclaw-rpi5-ops/scripts/verify-wayvnc.sh](https://github.com/miyashita337/openclaw-rpi5-ops) に置いた。
:::

### 1. Mac 側に TigerVNC Viewer を入れる

```bash
brew install --cask tigervnc-viewer
```

### 2. Tailnet IP を確認

```bash
ssh user@hostname 'tailscale ip -4'
# → 100.72.229.19
```

### 3. TigerVNC で接続

TigerVNC を起動して接続先に **Tailnet IP:5900** を入れる:

![TigerVNC の接続ダイアログに 100.72.229.19:5900 を入力](/images/rpi5-trixie-pi-connect-wayvnc/05-tigervnc-connect-dialog.png)

### 4. 証明書警告が 2 回出る(全部 Yes)

WayVNC は VeNCrypt TLS 暗号化を強制する。Pi 内に **自己署名のサーバー証明書** が生成済(`wayvnc-generate-keys.service` が一度だけ走る)で、これに対して TigerVNC が文句を言う:

**1 回目: Unknown certificate issuer**

![Unknown certificate issuer ダイアログ — 自己署名なので未知の発行者扱い](/images/rpi5-trixie-pi-connect-wayvnc/06-cert-unknown-issuer.png)

`subject CN=hostname / issuer CN=hostname / EC/ECDSA 384bits / 有効期限 2036-04-30 まで 10 年` の自己署名証明書。Tailnet 内の自分の Pi に対して接続しているなら **Yes** で問題ない。

**2 回目: Certificate hostname mismatch**

![Certificate hostname mismatch ダイアログ — IP で繋いだので CN=hostname と不一致](/images/rpi5-trixie-pi-connect-wayvnc/07-cert-hostname-mismatch.png)

「100.72.229.19 で繋いだのに証明書の CN が hostname」のミスマッチ。これは MagicDNS の `hostname` で繋げば回避できるが、TigerVNC のホスト名解決が MagicDNS に届かない場合があるので **IP 直叩きの場合は Yes** で進める。

:::message
本来の運用では「ホスト名で繋ぐ」「初回接続後にフィンガープリントを保存」が定石。中間者攻撃を本気で防ぐなら、`pin-sha256` の値を 1 回目に控えておいて、以降の接続で一致を確認する習慣を付けるのが望ましい。
:::

### 5. VNC authentication

ユーザー名 + パスワードで認証。これは **Pi の OS ユーザー (PAM)** に対する認証で、`user` の通常ログインパスワードを入れる:

![VNC authentication ダイアログ — 緑の "This connection is secure" バナー付き](/images/rpi5-trixie-pi-connect-wayvnc/08-vnc-auth.png)

緑の **「This connection is secure」** バナーは VeNCrypt TLS が確立されている証。

### 6. 接続成功

![TigerVNC で hostname のデスクトップが表示された画面 — タイトルバーに WayVNC - TigerVNC](/images/rpi5-trixie-pi-connect-wayvnc/09-tigervnc-connected.png)

タイトルバーが **「WayVNC - TigerVNC」** になっているのに注目。Pi 側の VNC server 名が `WayVNC` であることが Mac 側からも見えている。これで Pi Connect と全く同じデスクトップに、**中継なしで届いた**。

## ハマりどころ

### [Issue #70](https://github.com/raspberrypi/trixie-feedback/issues/70)「黒画面」は 2026-05 時点で再現せず

冒頭に書いた通り、hostname の構成 (rpi-connect 2.11.0 / wayvnc 0.9.1 / neatvnc 0.9.5 / labwc 0.9.2) では再現しなかった。[該当 Issue](https://github.com/raspberrypi/trixie-feedback/issues/70) は active のままだが、最新パッケージで何らかの修正が入った可能性がある。**過去にハマった人は再挑戦推奨**。

### RealVNC Server が同居している

`apt list --installed | grep vnc` を取ると `realvnc-vnc-server` が入っているケースがある。trixie + labwc では起動しないので **実害は出ていない** が、X11 にフォールバックする運用を取ると port 5900 競合が発生する。本気で WayVNC 一本にするなら:

```bash
sudo apt purge realvnc-vnc-server
```

で消しておく方が事故が減る。

### SSH セッション単独では Wayland に届かない

`ssh hostname 'wayvnc ...'` を直叩きしても `WAYLAND_DISPLAY` 未設定で起動できない。Pi Connect が動いているのは、**`rpi-connect-wayvnc.service` が graphical session 配下で起動している** から。自前で wayvnc を上げ直したいなら:

```bash
loginctl enable-linger user   # ログオフ後も user systemd を維持
systemctl --user start wayvnc
```

または上記の `rpi-connect-wayvnc.service` をそのまま使うのが手軽。

### `rpi-connect-wayvnc.service` と自前 `wayvnc.service` の二重起動

両方 enable すると port 5900 を取り合う。記事の検証段階で `wayvnc.service` (Pi Connect 由来でない方) を有効化すると `Address already in use` で片方が落ちる。**Pi Connect を使う限り、自前の wayvnc.service は要らない**。

### 自己署名証明書を毎回承認するのが鬱陶しい

TigerVNC の `~/.vnc/x509_known_hosts` に 1 回承認すれば永続化する。それでも気になるなら、Tailscale 由来のホスト名 `hostname` で繋ぎ、`CN=hostname` の自己署名証明書と一致させれば「hostname mismatch」だけは消える(unknown issuer は残る)。

## セキュリティ考察

| リスク | Pi Connect | WayVNC + Tailscale |
|---|---|---|
| 公開リスク | 中継経由なので Pi のポートを世界に公開しない | Tailnet 内のみ。world に公開しない |
| 認証 | Pi ID (パスワード + MFA 可能) | PAM (Pi の OS パスワード) |
| 暗号化 | WebRTC (DTLS-SRTP) | VeNCrypt TLS |
| 常時 listen | wayvnc が 5900 で常時 listen | 同左 |
| ACL | Pi ID 単位 | Tailscale ACL で制御可 |

両方とも「**wayvnc が 5900 で常時 listen している**」のは同じ。気になるなら on-demand 化(`systemctl --user disable rpi-connect-wayvnc.service` + 必要時 start) を検討するが、Tailnet 内に閉じている前提ならそのままで運用上の害は小さい。

:::message
本番運用方針として SSH (Tailscale SSH) を主軸にしている場合、GUI が必要な瞬間だけ `rpi-connect on` / `off` を切り替えて常時 listen を避けるのも選択肢。OpenClaw のような自動化エージェントを動かすなら、本番は SSH 一本・検証は Pi Connect、というハイブリッドが現実解。
:::

## まとめ

- trixie + Pi5 + labwc 環境では **RealVNC / xrdp の旧記事は腐っている** ので、Pi Connect か WayVNC 直結の 2 択
- Pi Connect は **5 分で繋がる**、個人は完全無料、サブスク化なし(2026-05 時点)。Organisations プランは別 SKU の罠
- 内部実装は **Pi Connect も WayVNC を使っている** ので、Tailscale 経由の WayVNC 直結も同じ画面が映る
- [Issue #70「黒画面」](https://github.com/raspberrypi/trixie-feedback/issues/70)は最新構成で **再現せず** — 諦めた人は再挑戦推奨
- 自己署名証明書の警告 2 回(unknown issuer / hostname mismatch) は Tailnet 内なら Yes で問題なし

本番で常時動かしたいなら SSH 一本、たまに GUI が要るときに Pi Connect か TigerVNC を起動する、というハイブリッド運用が trixie 時代の正解。

## 次回予告

- OpenClaw を入れて、定期実行・ブラウザ操作・通知を RPi5 に任せる(本番は SSH only)
- WayVNC を on-demand 化して常時 listen を消す systemd ユニットの書き方
- Tailscale ACL で「VNC は自分の Mac からだけ」を絞り込む

