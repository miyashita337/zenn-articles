---
title: "OpenClaw自動化サーバー構築記 #4 NVMe ブート移行 — piclone が壊れていた話"
emoji: "💾"
type: "tech"
topics: ["raspberrypi", "nvme", "linux", "rsync", "bootloader"]
published: false
---

## TL;DR

今回試してわかったことは以下です。

- RPi5 で SD → NVMe 移行は trixie + Lite 環境では **公式 `piclone` が事実上使えませんでした** (GUI-only、xvfb-run でもイベントループ待ちで詰みました)
- 結局 **rsync 法** が現実解でした。Tailscale / locale / SSH 鍵を保ったままクローンできます
- PARTUUID を書き換えて、EEPROM の `BOOT_ORDER=0xf416` (NVMe → SD → USB → restart) にすると、**NVMe 優先 + SD 自動フォールバック** にできます
- **`vcgencmd bootloader_config` は起動時にキャッシュされた値**を返すので、apply 直後は `0xf461`、reboot 後にようやく `0xf416` の二段階で観察する必要がありました
- SD カードは抜かずに、rollback 経路として温存しています

![NVMe ブート成功の最終確認 — findmnt / が /dev/nvme0n1p2、/proc/cmdline に root=PARTUUID=88aae6c1-02](/images/openclaw-04/23-nvme-boot-success.png)

## 0. はじめに — 今回のスコープ

[前回 #3](https://zenn.dev/harieshokunin/articles/openclaw-03-remote-desktop) でリモートデスクトップ (TigerVNC vs Pi Connect) の比較をしました。今回はその下のレイヤとして、**Raspberry Pi 5 (`hostname`) を SD ブートから NVMe SSD ブートへ移行する作業** を実機ログ込みで追っていきます。

最終ゴールは OpenClaw を載せる本番サーバ化ですが、その前段として、

- 起動を NVMe (高速・耐久性) に切替え
- 設定 (Tailscale / locale / SSH 鍵 / タイムゾーン) を保ったままクローン
- 万が一 NVMe が起動しなくても SD で復旧できる二重化

を成立させたい、というのが今回のスコープです。実際にやってみると、**公式 `piclone` が trixie Lite + SSH 環境で壊れていたこと、xvfb-run でも詰むこと、最終的に rsync 法に切り替えて成功すること** の 3 段で展開していきました。

## 1. Day 0: OS 初期化 (Lite trixie + Tailscale + locale + tz)

OS は **Raspberry Pi OS 13 (trixie) 64-bit Lite** を使いました。GUI なし、ヘッドレス前提です。

### 1.1 Tailscale SSH と locale

![Tailscale SSH 経由で hostname に接続、locale を ja_JP.UTF-8 に設定](/images/openclaw-04/02-tailscale-ssh-locale.png)

- `localectl set-locale LANG=ja_JP.UTF-8`
- `/etc/locale.gen` で `ja_JP.UTF-8 UTF-8` を有効化

![locale-gen で日本語ロケールを生成](/images/openclaw-04/01-locale-gen.png)

### 1.2 タイムゾーン確認

![timedatectl で Asia/Tokyo + NTP active を確認](/images/openclaw-04/03-locale-tz-confirmed.png)

- `LANG=ja_JP.UTF-8 / LC_ALL=ja_JP.UTF-8`
- `Time zone: Asia/Tokyo`
- `NTP service: active`

### 1.3 MagicDNS と DNS 経路の確認

![/etc/resolv.conf が tailscale 管理 (100.100.100.100) になっていることを確認](/images/openclaw-04/04-resolv-nvme-magicdns.png)

`MagicDNSEnabled: true` で resolv.conf が `100.100.100.100` (Tailscale DNS) を向いていました。これで peer の hostname が直接解決できます。

## 2. Day 1 の前提失敗: piclone が壊れていた

### 2.1 piclone CLI 不在

公式チェックリストでは `piclone` (SD Card Copier の CLI 版) を使えという話でしたが、trixie の `piclone 1.2` は **GUI 専用バイナリ** でした。

![piclone --help が即座に X 待ちで hang する](/images/openclaw-04/06-piclone-hangs-no-cli.png)

```
$ piclone --help
(無応答、X server を待っている)
```

`dpkg -L piclone` を確認すると `.desktop` ファイルのみで、man ページもなく CLI モード自体が存在しませんでした。Lite + SSH ヘッドレス環境では、事実上完全に詰みました。

### 2.2 xvfb-run でもダメ

「じゃあ Xvfb で仮想 X server を立てて GUI を回せばいいのでは」と思って試してみました。

![timeout 10 xvfb-run -a piclone --help が EXIT: 124 (timeout)](/images/openclaw-04/07-piclone-xvfb-fail.png)

```
$ timeout 10 xvfb-run -a piclone --help
EXIT: 124  # timeout 強制終了
```

Xvfb 上で X server は立つものの、piclone は GUI イベントループに入って **click 待ち** になるため、`--help` を読まずに止まりました。

### 2.3 NVMe の存在確認 (前作業)

![piclone 試行前に NVMe が認識されていることを確認 (lsblk)](/images/openclaw-04/05-piclone-nvme-precheck.png)

NVMe デバイスは `/dev/nvme0n1` で正しく認識済みでした (256 GB)。問題はクローン手段だけでした。

## 3. Day 1 正攻法: rsync 法による NVMe 移行

公式 GUI が壊れているなら、**rsync で root をブロックコピーする** しかありません。

### 3.1 NVMe パーティション作成

![parted で nvme0n1 を MBR + p1 (FAT32 boot) + p2 (ext4 root) で切る](/images/openclaw-04/09-nvme-partitioned.png)

- `nvme0n1p1` = 544M FAT32 (boot)
- `nvme0n1p2` = 237.9G ext4 (root)
- 新しい PARTUUID: `88aae6c1-01` / `88aae6c1-02`

### 3.2 既存 SD ブートローダの調査

![/boot/firmware と SD のブートローダ周辺を survey](/images/openclaw-04/08-survey-sd-bootloader.png)

`cmdline.txt` / `fstab` がどの PARTUUID を見ているかを確認しました (旧 `49315c0f-01/02`)。

### 3.3 tmux インストール (作業継続性のため)

![tmux 3.5a を apt install。長時間 rsync が SSH 切断で死なないように](/images/openclaw-04/10-tmux-install.png)

長時間 rsync が走るので、SSH 切断で死なないように tmux 3.5a を apt で入れておきました。

### 3.4 rsync 本体 (root + boot)

![rsync によるルートクローン進行中](/images/openclaw-04/11-rsync-progress-1.png)

```
sent 7,337,245,291 bytes / total size 7,379,525,156 / speedup 1.01
```

![rsync ルート完了](/images/openclaw-04/12-rsync-root-done.png)

`/boot/firmware` も同様に rsync しました。

![/boot/firmware の rsync 完了 (sent 89 MB / to-chk=0/416)](/images/openclaw-04/13-rsync-boot-done.png)

### 3.5 マウントポイント整備と PARTUUID 書換

![mount point を作って NVMe にマウント](/images/openclaw-04/14-mkdir-mountpoints.png)

クローン後の NVMe 上の `cmdline.txt` / `fstab` で、旧 PARTUUID `49315c0f` を新しい `88aae6c1` に置換しました。`grep -l '49315c0f'` で残存ゼロを確認しています。

![Stage 3a 完了 — 旧 PARTUUID が NVMe 上から消えたことを grep で確認](/images/openclaw-04/15-stage3a-done-old-partuuid.png)

## 4. EEPROM (BOOT_ORDER) 書換 — 罠 2 連発

### 4.1 EDITOR の罠: `sed -i` は単一コマンド名扱い

最初に試したのはこれでした。

```bash
EDITOR='sed -i s/0xf461/0xf416/' rpi-eeprom-config --edit
```

![sh: 1: sed -i s/0xf461/0xf416/: not found / Aborting update because exited with code 32512](/images/openclaw-04/16-eeprom-editor-error.png)

`rpi-eeprom-config --edit` は内部で `sh -c "$EDITOR $FILE"` を実行するため、**`EDITOR` の値全体が単一コマンド名** として解釈されてしまいます。スペース込みで `not found` でした。

`$EDITOR` は元々 `EDITOR=vi` のような **単一バイナリ名の代入** を想定している環境変数で、`rpi-eeprom-config` 側もそのつもりで `sh -c "$EDITOR $FILE"` の形で素直に exec しています。なのでこちらが「`sed -i s/.../.../`」のように引数付きの 1 行スクリプトを突っ込もうとすると、シェルからは `sed -i s/.../.../` という名前のバイナリを探しに行く動きになって `not found` という、ある意味で正しい挙動になっていました。`VISUAL` 系の変数全般も同じ前提で動いているので、引数を渡したいときは小さな wrapper script を `EDITOR=/path/to/wrapper.sh` で渡すか、後述の `--apply` 経路に切り替えるのが穏当です。

### 4.2 heredoc の罠: インデントで EOF が認識されない

代替案として helper script を heredoc で書こうとしましたが、**コピペ時のインデント保持** で `EOF` が行頭ではなくスペース付きになり、bash が終端を認識せず ^C 連打で抜ける羽目になりました。

![heredoc <<'EOF' が end token を認識しないまま継続行入力モードのまま](/images/openclaw-04/17-heredoc-indent-issue.png)

### 4.3 `--apply` 経路で解決

最終的な正解はこれでした。

```bash
rpi-eeprom-config > /tmp/boot.conf
sed -i 's/0xf461/0xf416/' /tmp/boot.conf
sudo rpi-eeprom-config --apply /tmp/boot.conf
```

![rpi-eeprom-config --apply が success を返す](/images/openclaw-04/18-eeprom-apply-success.jpeg)

## 5. 副作用ノート: `vcgencmd bootloader_config` は起動時キャッシュ

ここで **記事の小ボス** に出会いました。`--apply` 直後に確認すると…

![apply 直後の bootloader_config が依然 0xf461 を返す](/images/openclaw-04/19-eeprom-config-stale.jpeg)

```
$ vcgencmd bootloader_config | grep BOOT_ORDER
BOOT_ORDER=0xf461   # 古い値のまま!
```

![vcgencmd を再実行しても変わらない](/images/openclaw-04/20-vcgencmd-still-old.png)

これは **EEPROM の実値ではなく、起動時にキャッシュされた値** を返す仕様でした。

- EEPROM は実際には書き換わっている
- 起動中の `vcgencmd` は古いキャッシュを見ている
- **reboot 後の `vcgencmd` で初めて新しい値 `0xf416` が見える**

これを知らないと「apply が失敗した」と誤判断してしまうところでした。

## 6. NVMe ブート完全成功

### 6.1 reboot 前の最終チェック

![Pi Connect が並行起動中。NVMe rsync 後の signin はまだ。NVMe 側の cmdline.txt / fstab を最終確認](/images/openclaw-04/21-rpi-connect-parallel.png)

![reboot 前のフルチェック (PARTUUID, BOOT_ORDER, NVMe マウント)](/images/openclaw-04/22-pre-reboot-checks.png)

### 6.2 reboot 後

`reboot` を打って復帰してから、確認しました。

```
$ findmnt /
TARGET SOURCE          FSTYPE OPTIONS
/      /dev/nvme0n1p2  ext4   rw,relatime

$ findmnt /boot/firmware
TARGET          SOURCE         FSTYPE OPTIONS
/boot/firmware  /dev/nvme0n1p1 vfat   rw,relatime,...

$ cat /proc/cmdline | tr ' ' '\n' | grep -i part
root=PARTUUID=88aae6c1-02

$ vcgencmd bootloader_config | grep BOOT_ORDER
BOOT_ORDER=0xf416
```

すべて新しい PARTUUID + 新しい BOOT_ORDER で起動完了しました。SD は `/dev/mmcblk0` として残ったままで、rollback 経路を保持しています。

## まとめ

今回やったことを振り返ると以下です。

- trixie + Pi5 の SD → NVMe 移行は、`piclone` が事実上使えませんでした (GUI-only、xvfb-run でも詰みました)
- **rsync 法** で root + /boot/firmware をブロックコピーすれば、設定を保持したままクローンできました
- PARTUUID 書換は `cmdline.txt` + `/etc/fstab` の二箇所で、`grep -l` で残存ゼロを検証しました
- BOOT_ORDER は `--apply` 経路で安全に書き換えできましたが、**reboot するまで `vcgencmd` の表示は古いキャッシュ** だった点に注意です
- `BOOT_ORDER=0xf416` (NVMe → SD → USB → restart) で **NVMe 失敗時の自動 SD フォールバック** が成立します
- SD は抜かずに残しています (rollback + 物理 break-glass の両方の意味で)

## 次回予告

次回は以下を扱う予定です。

- #5: OpenClaw 公式 install.sh の **安全な 4 段実行** (curl で取得 → sha256sum で検証 → less で目視 → bash で実行)
- `useradd --system --no-create-home --shell /usr/sbin/nologin openclaw`
- systemd hardening (`ProtectSystem=strict`, `MemoryDenyWriteExecute=yes`, ...)
- bind=`127.0.0.1`, token=`openssl rand -hex 32`, allowFrom=自分のユーザーIDのみ
- `unattended-upgrades` + 週次 CVE フィード cron

---

## 付録: 採用判断の根拠

- **rsync 法を採用** ← piclone GUI-only / xvfb-run 詰みを実機で確認してから移行しました。Lite + SSH ヘッドレス環境で動く唯一の現実解でしたし、設定 (Tailscale / locale / SSH 鍵) を保ったままクローンできます。rollback も SD を残しておくだけで自動的に成立します
- **MBR (msdos) 維持** ← SD 既存テーブルが MBR で、`cmdline.txt` / `fstab` が PARTUUID `XXXXXXXX-NN` 形式に依存していました。GPT に変えるとフォーマット差で書換コストが増えるので避けました
- **`BOOT_ORDER=0xf416`** ← NVMe(6) → SD(1) → USB(4) → restart(f) の優先順です
- **SD カードは抜かない** ← NVMe boot の rollback 経路として温存しています

## 付録: rsync コマンド (root / boot 用)

クローン側で実際に使ったオプションです。後追いで作業される方の取っ掛かりになれば。

root のコピー (SD の `/` → NVMe の `/mnt/nvme-root`):

```bash
sudo rsync -aHAXx --numeric-ids --info=progress2 \
  --exclude={'/dev/*','/proc/*','/sys/*','/tmp/*','/run/*','/mnt/*','/media/*','/lost+found','/boot/firmware/*'} \
  / /mnt/nvme-root/
```

`/boot/firmware` は別ファイルシステム (FAT32) なので、別途 root だけ rsync しました。

```bash
sudo rsync -aHAXx --numeric-ids --info=progress2 \
  /boot/firmware/ /mnt/nvme-boot/
```

オプションの意図は次の通りです。

- `-a` ← `-rlptgoD` のセット。パーミッション / オーナー / 時刻 / シンボリックリンクをまとめて維持してくれます
- `-H` ← ハードリンクを保ったままコピーします (`/usr/bin` 配下の busybox 系で効きます)
- `-A` ← POSIX ACL を維持します (Tailscale や systemd 周辺で稀に効きます)
- `-X` ← 拡張属性 (xattr) を維持します。SELinux/capabilities を使っていなくても、`getcap` 系の権限を落とさないために入れました
- `-x` ← ファイルシステム境界をまたがない指定です。`/proc` `/sys` 等を `--exclude` で削っているので二重防御ですが、入れておくと安心でした
- `--numeric-ids` ← UID/GID を数値のままコピーします。クローン先のユーザー DB が同期される前提なら名前解決にしてもよいですが、こちらの方が事故が少なかったです

`-aHAXx` の組み合わせは ArchWiki / `man rsync` でも「フルバックアップ用途の鉄板セット」として紹介されています。FAT32 へのコピーは ACL/xattr が無視されるだけで害はないので、root と boot で同じオプションのままにしておきました。
