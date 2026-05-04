---
title: "OpenClaw自動化サーバー構築記 #4 NVMe ブート移行 — piclone が壊れていた話"
emoji: "💾"
type: "tech"
topics: ["raspberrypi", "nvme", "linux", "rsync", "bootloader"]
published: false  # 公開前に true に
---

## TL;DR

1. RPi5 で SD → NVMe 移行は trixie + Lite 環境では公式 **piclone が事実上使えない**(GUI-only、xvfb-run でも GUI イベントループで詰む)
2. **rsync 法** が現実解。Tailscale/locale/SSH 鍵を保ったままクローン可能
3. PARTUUID 書換 + EEPROM `BOOT_ORDER=0xf416` (NVMe → SD → USB → restart) で **NVMe 優先 + SD 自動フォールバック**
4. **`vcgencmd bootloader_config` は起動時キャッシュ** — 直後 `0xf461` / reboot 後 `0xf416` の二段階観察が必要
5. SD は抜かずに rollback 経路として温存

![NVMe ブート成功の最終確認 — findmnt / が /dev/nvme0n1p2、/proc/cmdline に root=PARTUUID=88aae6c1-02](/images/openclaw-04/23-nvme-boot-success.png)

## 0. はじめに — 今回のスコープ

[前回 #3](https://zenn.dev/harieshokunin/articles/openclaw-03-remote-desktop) でリモートデスクトップ(TigerVNC vs Pi Connect)の比較をした。今回はその下のレイヤ、**Raspberry Pi 5 (`wells`) を SD ブートから NVMe SSD ブートへ移行する作業**を実機ログ込みで追う。

最終ゴールは OpenClaw を載せる本番サーバ化だが、その前段として:

- 起動を NVMe(高速・耐久性) に切替え
- 設定 (Tailscale/locale/SSH 鍵/タイムゾーン) を保ったままクローン
- 万が一 NVMe が起動しなくても SD で復旧できる二重化

を成立させる。記事の山場は **公式 piclone が trixie Lite + SSH 環境で壊れていたこと、xvfb-run も詰むこと、rsync 法に切り替えて成功すること** の 3 段だ。

## 1. Day 0: OS 初期化 (Lite trixie + Tailscale + locale + tz)

OS は **Raspberry Pi OS 13 (trixie) 64-bit Lite**。GUI なし、ヘッドレス前提。

### 1.1 Tailscale SSH と locale

![Tailscale SSH 経由で wells に接続、locale を ja_JP.UTF-8 に設定](/images/openclaw-04/02-tailscale-ssh-locale.png)

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

`MagicDNSEnabled: true` で resolv.conf が `100.100.100.100` (Tailscale DNS) を向く。これで peer hostname が直接解決できる。

## 2. Day 1 の前提失敗: piclone が壊れていた

### 2.1 piclone CLI 不在

公式チェックリストでは `piclone` (SD Card Copier の CLI 版) を使えという話だが、trixie の `piclone 1.2` は **GUI 専用バイナリ** だった。

![piclone --help が即座に X 待ちで hang する](/images/openclaw-04/06-piclone-hangs-no-cli.png)

```
$ piclone --help
(無応答、X server を待っている)
```

`dpkg -L piclone` を確認すると `.desktop` ファイルのみで、man ページもなく CLI モード自体が存在しない。Lite + SSH ヘッドレス環境では事実上完全に詰む。

### 2.2 xvfb-run でもダメ

「じゃあ Xvfb で仮想 X server を立てて GUI を回そう」と試行:

![timeout 10 xvfb-run -a piclone --help が EXIT: 124 (timeout)](/images/openclaw-04/07-piclone-xvfb-fail.png)

```
$ timeout 10 xvfb-run -a piclone --help
EXIT: 124  # timeout 強制終了
```

Xvfb 上で X server は立つが、piclone は GUI イベントループに入って **click 待ち** になるため、`--help` を読まずに止まる。**この事実関係が記事の山場**。

### 2.3 NVMe の存在確認 (前作業)

![piclone 試行前に NVMe が認識されていることを確認 (lsblk)](/images/openclaw-04/05-piclone-nvme-precheck.png)

NVMe デバイスは `/dev/nvme0n1` で正しく認識済み (256 GB)。問題はクローン手段だけだった。

## 3. Day 1 正攻法: rsync 法による NVMe 移行

公式 GUI が壊れているなら、**rsync で root をブロックコピーする**しかない。

### 3.1 NVMe パーティション作成

![parted で nvme0n1 を MBR + p1 (FAT32 boot) + p2 (ext4 root) で切る](/images/openclaw-04/09-nvme-partitioned.png)

- `nvme0n1p1` = 544M FAT32 (boot)
- `nvme0n1p2` = 237.9G ext4 (root)
- 新 PARTUUID: `88aae6c1-01` / `88aae6c1-02`

### 3.2 既存 SD ブートローダの調査

![/boot/firmware と SD のブートローダ周辺を survey](/images/openclaw-04/08-survey-sd-bootloader.png)

`cmdline.txt` / `fstab` がどの PARTUUID を見ているか確認 (旧 `49315c0f-01/02`)。

### 3.3 tmux インストール (作業継続性のため)

![tmux 3.5a を apt install。長時間 rsync が SSH 切断で死なないように](/images/openclaw-04/10-tmux-install.png)

### 3.4 rsync 本体 (root + boot)

![rsync によるルートクローン進行中](/images/openclaw-04/11-rsync-progress-1.png)

```
sent 7,337,245,291 bytes / total size 7,379,525,156 / speedup 1.01
```

![rsync ルート完了](/images/openclaw-04/12-rsync-root-done.png)

`/boot/firmware` も同様に rsync:

![/boot/firmware の rsync 完了 (sent 89 MB / to-chk=0/416)](/images/openclaw-04/13-rsync-boot-done.png)

### 3.5 マウントポイント整備と PARTUUID 書換

![mount point を作って NVMe にマウント](/images/openclaw-04/14-mkdir-mountpoints.png)

クローン後の NVMe 上 `cmdline.txt` / `fstab` で旧 PARTUUID `49315c0f` を新 `88aae6c1` に置換。`grep -l '49315c0f'` で残存ゼロを確認。

![Stage 3a 完了 — 旧 PARTUUID が NVMe 上から消えたことを grep で確認](/images/openclaw-04/15-stage3a-done-old-partuuid.png)

## 4. EEPROM (BOOT_ORDER) 書換 — 罠 2 連発

### 4.1 EDITOR の罠: `sed -i` は単一コマンド名扱い

最初に試したのはこれ:

```bash
EDITOR='sed -i s/0xf461/0xf416/' rpi-eeprom-config --edit
```

![sh: 1: sed -i s/0xf461/0xf416/: not found / Aborting update because exited with code 32512](/images/openclaw-04/16-eeprom-editor-error.png)

`rpi-eeprom-config --edit` は内部で `sh -c "$EDITOR $FILE"` を実行するため、**`EDITOR` の値全体が単一コマンド名**として解釈される。スペース込みで `not found`。

### 4.2 heredoc の罠: インデントで EOF が認識されない

代替案として helper script を heredoc で書こうとしたが、**コピペ時のインデント保持** で `EOF` が行頭ではなくスペース付きになり、bash が終端を認識せず ^C 連打で抜ける羽目に。

![heredoc <<'EOF' が end token を認識しないまま継続行入力モードのまま](/images/openclaw-04/17-heredoc-indent-issue.png)

### 4.3 `--apply` 経路で解決

最終的な正解:

```bash
rpi-eeprom-config > /tmp/boot.conf
sed -i 's/0xf461/0xf416/' /tmp/boot.conf
sudo rpi-eeprom-config --apply /tmp/boot.conf
```

![rpi-eeprom-config --apply が success を返す](/images/openclaw-04/18-eeprom-apply-success.jpeg)

## 5. 副作用ノート: `vcgencmd bootloader_config` は起動時キャッシュ

ここで **記事の小ボス**。`--apply` 直後に確認すると…

![apply 直後の bootloader_config が依然 0xf461 を返す](/images/openclaw-04/19-eeprom-config-stale.jpeg)

```
$ vcgencmd bootloader_config | grep BOOT_ORDER
BOOT_ORDER=0xf461   # 古い値のまま!
```

![vcgencmd を再実行しても変わらない](/images/openclaw-04/20-vcgencmd-still-old.png)

これは **EEPROM の実値ではなく起動時にキャッシュされた値** を返す仕様。
- EEPROM は実際には書き換わっている
- 起動中の `vcgencmd` は古いキャッシュを見ている
- **reboot 後の `vcgencmd` で初めて新値 `0xf416` が見える**

この事実関係を知らないと「apply が失敗した」と誤判断する。

## 6. NVMe ブート完全成功

### 6.1 reboot 前の最終チェック

![Pi Connect が並行起動中。NVMe rsync 後の signin はまだ。NVMe 側の cmdline.txt / fstab を最終確認](/images/openclaw-04/21-rpi-connect-parallel.png)

![reboot 前のフルチェック (PARTUUID, BOOT_ORDER, NVMe マウント)](/images/openclaw-04/22-pre-reboot-checks.png)

### 6.2 reboot 後

`reboot` を打って復帰し、確認:

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

すべて新 PARTUUID + 新 BOOT_ORDER で起動完了。SD は `/dev/mmcblk0` として残存し、rollback 経路を保持している。

## まとめ

- trixie + Pi5 の SD → NVMe 移行は `piclone` が事実上使えない (GUI-only、xvfb-run でも詰む)
- **rsync 法**で root + /boot/firmware をブロックコピーすれば、設定保持したままクローン可能
- PARTUUID 書換は `cmdline.txt` + `/etc/fstab` の二箇所、grep -l で残存ゼロ検証
- BOOT_ORDER は `--apply` 経路で安全に書換、ただし **reboot するまで `vcgencmd` の表示は古いキャッシュ**
- `BOOT_ORDER=0xf416` (NVMe → SD → USB → restart) で **NVMe 失敗時の自動 SD フォールバック**
- SD は抜かない (rollback + 物理 break-glass)

## 次回予告

- #5: OpenClaw 公式 install.sh の **安全な 4 段実行** (curl で取得 → sha256sum で検証 → less で目視 → bash で実行)
- `useradd --system --no-create-home --shell /usr/sbin/nologin openclaw`
- systemd hardening (`ProtectSystem=strict`, `MemoryDenyWriteExecute=yes`, ...)
- bind=`127.0.0.1`, token=`openssl rand -hex 32`, allowFrom=自分のユーザーIDのみ
- `unattended-upgrades` + 週次 CVE フィード cron

---

## 付録: 採用判断の根拠

- **rsync 法を採用** ← piclone GUI-only / xvfb-run 詰みを実証してから移行。Lite + SSH ヘッドレス環境で動く唯一の現実解、設定 (Tailscale/locale/SSH 鍵) を保ったままクローン可能、rollback が SD 保存で自動的に成立
- **MBR (msdos) 維持** ← SD 既存テーブルが MBR で `cmdline.txt`/`fstab` が PARTUUID `XXXXXXXX-NN` 形式に依存。GPT に変えるとフォーマット差で書換コストが増える
- **`BOOT_ORDER=0xf416`** ← NVMe(6) → SD(1) → USB(4) → restart(f) の優先順
- **SD カードは抜かない** ← NVMe boot の rollback 経路として温存
