---
title: "OpenClaw自動化サーバー構築記 #5 OpenClaw導入 — systemd hardening でスコア 9.0→1.4"
emoji: "🛡"
type: "tech"
topics: ["openclaw", "raspberrypi", "systemd", "hardening", "linux"]
published: true
---

## TL;DR（5行でまとめると）

- 公式の install スクリプト (`curl ... | bash`) は **いきなり実行せず**、`OPENCLAW_DRY_RUN=1` を付けて「中で何をするか」を先に表示させてから流しました（setuid・sudoers 改変・隠れた `eval` がゼロ件であることを確認済み）
- 普段使いの個人ユーザーで動かさず、**専用ユーザー `openclaw` を作って `/opt/openclaw` で動かす** 構成に組み替えました（乗っ取られても作業ファイルに被害が及ばないようにするため）
- systemd unit に **「daemon に許す動作」を 4 段階で絞り込む設定** を入れて、危険度スコア (`systemd-analyze security`) を **9.0 UNSAFE 😨 → 1.4 OK 🙂** まで下げました（所要 30 分）
- ハマったのは 2 件: `/tmp` を読取専用にしすぎて起動失敗 → `PrivateTmp=yes` で解消／sudoers にコピペすると改行が混入 → SSH 経由で `sudo install` 配置で回避
- 仕上げは **AI アシスタント (Claude Code) に期限付きの NOPASSWD sudo を渡して SSH 自動操作** させ、ほぼ手放しで完走させました

![iTerm2 で Claude Code (左) と hostname (右) を並走させた hardening 作業の様子](/images/openclaw-05/00-cover.png)

## はじめに

[前回 #4](https://zenn.dev/harieshokunin/articles/openclaw-04-nvme-boot-migration) で NVMe ブート移行を済ませた `hostname` (Raspberry Pi 5) に、本連載の主役である **OpenClaw** を本番運用構成で入れていきます。

OpenClaw は AI アシスタントと自動化を繋ぐ daemon で、agent 機能 / channels / browser control / cron 等を一台に同居させられます。個人のホームサーバーで動かしたいので、以下を満たす構成を目指しました。

- **username (個人ユーザー) の権限を持たない** 専用 system user で動作 (もし乗っ取られても被害範囲を限定するため)
- **token 認証 + loopback bind** のみ (外部公開は将来 Cloudflare Tunnel 経由にする想定)
- **systemd hardening** で読み書き可能パス・capability・syscall を最小限に絞る

本記事は install から hardening 完了までの一気通貫です。公式 install.sh をそのまま流す (path A) のではなく、**監査 → C-1 方式で /opt 昇格 → 自前 unit + 階層化 hardening** という回り道を選びました。結果として所要時間は半日 (公式想定の 1 時間ではなく) になりましたが、**`systemd-analyze security` スコアを 9.0 から 1.4 まで落とせました**。

:::message
本記事は **個人開発の自宅サーバーでの作業ログ** として書いています。法人での運用は別途リスク評価が必要です。
:::

## 全体像

```
┌─ username (操作ユーザー)
│   └─ ~/openclaw  (git install 完走、参照用に残置)
│
└─ openclaw  (UID 999, system user, no shell, no home)
    ├─ /opt/openclaw           (root:openclaw 0750, install 成果物の rsync 先)
    ├─ /var/lib/openclaw       (openclaw:openclaw 0750, HOME 偽装)
    ├─ /var/log/openclaw       (openclaw:openclaw 0750)
    ├─ /etc/openclaw/openclaw.env  (root:openclaw 0640, OPENCLAW_GATEWAY_TOKEN)
    └─ /usr/local/bin/openclaw (root:root 0755, 3 行 wrapper)

systemd unit:
  /etc/systemd/system/openclaw-gateway.service
  - User=openclaw / Group=openclaw
  - 127.0.0.1:18789 のみで listen (loopback bind, token auth)
  - Tier A/B/B-2/C hardening 全部入り
```

## Step 0: install.sh のセキュリティ監査

公式は `curl https://openclaw.ai/install.sh | bash` を案内していますが、流す前にざっと監査しました。

```bash
curl -sSL https://openclaw.ai/install.sh -o /tmp/openclaw-install.sh
sha256sum /tmp/openclaw-install.sh
# → 57f025ba0272e2da3238984360e37fad5230bc7cea81854d154a362ea989d49d (93204 bytes)
```

- **sha256 / 公式署名は提供されていない** → 弱点ですが、source code が公開されているので grep 監査で代用しました
- `setuid` / `sudoers` 編集 / firewall 操作 / `rm -rf /` / 難読化 (`base64 -d`, `eval $(...)` 等) → ゼロ件でした
- 内蔵の `curl|bash` 文字列が 7 件ヒット → すべて `print_usage()` の heredoc 内 + `print_homebrew_admin_fix()` の echo 内でした (= 文字列表示なので実行ではなし)
- `eval` は L91 の `eval "$("$brew_bin" shellenv)"` 1 件のみ (Homebrew 標準パターン)

監査結果としては、**悪意の混入は見えなかったものの、配布側に sha256 / 署名提供がないのは弱い** という印象でした。仕方ないので、git install path (`--install-method git`) を選んで commit hash で pin する戦略にしました。

```bash
OPENCLAW_DRY_RUN=1 bash /tmp/openclaw-install.sh \
  --dry-run --no-onboard --no-prompt --install-method git
# → "Dry run complete (no changes made)" を確認後、本番実行
```

![dry-run で依存関係チェックが完了し、`Dry run complete (no changes made)` が出るまで進んだ画面](/images/openclaw-05/02-install-dryrun.png)

## Step 1: install path 選択

3 案を比較しました。

| 方式 | 概要 | メリット | デメリット |
|---|---|---|---|
| **A** | 公式 npm install | 最速 (5 分) | バイナリ固定、コードを `git diff` で読めない |
| **B** | 公式 git install (username の HOME に直接) | コードは読める | 個人ユーザー直起動のため compromise 時の被害大 |
| **C-1 (採用)** | git install → `/opt/openclaw` に rsync 昇格 → `openclaw` user で起動 | 透明性 + blast radius 限定 + update 経路もスクリプト化容易 | 公式想定外なので自前 unit が必要 |

採用したのは **C-1** です。決め手は 2 つで、`git diff v1.x v1.y` でアップデートの中身がそのまま読めるのと、**`openclaw` という system user で動かしておけば、もし乗っ取られても個人ユーザーの SSH 鍵 / Tailscale 認証 / git 履歴は巻き込まれない** からでした。

## Step 2: install + CLI 動作確認

```bash
bash /tmp/openclaw-install.sh --install-method git --no-onboard --no-prompt
# → Node.js v22.22.2 (NodeSource APT) + git + pnpm corepack + OpenClaw 2026.5.4 (b8f6e16)
# → ~/openclaw (2.9 GB) + ~/.local/bin/openclaw (98 bytes wrapper)

openclaw --version
# → OpenClaw 2026.5.4 (b8f6e16)
```

サブコマンドはたくさんあります: `acp / agent / agents / approvals / backup / capability / channels / chat / clawbot / commitments / completion / config / configure / crestodian / cron / daemon / dashboard / devices / directory / dns / docs / doctor / exec-policy / gateway / health / help / hooks / infer / logs / mcp / memory / ...`。

`openclaw daemon install` は launchd / systemd / schtasks 統合で `install/start/stop/restart/status/uninstall` を持っていますが、**`--user` フラグがありません**。current user 用にしか設定されない設計だったので、**自前 unit を書くしかなさそう** でした。

## Step 3: /opt 昇格 + system user 作成

```bash
# system user 作成 (UID 999, no shell, no home)
sudo useradd --system --no-create-home \
  --home-dir /var/lib/openclaw --shell /usr/sbin/nologin openclaw

# ディレクトリ配置
sudo install -d -m 0750 -o root     -g openclaw /opt/openclaw
sudo install -d -m 0750 -o openclaw -g openclaw /var/lib/openclaw
sudo install -d -m 0750 -o openclaw -g openclaw /var/log/openclaw
sudo install -d -m 0750 -o root     -g openclaw /etc/openclaw

# rsync で /opt 昇格 (秘密ファイルは除外)
sudo rsync -aH --delete \
  --exclude '.env' --exclude '.env.*' --exclude '*.local' \
  /home/username/openclaw/ /opt/openclaw/
sudo chown -R root:openclaw /opt/openclaw
sudo chmod -R u=rwX,g=rX,o= /opt/openclaw

# wrapper
sudo install -m 0755 /dev/stdin /usr/local/bin/openclaw <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
exec node "/opt/openclaw/dist/entry.js" "$@"
WRAPPER

# token + env ファイル
TOKEN=$(openssl rand -hex 32)
echo "OPENCLAW_GATEWAY_TOKEN=${TOKEN}" \
  | sudo install -m 0640 -o root -g openclaw /dev/stdin /etc/openclaw/openclaw.env
# token を 1Password 等に保存
```

:::message alert
**ここで 1 回ハマりました**。当初は heredoc (`sudo tee /etc/openclaw/openclaw.env <<EOF ... EOF`) で書こうとしましたが、SSH 越しに `iTerm2 → hostname` の paste を経由すると、インデントが混入して終端 `EOF` が認識されず、bash が `>` 継続プロンプトのまま永久に hang してしまいました。**解決策は heredoc を使わず `printf '%s\n' 'line1' 'line2' | sudo tee /path > /dev/null` の単一行パターンに統一** することでした。
:::

## Step 4: 自前 systemd unit (最小ガード)

最初は最小ガードで起動させて、動作確認をしました。

```ini:openclaw-gateway.service
[Unit]
Description=OpenClaw Gateway
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/openclaw gateway --bind loopback --port 18789 --auth token --allow-unconfigured
Restart=on-failure
RestartSec=10s

User=openclaw
Group=openclaw
EnvironmentFile=/etc/openclaw/openclaw.env
Environment=HOME=/var/lib/openclaw
Environment=NODE_ENV=production
WorkingDirectory=/var/lib/openclaw

NoNewPrivileges=yes

StandardOutput=journal
StandardError=journal
SyslogIdentifier=openclaw-gateway

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now openclaw-gateway
sudo systemctl status openclaw-gateway
# → active (running), Main PID = openclaw user
ss -tlnp | grep 18789
# → 127.0.0.1:18789 + [::1]:18789 のみ (loopback only)
```

![daemon が `active (running)` で起動して、`ss -tlnp` で 127.0.0.1:18789 と [::1]:18789 の loopback listen を確認できた画面](/images/openclaw-05/03-daemon-active.png)

journal で `[gateway] ready` と 7 plugins (acpx / browser / device-pair / file-transfer / memory-core / phone-control / talk-voice) の起動を確認できました。ここで **Phase 3 完了** です。

## Step 5: systemd hardening 階層化バッチ投入

公式チュートリアル (および当初の自分の計画) は「**1 項目ずつ追加 → 1 時間 journal 観察 → 代表機能テスト → 次へ**」という正攻法でした。10 項目 × 1 時間 = 10 時間以上かかる計算です。

これを **リスク階層化バッチ** に再設計しました。

| Tier | 項目 | 戦略 | 時間 |
|---|---|---|---|
| **A (OS 隔離、安全)** | `ProtectSystem=strict` / `ProtectHome=yes` / `Protect{Kernel,Control}*` / `LockPersonality` / `Restrict{SUIDSGID,Namespaces,Realtime}` / `RemoveIPC` / `SystemCallArchitectures=native` / `ReadWritePaths=...` / `PrivateTmp=yes` | **一括投入 + smoke test 5-10 分** | 20 分 |
| **B (capability + clock/proc/host)** | `CapabilityBoundingSet=` (空) / `AmbientCapabilities=` / `RestrictAddressFamilies=...` / `ProtectClock` / `ProtectHostname` / `ProtectProc=invisible` / `ProcSubset=pid` / `PrivateDevices` / `KeyringMode=private` / `UMask=0077` | **一括投入** (壊れても権限エラーで明確に判明する想定) | 10 分 |
| **B-2 (SystemCallFilter deny-list)** | `SystemCallFilter=~@swap @reboot @raw-io @privileged @mount @module @debug @cpu-emulation @clock @obsolete` / `SystemCallErrorNumber=EPERM` | **deny-list 形式** (Node.js JIT が必要とする `mprotect` 等は許容したまま) | 5 分 |
| **C (リソース制限)** | `MemoryMax=2G` / `TasksMax=512` / `LimitNOFILE=65536` / `MemoryAccounting=yes` / `TasksAccounting=yes` | **一括** | 5 分 |
| **保留** | `MemoryDenyWriteExecute=yes` (Node.js V8 JIT は `PROT_WRITE \| PROT_EXEC` を必要とするため破壊リスク高) / `IPAddressDeny=any` (agent の外部 API 呼び出しを block する) | 別途検証 | — |

### Tier A 投入直後にハマったやつ

`ProtectSystem=strict` を入れた瞬間、daemon が crash loop に陥りました。journal の出力はこんな感じです。

```
[openclaw] Failed to start CLI: Error: Unsafe fallback OpenClaw temp dir: /tmp/openclaw-999
    at ensureTrustedFallbackDir (file:///opt/openclaw/dist/tmp-openclaw-dir-*.js:74:10)
    at resolvePreferredOpenClawTmpDir (...)
    at resolveDefaultLogDir (...)
```

**原因**は、`ProtectSystem=strict` が **/usr /boot /etc に加えて /var (および systemd によっては /tmp も) を ro 化** することでした。OpenClaw のログ書き出し先が `/tmp/openclaw-<UID>` で、ここが ro になると "Unsafe fallback" 例外が飛ぶ仕様だったようです。

**解決策**は `PrivateTmp=yes` の追加でした。これで daemon に **専用の隔離された /tmp namespace** が割り当てられて、書き込み可能になります (副産物として、ログ path が `/tmp/openclaw-999/` → `/tmp/openclaw/` に変化して、UID prefix が不要になりました)。

### Tier B/B-2 投入

Tier A が安定したのを確認してから、Tier B (capability + clock/proc/host) と Tier B-2 (SystemCallFilter) を続けて投入しました。**両 Tier とも一発で PASS** で、smoke test (`[gateway] ready` + 7 plugins 起動 + listen 確認) でも異常なしでした。

最終的な unit ファイルの抜粋はこちらです。

```ini:openclaw-gateway.service
# === hardening: Tier A (OS isolation) ===
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictSUIDSGID=yes
RemoveIPC=yes
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallArchitectures=native
ReadWritePaths=/var/lib/openclaw /var/log/openclaw
PrivateTmp=yes

# === hardening: Tier B (capabilities, namespaces, clock/proc) ===
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProcSubset=pid
PrivateDevices=yes
KeyringMode=private
UMask=0077

# === hardening: Tier B-2 (system call deny list, Node.js JIT compatible) ===
SystemCallFilter=~@swap @reboot @raw-io @privileged @mount @module @debug @cpu-emulation @clock @obsolete
SystemCallErrorNumber=EPERM

# === hardening: Tier C (resource limits) ===
MemoryMax=2G
TasksMax=512
LimitNOFILE=65536
MemoryAccounting=yes
TasksAccounting=yes
```

## 結果: スコア 9.0 → 1.4

```bash
sudo systemd-analyze security openclaw-gateway | tail -1
```

| 段階 | スコア | 削減 |
|---|---|---|
| Phase 3 直後 (最小ガード) | **9.0 UNSAFE 😨** | — |
| Tier A + C + PrivateTmp 投入後 | 6.1 MEDIUM 😐 | -2.9 |
| Tier B 追加 | 2.9 OK 🙂 | -3.2 |
| Tier B-2 (SystemCallFilter) 追加 | **1.4 OK 🙂** | -1.5 |

![systemd-analyze security openclaw-gateway.service の最終出力。`Overall exposure level for openclaw-gateway.service: 1.4 OK 🙂` でハードニング完了](/images/openclaw-05/04-systemd-analyze-final-1.4.png)

残り 1.4 のうち、約 0.7 は `RestrictAddressFamilies=~AF_UNIX/INET/NETLINK` (= daemon が必要としているソケット種別なので削除できないところ) です。約 0.4 は `SystemCallFilter` の `@resources` (Node.js が `setrlimit` で使うかもしれないので残置)、残りは `RootDirectory=` 系 (chroot 風の隔離、コスト対比で見送り) でした。

## おまけ: AI agent (Claude Code) で hardening を自律化した話

本セッションは **Claude Code (Opus 4.7)** に hardening 作業を任せました。SSH と sudo が両方絡む作業なので、以下の経路で自律化しました。

1. **Mac → hostname SSH 許可**: プロジェクトの `.claude/settings.json` の `allow` に `Bash(ssh username@hostname:*)` を追加 (deny の `Bash(ssh:*)` は project scope で削除)
2. **hostname 側 NOPASSWD**: `/etc/sudoers.d/openclaw-claude-ops` を作って systemd 操作のみ NOPASSWD にしました。撤去は `sudo rm` 1 回でゼロに戻ります

```bash
# 付与 (作業中のみ)
cat > /tmp/sudoers <<'EOF'
username ALL=(root) NOPASSWD: /bin/systemctl daemon-reload
username ALL=(root) NOPASSWD: /bin/systemctl restart openclaw-gateway
... (operations 限定で 15 行)
EOF
sudo install -m 0440 -o root -g root /tmp/sudoers /etc/sudoers.d/openclaw-claude-ops

# 撤去 (作業完了後)
sudo rm /etc/sudoers.d/openclaw-claude-ops
```

これで Claude が `ssh username@hostname "sudo -n systemctl restart openclaw-gateway"` のような sudo 込みコマンドを **passwordless** で打てるようになります。hardening 作業 30 分のうち、ユーザー操作は **NOPASSWD 付与の 1 回のみ** に圧縮できました。

:::message alert
**NOPASSWD は scope を厳密に切って、作業終了後に必ず撤去する** 運用にしてください。全コマンド NOPASSWD は cyber security の伝統的な anti-pattern です (compromise 時に root と等価)。本記事の例では `systemctl <op> openclaw-gateway` / `journalctl -u openclaw-gateway` / `cat|cp|tee /etc/systemd/system/openclaw-gateway.service*` / `systemd-analyze {security,verify}` の operations 限定にしています。
:::

### 撤去フェーズで踏んだ罠: sudo timestamp cache

hardening 完了後に `sudo rm /etc/sudoers.d/openclaw-claude-ops` で NOPASSWD ファイルを削除して、続けて Claude に `sudo -n systemctl daemon-reload` で失効確認をさせました。期待値は「password 要求で `rc=1`」でしたが、実測は **`rc=0` で成功** してしまいました。

原因は `sudo` の **credential timestamp cache** (default 15 分) でした。ユーザーが直前に interactive `sudo rm` を打った時点でクレデンシャルがキャッシュされていて、その有効期限内に NOPASSWD 失効を検査しても **キャッシュ経由で `sudo -n` が通り続けてしまう** わけです。NOPASSWD 撤去自体は成功しているのですが、検査側の見立てを誤らせる挙動でした。

正しい検査手順は、`sudo -k` でキャッシュを明示的にクリアしてから検査することでした。

```bash
# WRONG (false negative: 撤去済みなのに sudo -n が通って「失効してない」と誤断する可能性)
sudo rm /etc/sudoers.d/openclaw-claude-ops
sudo -n systemctl daemon-reload  # → rc=0 (キャッシュで成功)

# RIGHT (キャッシュをクリアしてから検査)
sudo rm /etc/sudoers.d/openclaw-claude-ops
sudo -k                           # ← ここで cache 破棄
sudo -n systemctl daemon-reload   # → rc=1 + "パスワードが必要です"
```

「撤去 → 即検査」の自動化スクリプトを書く場合は、**必ず `sudo -k` を間に挟む** のが鉄則です。これは NOPASSWD 撤去スクリプト共通のチェックパターンとして覚えておく価値がある気がします。

### 副次効果: 安全姿勢の完全復帰

撤去後の状態は以下です。

| 項目 | 状態 |
|---|---|
| `/etc/sudoers.d/openclaw-claude-ops` | 削除済 (`ls` で「ファイルがありません」を確認) |
| `sudo -k && sudo -n systemctl daemon-reload` | `パスワードが必要です` (rc=1) |
| Claude が hostname で root を passwordless で取れる経路 | 完全に閉じた |
| 残存している Claude の自律権限 | `Bash(ssh username@hostname:*)` (= passwordless ではないため、起動時 keychain 経由でも sudo は password 要求に戻ります) |

これで **hardening 作業中だけ blast radius を広げて、終わったら元の最小権限に戻す** という ephemeral elevation のサイクルが完成しました。全コマンド sudo NOPASSWD を恒久的に貼ったままにしないことが大事です。(このサイクル自体を `op-up.sh` / `op-down.sh` のような対のスクリプトにしておくと心理的な障壁が下がる、というのは別記事ネタにしようかと思っています。)

## ハマりポイントまとめ

| # | 症状 | 原因 | 解決 |
|---|---|---|---|
| 1 | sudoers.d ファイルが `構文エラー` で拒否 | iTerm2 の paste で `\` 行継続後に 2 スペースインデントが混入 | SSH stdin で /tmp に書く → `sudo install` で配置 (paste 不要) |
| 2 | daemon が `Unsafe fallback OpenClaw temp dir` で crash loop | `ProtectSystem=strict` で /tmp が ro 化 | `PrivateTmp=yes` 追加で daemon 専用 namespace の /tmp を確保 |
| 3 | `du -sh /opt/openclaw` が `4.0K` と表示される | `chmod -R u=rwX,g=rX,o=` で o= したため username が中身を読めない | `sudo du` で打ち直すと正しく 2.9G。「rsync が空コピー失敗した」ではなく権限で見えなかっただけだった |
| 4 | `openclaw daemon install --user` フラグなし | 公式は current user 用 service として登録する設計 | 自前 unit を書く |
| 5 | `openclaw doctor \| head -50` で永久 hang | `doctor` は対話 prompt を出すため stdin 待ちで止まる | Ctrl+C で抜けて非対話実行は別途検討 |

## 次回予告 (#6 以降)

本記事で daemon 本体 + 権限分離 + hardening は完了しました。残課題は以下です。

- **Web UI build**: `Control UI build failed: Missing UI runner: install pnpm` → username で build → `/opt/openclaw/dist/web` 等を rsync で同梱する設計 (build chain を runtime user に持たせない方が secure)
- **port forward 動作確認**: Mac から `ssh -N -L 18789:127.0.0.1:18789 username@hostname` → `http://localhost:18789/` で token 認証
- **Cloudflare Tunnel + Access (MFA)** で外部公開
- **restic backup → Cloudflare R2 / Backblaze B2** で /var/lib/openclaw + /etc/openclaw を nightly 退避
- **Sentry / Pushover で外形監視 + アラート**

## 参考リンク

- OpenClaw: https://openclaw.ai
- systemd.exec(5): https://www.freedesktop.org/software/systemd/man/systemd.exec.html
- Issue #4 (本作業の hardening trace): https://github.com/miyashita337/openclaw-rpi5-ops/issues/4
