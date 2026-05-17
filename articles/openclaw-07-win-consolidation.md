---
title: "OpenClaw自動化サーバー構築記 #7 Win 集約への撤退判断 — 移行はまだ途中です"
emoji: "🪟"
type: "tech"
topics: ["openclaw", "ollama", "raspberrypi", "discord", "homelab"]
published: false
---

:::message alert
**本記事は移行完了の記事ではありません**。#6 末尾の「次回 #7 で Win 集約への撤退」予告に対して、本記事執筆時点 (2026-05-17) では **(D) ハイブリッド構成のまま運用 2 日目**で、撤退そのものは未実施です。本記事では「なぜ撤退が必要と判断したか」「現状の症状ログ」「目標構成と移行を止めているもの」をまとめます。実行記は #8 以降に分割します。
:::

![intro: Pi5 から Win タワーへの引き継ぎ](/images/openclaw-07/08-intro-retreat.png)

## TL;DR（1 行）

**Pi5 で OpenClaw を 24h 走らせようとしたらマシンスペックが足りず、Windows タワーに退避することにしました**。本記事はその撤退判断のログで、実装はまだ途中です。

なお、ここで退避先にしている Windows タワーは [初心者が挑む！自作PC組み立て完全ガイド【MAG B650 TOMAHAWK WIFI + RTX 4070 Ti SUPER】](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) で組んだマシンです。

## はじめに

[#6](https://zenn.dev/harieshokunin/articles/openclaw-06-discord-hybrid) では Discord 受信窓口を RPi5 に置き、LLM 推論を [Windows タワー](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a)へ forward する **(D) ハイブリッド** を採用しました。受信側は動いたのですが、**実運用してみると Pi5 上で OpenClaw daemon を 24h 走らせること自体が無理筋** であることが分かってきました。

本記事はその「気づき」と「撤退判断」のログです。実装そのもの (OpenClaw 停止 + bridge bot 移設) は本記事執筆時点ではまだ実施できていません。撤退の判断と移行の停滞理由を、**何が起きてどう判断したか** の時系列で順に書きます。

:::message
本記事は **個人開発の自宅サーバー** での記録です。法人運用や複数人 Discord サーバーには別の制約 (権限設計 / SLA / 監査) が乗ります。
:::

## Step 0: 撤退を決めた 3 症状

具体的に詰んだのは以下の 3 つです。どれも単独では「最適化すればなんとかなる」ように見えたのですが、3 つが連鎖していたので **Pi5 のハード性能不足** が根本だと判定しました。

### 症状 1: session JSONL の token 飽和 (32K budget の 99.97%)

![症状1: compaction で 30 秒固まる Pi5](/images/openclaw-07/09-symptom-1-compaction.png)

OpenClaw は対話履歴を `~/.openclaw/workspace/sessions/agent:main:discord:channel:<id>.jsonl` に追記していく仕組みなのですが、Discord で数往復するだけで **token budget 32K の 99.97%** まで到達します。OpenClaw はそこで自動 compaction (要約圧縮) に入るのですが、これが **Pi5 上では 30 秒以上かかります**。

```
[openclaw] context budget: 31987/32000 tokens (99.97%) — compacting...
[openclaw] compaction took 32441ms
```

compaction 中は OpenClaw が他のメッセージを処理できないので、**チャットボットが返事を書こうとして毎回 30 秒固まる** 状態になります。

### 症状 2: Node event loop が compaction 中に 32 秒ブロックされる

![症状2: heartbeat が止まって Discord 切断](/images/openclaw-07/10-symptom-2-heartbeat.png)

OpenClaw は Node.js で動いていて、compaction 中に **event loop が 32 秒ブロック** される現象が出ます。journald にこう出ます。

```
openclaw-gateway[1824]: [perf] event loop blocked for 32441ms
openclaw-gateway[1824]: [discord] gateway heartbeat ACK timeout (>10s)
openclaw-gateway[1824]: [discord] WebSocket closed (4000), reconnecting...
```

Event loop が止まっている間は **Discord gateway の heartbeat (10 秒以内に ACK 必須)** が間に合わず、WebSocket が切断されます。再接続自体は数秒で済みますが、その瞬間に来たメッセージは取りこぼします。

Pi5 の Cortex-A76 (4 core / 2.4GHz) は普段使いには十分速いのですが、Node の同期処理を 30 秒掛けるような重い処理はそもそも乗りません。

### 症状 3: embedding 経路の二重故障

![症状3: OpenAI も Pi5 ローカルも詰まる八方塞がり](/images/openclaw-07/11-symptom-3-embedding-deadlock.png)

OpenClaw は対話履歴検索に embedding (text-embedding-3-small) を使うのですが、OpenAI quota 上限で 429 を吐くようになりました。

```
[openclaw] embedding error: 429 Too Many Requests
```

代替として Pi5 上 Ollama で `nomic-embed-text` に切り替えたのですが、Pi5 の CPU 推論が遅すぎて (1 batch 8 秒) 常用できず。要は **embedding を Pi5 で賄うのは無理、かといって OpenAI に依存すると 429 で詰む** デッドロックです。

## Step 1: 現状 (D) ハイブリッドの実機ログ

![Win Tower 落ちで forward 経路が SPOF 化](/images/openclaw-07/12-D-hybrid-spof.png)

撤退判断の根拠は症状 1〜3 ですが、本日 (2026-05-17) に実際にもう 1 つの症状を観測したので付記します。**[Win Tower](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) 落ち = Discord 全停止** という SPOF 構造です。

### 現在の構成 (運用 2 日目)

![current-arch](/images/openclaw-07/05-arch-current-D-hybrid.png)

### `systemctl status` で見ると OpenClaw はまだ Pi5 で走っている

撤退方針は #6 末尾で書いたのですが、執筆時点で実装は未着手です。実機の `systemctl status` がそれを物語っています。

![systemctl-status](/images/openclaw-07/01-systemctl-status-still-running.png)

`Active: active (running) since Fri 2026-05-15 10:16:59 JST; 2 days ago` の通り、撤退予告から 2 日経った時点でも普通に走っています。SD カード書き換え後、`systemctl enable` のまま放置してあったので boot 時に勝手に起動します。

### Win Tower 落ちで 14 分間 Discord 全停止

本日の `journalctl` から、Win Tower がオフラインだった 13:33〜13:47 の間に発生したエラーループです。

![journal-etimedout](/images/openclaw-07/02-journal-etimedout-failover.png)

主要な observation:

- 1 回の `embedded run` で **825 秒 = 約 14 分** retry し続けた (`durationMs=825618`)
- fallback 経路は `next=none` で設定されていない (どこにも逃さない)
- Discord 側はその間、Bot からエラー応答が来るか沈黙する

`next=none` (fallback 未設定) は今回意図的にそうしているわけではなくて、まだ「OpenAI fallback」「Mac claude-hub fallback」のような設計に手が回っていない、というのが本音です。SPOF を承知で運用していました。

## Step 2: Win Tower 側 Ollama の状態確認

[Win Tower](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) 側は Ollama がきちんと動いているか確認しておきます。Tailscale 越し `curl` で取得した `/api/tags` がこちら。

![ollama-tags](/images/openclaw-07/03-ollama-tags-win-tower.png)

- `qwen3.6:27b` (Q4_K_M, 17.4GB) — 主力モデル
- `nomic-embed-text` — embedding 用 (Pi5 でやらせていた仕事の引取先)
- `llama3.1:8b` / `gemma2:9b` / `qwen2.5:7b` — 検証用

Mac から `curl` して `http=200 / 27ms`、hostname (RPi5) から叩いても `17ms` 応答です。**Tailscale 越しでも latency は無視できる** ので、forward の遅さが Pi5 側の問題であって Win Ollama 側ではないことが分かります。

### Tailscale 越し Qwen3.6:27B の実機ベンチ

bench スクリプトを 5 prompt 投げた実測値です ([openclaw-rpi5-ops/bench-results/ollama-tailscale](https://github.com/miyashita337/openclaw-rpi5-ops/tree/main/bench-results/ollama-tailscale))。

![bench-summary](/images/openclaw-07/04-bench-summary-tailscale.png)

読み取り:

- **コールドスタートは ~49 秒** (Ollama にモデルをロードする一発目)
- **持続スループットは 6.3〜6.7 tok/s** — Qwen3.6:27B (Q4_K_M) を [Win タワー](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) (具体的なスペックはリンク先の自作 PC 組み立て記事を参照) で回した値
- 短い応答 (~200 文字) で 8〜11 秒 → Discord チャットとしては実用域
- 長文 (~3000 文字 = 1032 token) で 164 秒 → 待たせすぎなので bridge bot 側で `num_predict=512` を強制する設計に倒した

## Step 3: 4 案を再評価して (E) Win 単独に

![5 案分岐: A B C D は通行止め、E だけ通れる](/images/openclaw-07/13-options-fork-E.png)

[#6 Step 0](https://zenn.dev/harieshokunin/articles/openclaw-06-discord-hybrid#step-0-4-案比較) で並べた 4 案を、症状 1〜3 + 本日の SPOF 観測を踏まえて再評価しました。

![options-reeval](/images/openclaw-07/07-options-reeval-table.png)

なお、案 A の「Mac の claude-hub だけに Discord を持たせる」構成は別記事 [【導入編】: claude-hub — iPhoneからClaude Codeを操作するDiscord Supervisorシステム](https://zenn.dev/harieshokunin/articles/c6ba085ed070e3) で詳しく書いています。本記事では「夜 Mac を閉じると沈黙する」点だけを採点しています。

(D) から (E) への切り替えのキモは、**Pi5 に OpenClaw を置く限り症状 1, 2 は避けられない** という気づきです。forward 経路を改善しても、Pi5 上で OpenClaw daemon が走っている時点で event loop ブロックは起き続けます。だから **forward を改善するより、Pi5 から OpenClaw 自体を抜く** 方が筋でした。

ただし (E) には前提条件があります:

1. **[Win Tower](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) の 24h 稼働** — 今は気分で起こしているので、Wake-on-LAN 含めて運用ルールを決める必要があります
2. **新規 Discord Bot Token の発行** — bridge bot 用に既存とは別の Bot を Developer Portal で作る必要があります (既存 token は OpenClaw 用に温存)
3. **RPi5 (hostname) 側 OpenClaw の停止と mask** — `systemctl stop && disable && mask` で復活を機械的に防ぎます

このうち 1, 2 が今ストッパーになっていて、本記事を撤退完了記ではなく「判断と途中経過の記事」にしました。

## Step 4: 目標構成 (E) と bridge bot の設計

![OpenClaw 多腕ロボから 165 行豆ロボへ](/images/openclaw-07/14-bridge-bot-minimal.png)

撤退完了後の姿はこうなります。

![target-arch](/images/openclaw-07/06-arch-target-E-win-consolidation.png)

bridge bot 本体は AgentTeams 診断 (architect / devils-advocate / refactor-cleaner / fact-checker) で「**agentic framework は要件外、純粋な forward だけで足りる**」と全員一致した結果、**165 行の Python** に落としました。コード本体から要点を抜粋します。

```python
async def query_ollama(prompt: str) -> str:
    """Ollama native /api/chat を non-stream で叩く。think:false で thinking 無効化。"""
    async with httpx.AsyncClient(timeout=TIMEOUT_SECONDS) as http:
        resp = await http.post(
            f"{OLLAMA_URL}/api/chat",
            json={
                "model": MODEL,
                "messages": [{"role": "user", "content": prompt}],
                "stream": False,
                "think": False,
                "options": {"num_predict": 512},  # Qwen 冗長応答 hang 回避
            },
        )
        resp.raise_for_status()
        body = resp.json()
        message = body.get("message") or {}
        content = (message.get("content") or "").strip()
        if not content:
            raise RuntimeError(f"empty response: {body!r}")
        return content


@client.event
async def on_message(message: discord.Message) -> None:
    if not client.user or message.author == client.user or message.author.bot:
        return
    is_dm = isinstance(message.channel, discord.DMChannel)
    mentioned = client.user in message.mentions
    if not (is_dm or mentioned):
        return
    prompt = strip_mention(message.content, client.user)
    if not prompt:
        await message.reply("メッセージ本文が空です。質問を書いてください。")
        return
    async with message.channel.typing():
        reply = await query_ollama(prompt)
    for chunk in chunk_for_discord(reply):
        await message.reply(chunk)
```

依存は **discord.py / httpx / python-dotenv** の 3 つだけ。OpenClaw が抱えていた session JSONL, compaction, embedding, persona 管理, multi-agent routing 等は **要件外** なので全部削ぎ落としました。

`/Users/harieshokunin/agent-base/rules/general/agent-output-quality.md` の **anti-pattern #4「使われない機能の継続保守の禁止」** に該当する機能群でした。記事 #6 で組んだ persona 管理 (IDENTITY.md / USER.md / SOUL.md) も結局 1 回設定したきり更新していなかったので、消して問題ありません。

### ハマり予告: `num_predict` を 4096 から 512 に下げる必要あり

bench Run 3 のときに発見した罠です。`num_predict` を 4096 (Ollama デフォルト) のままにしていたところ、**Qwen3.6:27B が冗長な応答を吐き続けて hang** する現象が出ました。`think:false` で thinking を無効化しても、本文生成側で延々と書き続けます。512 に下げて安定しました。Discord 表示上限 2000 文字の関係で実用上もこれくらいで十分です。

```diff
- "options": {"num_predict": 4096},
+ "options": {"num_predict": 512},
```

## Step 5: 移行を止めている 2 点

![2 つの鍵のかかったゲート: Win 24h 運用 + 新規 Bot Token](/images/openclaw-07/15-blockers-locked-gates.png)

撤退判断は確定したのに本記事執筆時点で実装が止まっている理由を整理しておきます。

### ブロッカー 1: Win Tower の 24h 運用方針

今までは「夜は [Win Tower](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) を落としていた」のですが、(E) を採用すると **Win 落ち = Discord 沈黙** になります。本日 13:33〜13:47 の 14 分間 ETIMEDOUT を出していたのが正にそれです。

対応案:

- **(α) 完全 24h 起こす**: 電気代と寿命とのトレードオフ
- **(β) Wake-on-LAN**: Pi5 → Win に WoL マジックパケットを投げて起こす。Discord 受信側を Pi5 に残す必要があるので (E) には合わない (D に近くなる)
- **(γ) 諦めて夜は沈黙**: Bot は朝起きる前提で運用、Discord に「夜は寝てます」と書いておく

現実的には (γ) で始めてみて、必要なら (α) に上げる方針です。電気代が決め手ですが、計算してから決めます。

### ブロッカー 2: 新規 Discord Bot Token

既存 OpenClaw 用 Bot Token (`@openclaw-rpi5`) は OpenClaw daemon で使い続ける可能性があるので、bridge bot 用には **別の Bot User** を作ります。これは Discord Developer Portal の手動操作なのでスクリプト化できません (#6 Step 1 で詳しく書いた手順を踏みます)。

ただし、新規 Bot を作ると **Discord サーバーへの再招待 + 権限再付与** が必要です。Privileged Intents (Server Members + Message Content) の ON も再度必要です。要するに **#6 Step 1〜3 をもう一回繰り返す** ので、その手順は #6 を読み返すことで再利用できます。

## Step 6: Pi5 系記事 (#1〜#7) で生き残る知見

撤退後の Pi5 の役割と、各記事の知見の生死を整理しておきます。

| 出典 | 知見 | 撤退後も使える |
|---|---|---|
| #2 | Tailscale + MagicDNS + ssh の組み合わせ | はい |
| #2 | `ssh user@hostname` のホスト解決 | はい |
| #3 | TigerVNC vs Pi Connect の比較、Wayland 制約 | はい (リモデで使用継続) |
| #4 | piclone が壊れていた話、rsync -aHAXx での代替 | はい (Pi5 SD 焼き直し時に) |
| #5 | systemd hardening の Tier A/B/B-2/C | テンプレートとして温存 |
| #5 | NOPASSWD 撤去フェーズの sudo timestamp cache trap | はい (恒久知見) |
| #6 | Discord Privileged Intents (Server Members + Message Content) | はい (bridge bot でも同じ) |
| #6 | pairing flow / token rotation | bridge bot は pairing 自体不要、rotation は同じ |
| #6 | OpenAI billing canceled の silent 401 | bridge bot は OpenAI 不要なので非該当 |
| #6 | channel は @mention 必須 / DM 不要 | はい (bridge bot 内で同じ filter ロジック実装済み) |
| #7 (本記事) | Pi5 上で agentic framework を 24h 走らせるのは hardware fitting 上の限界 | 教訓として残る |

**Pi5 系の hardware 限界に当たった経験** そのものが #7 の核なので、撤退が完了していないとしても本記事を出す価値はある、というのが私の判断です。

## ハマりポイントまとめ (#7 で追加)

| # | 症状 | 原因 | 解決 |
|---|---|---|---|
| 1 | OpenClaw が compaction で 32 秒固まる | Pi5 上で session JSONL が 32K token budget の 99.97% に到達 | Pi5 から OpenClaw 撤去 (実装は #8 以降) |
| 2 | Discord gateway heartbeat ACK timeout で切断連発 | event loop が compaction 中に 32 秒ブロックされる | 同上 (構成変更) |
| 3 | OpenAI embedding が 429 で詰まる | quota 上限、Pi5 Ollama 切替も CPU 推論で遅すぎ | Win タワーで Ollama に集約 (embedding も含めて) |
| 4 | Win Tower 落ち = Discord 14 分沈黙 | (D) ハイブリッドで forward 先が SPOF、fallback 未設定 | (E) 移行で Pi5 → Win 完全集約、Win 24h 運用方針確定が前提 |
| 5 | Qwen3.6:27B が冗長応答で hang | `num_predict: 4096` (default) | `num_predict: 512` に下げる (bridge bot で実装済み) |
| 6 | Tailscale 越しの Ollama 初回 1 リクエストが 49 秒 | Ollama のモデルロード (cold start) | 受け入れる (運用上は最初の 1 回だけ) |

## 次回予告 (#8) — 実際の cut-over

![#7 から #8 へ: 次の山に向かう](/images/openclaw-07/16-next-episode-8.png)

#7 で判断したことを #8 で実装します。やること:

- [Win Tower](https://zenn.dev/harieshokunin/articles/3aca5170f9ee8a) 24h 運用方針の確定 (電気代の試算込み)
- Discord Developer Portal で新規 Bot 発行 + サーバー招待 + Privileged Intents 設定
- Win Tower への `discord-ollama-bridge.service` deploy (systemd unit 作成)
- RPi5 (hostname) 側で `systemctl stop && disable && mask openclaw-gateway.service`
- 1 週間運用してみての所感と、再度の (E) → (?) 撤退があるかどうか

ひとことでまとめると: **「動かしてみないと limit はわからない」が個人開発の本音です**。#5 で hardening まで組んでから #7 で「全部剥がす」判断をするのは無駄に見えるのですが、剥がすかどうかの判断は実際に走らせて症状を見てからでないと下せませんでした。

## 参考リンク

- 前回 #6 (Discord ハイブリッド): https://zenn.dev/harieshokunin/articles/openclaw-06-discord-hybrid
- discord-ollama-bridge.py 本体: https://github.com/miyashita337/openclaw-rpi5-ops/blob/main/scripts/discord-ollama-bridge.py
- bench-results (Ollama Tailscale 実測): https://github.com/miyashita337/openclaw-rpi5-ops/tree/main/bench-results/ollama-tailscale
- Ollama: https://ollama.com
- Qwen3.6 model card: https://huggingface.co/Qwen
- discord.py: https://discordpy.readthedocs.io
