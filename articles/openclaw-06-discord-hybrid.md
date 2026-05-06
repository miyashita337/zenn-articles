---
title: "OpenClaw自動化サーバー構築記 #6 Discord ハイブリッド経路 (RPi5 受け / Windows LLM)"
emoji: "🪀"
type: "tech"
topics: ["openclaw", "discord", "raspberrypi", "bot", "automation"]
published: false
---

## TL;DR（数行でまとめ）

今回試してわかったことは以下です。

1. OpenClaw の Discord 統合は (A) Mac だけ / (B) RPi5 だけ / (C) Mac+RPi5 並列 / (D) RPi5 受け + 別ホストへ forward の 4 案を比較しました。**(D) ハイブリッドを採用** — RPi5 を 24h Discord 受信窓口にして、LLM 推論は **Windows タワーマシン** へ forward する構成を狙っています (forward の開通は次回 #7 予定)
2. **DiscordBotの設定は「Privileged Intents (Server Members + Message Content) 両方 ON」** が必須でした。OFF のままだと daemon 側で `[discord] Discord Message Content Intent is limited` の警告は出ますが、Bot がメンションに反応しないだけで「動いてる風」になる罠です
3. **pairing flow** は DM で `ping` → Bot が pairing code と approve コマンドを返す → hostname 側で approve コマンドを叩く → 以後 DM が通る、の 3 段でした
4. **channel post は @mention 必須 / DM は @mention 不要** です。mention 無しの channel post は Bot が無視するだけで、エラーログも残りません (Discord API 仕様)

<!-- TODO: 00-cover.png を撮影 (Discord 画面 + RPi5 hostname terminal 並走の構図) -->

## はじめに

[#5](https://zenn.dev/harieshokunin/articles/openclaw-05-openclaw-install) で OpenClaw daemon を `openclaw` system user + Tier A/B/B-2/C hardening でスコア 1.4 まで落としました。daemon は元気に走っているのですが、**ユーザー入力経路 (channels) がまだありません** — このままだと `openclaw chat` を SSH で叩くしかなく、AI agent としては片手落ちです。

OpenClaw は標準で Discord / Slack / LINE 等の channel 統合を持っているので、本記事ではその中で **Discord** を最初の input 経路として開通させていきます。ただ単にトークンを set するだけでも動くのですが、せっかくなので以下の回り道もしてみました。

- 「**Mac の [claude-hub](https://github.com/miyashita337/claude-hub) (Mac で常駐する別 daemon) と RPi5 の OpenClaw のどちらに Discord を持たせるか**」 = 4 案の比較
- (D) **RPi5 受信窓口 + Windows タワー (LLM) へ forward** ハイブリッド構成の採用 (本記事では受信側のみ開通、forward 側は次回 #7)
- **Privileged Intents** / **billing canceled の silent 401** / **pairing flow** / **persona は Discord で設定するのが速い** といったハマりを 1 つずつ潰す

最終的には **「@openclaw-rpi5 を Discord で叩くと、RPi5 上の polka が反応する」** ところまで持っていきました。

:::message
本記事は **個人開発の自宅サーバー + 個人 Discord サーバー** での作業ログとして書いています。法人運用や複数人サーバーでは権限設計と PII の扱いが別途要検討です。
:::

## 全体像 (採用構成: 案 D ハイブリッド)

```
┌─ Discord (cloud)
│   ├─ DM (#openclaw-rpi5#7292)        ← 1:1 用、@mention 不要
│   └─ サーバー: Claude Agents
│       └─ #openclaw-rpi5-direct        ← 雑談用、@mention 必須
│
├─ hostname (Raspberry Pi 5, openclaw user)
│   └─ openclaw-gateway.service         ← 24h 常駐、Discord WebSocket 維持
│       ├─ DISCORD_BOT_TOKEN            (/etc/openclaw/openclaw.env)
│       ├─ OPENAI_API_KEY               (会話エンジン、要 Pay as you go)
│       ├─ workspace: /var/lib/openclaw/.openclaw/workspace/
│       │   ├─ IDENTITY.md (Bot 自身が編集)
│       │   ├─ USER.md     (Bot 自身が編集)
│       │   ├─ SOUL.md     (Bot 自身が編集)
│       │   └─ notes/<日付>.md (Bot 自身が編集 + git commit)
│       └─ acp 送出経路 (将来)         → Windows タワーの LLM へ forward
│
└─ Windows タワー (self-hosted LLM)
    └─ LLM 推論を担当 (LM Studio / Ollama 等を予定、本記事では未開通、次回 #7)
```

「**入力 (Discord 受信) は常駐 RPi5、LLM 推論は Windows タワー**」という非対称分担にしました。RPi5 単体で完結させると Bot persona / 軽い chat / git 操作までは賄えるのですが、LLM を OpenAI API に頼りっぱなしだと依存が強すぎる気もしますし、24h 動かす Windows タワーがあるなら self-hosted で動かしたいところです。Mac 単体だと今度は夜に閉じている間 Discord が無言になります。RPi5 受信 + Windows LLM forward のハイブリッドにすると、**24h 受け + 自前 LLM** の両取りが効くという狙いです。

## Step 0: 4 案比較

| 案 | 構成 | メリット | デメリット |
|---|---|---|---|
| **A** | Mac の [claude-hub](https://github.com/miyashita337/claude-hub) だけに Discord を持たせる | Mac の IDE / `gh` / git の credential が直結、開発体験がベスト | Mac 閉じている間は Bot 沈黙 (= 24h 運用にならない) |
| **B** | RPi5 の OpenClaw だけに Discord を持たせる | 24h 起き続ける | 重実装も全部 RPi5 で走る (Cortex-A76 で `npm install` が遅い、Mac の credential が使えない) |
| **C** | Mac と RPi5 両方に同じ Bot Token を貼る (並列) | 両方が同時に応答できる | Discord は同一 Bot Token の並列 connection を許さず、後から繋いだ方が前を kick する `Disallowed intents` / `Already identified` エラー連発。Bot メッセージが二重投稿される問題も併発 |
| **D (採用)** | RPi5 が Discord を受け、LLM 推論は Windows タワーへ forward | 24h 受け + LLM は self-hosted、OpenAI 依存も切れる | 「forward」のプロトコル (acp) を別途設計する必要あり (= 次回 #7 で開通) |

(C) の並列が動かないのは Discord API の `Identify` 仕様 (1 Bot User = 1 Gateway connection) でした。ここで詰んでしまったので、方針を D に切り替えています。

## Step 1: Discord Application + Bot を作って Server に招待

[Discord Developer Portal](https://discord.com/developers/applications) で New Application → Bot タブで `Reset Token` してトークンを発行します。OAuth2 → URL Generator で `bot` + `applications.commands` scope を選び、Bot Permissions は最小 (Send Messages / Read Message History / Add Reactions / Embed Links) で URL を発行 → ブラウザで貼って Claude Agents サーバーに追加しました。

![Bot を Claude Agents サーバーに追加成功 (Discord OAuth モーダル)](/images/openclaw-06-discord-spike/03-discord-oauth-success.png)

### Privileged Intents の罠 (ハマり 1)

同じ Bot 設定画面を下にスクロールすると **Privileged Gateway Intents** という section があり、3 つのトグルがあります。

![Privileged Intents 修正前 (Server Members OFF / Presence OFF / Message Content ON)](/images/openclaw-06-discord-spike/01a-portal-intents-before.png)

- **Presence Intent** (誰が online か取得) — 不要
- **Server Members Intent** (サーバーメンバー一覧取得) — **OpenClaw が要求**
- **Message Content Intent** (メッセージ本文を取得) — **OpenClaw が要求**

最初は `Message Content Intent` だけ ON にしていたのですが、hostname 側の journal にこんな警告が出ていました。

![journalctl: Discord Message Content Intent is limited](/images/openclaw-06-discord-spike/04a-journalctl-intent-limited.png)

```
[discord] [default] Discord Message Content Intent is limited;
          bots under 100 servers can use it without verification.
```

警告だけで起動はするので「動いてる」と勘違いしてしまいましたが、実際には Bot がメンションに**全く反応しない**沈黙状態でした。Server Members Intent も ON にして再起動するまで、メッセージは受け取れていなかったのです。

`Server Members Intent` を ON にして hostname 側 daemon を restart したら通るようになりました。Discord 100 サーバー未満は申請不要なので、個人開発ならトグル ON で完了です。

## Step 2: hostname 側に DISCORD_BOT_TOKEN を設定

`/etc/openclaw/openclaw.env` に `DISCORD_BOT_TOKEN=...` を追記して daemon を restart します。ただし、ここには **TOKEN を terminal に echo しない** ためのお作法があるのですが、それは Step 5 でまとめて触れます。とりあえず初回の primitive な手順だけ書いておきます。

```bash
# hostname 側
read -rs TOKEN          # ← ヒストリーに残らない、画面にも出ない
printf 'DISCORD_BOT_TOKEN=%s\n' "$TOKEN" \
  | sudo tee -a /etc/openclaw/openclaw.env > /dev/null
unset TOKEN
sudo systemctl restart openclaw-gateway
sudo systemctl status openclaw-gateway --no-pager | head -10
```

成功すると以下のように `active (running)` で起動して、journal に `[gateway] starting HTTP server` などが流れます。

![DISCORD_BOT_TOKEN を env に追加 → restart → active (running) で起動](/images/openclaw-06-discord-spike/04b-token-set-systemd-active.png)

## Step 3: Pairing flow (DM bootstrap → approve)

Discord Bot は招待した瞬間から「サーバーに居る」状態にはなるのですが、OpenClaw の文脈では **owner pairing** が別途必要でした。Bot にとって「あなた誰？」が決まらないと会話を進めない設計のようです。

DM で Bot に `ping` を送ると、Bot がこんな返事をしてきます。

![DM 開始時の全景 (Bot 名 + 共通サーバー + pairing code)](/images/openclaw-06-discord-spike/02-pairing-dm-bootstrap.png)

```
OpenClaw: access not configured.
Your Discord user id: XXXXXXXXXXXXXXXXXX
Pairing code: XXXXXXXX

Ask the bot owner to approve with:
openclaw pairing approve discord XXXXXXXX
```

**Discord user ID** と **8 桁の one-time pairing code** がペアで提示されます。hostname 側でこの approve コマンドを叩きます。

```bash
# hostname 側
sudo -u openclaw openclaw pairing approve discord XXXXXXXX
# → owner として登録、以降 DM が通るようになる
```

approve すると DM で Bot とまともに会話できるようになる… はずでした。ここで次のハマりに突入します。

## Step 4: ハマり 2 — 課金してなかったのに「動いてる風 401」で勘違い

DM で Bot に `ping` を送ったら、Bot から `Something went wrong while processing your request. Please try again, or use /new to start a fresh session.` が返ってきました。何度試しても同じ反応です。

![Discord error: Something went wrong (timeline 風)](/images/openclaw-06-discord-spike/07c-something-went-wrong-error.png)

`/new` で session を切ってもダメでした。channel で `@openclaw-rpi5 OpenClaw 動く？` と聞いてみたら、Bot は別のメッセージを返してきました。

![Bot reply: Your account is not active, please check your billing details](/images/openclaw-06-discord-spike/07b-bot-reply-billing-error.png)

`Your account is not active, please check your billing details on our website.` — これは **OpenAI 側のエラーメッセージ** で、Discord エラーではありません。「Discord が壊れている」と思って Bot Token rotation を始めかけたのですが、念のため hostname の journalctl を確認してみました。

![hostname journal: model_fallback_decision reason=auth (OPENAI_API_KEY が無効)](/images/openclaw-06-discord-spike/07e-openai-key-rotation-auth-error.png)

```
[model-fallback/decision] decision=candidate_failed
    requested=openai/gpt-5.5 candidates=openai/gpt-5.5
    reason=auth
    next=none
    detail=No API key found for provider "openai"
```

**OpenAI 側の billing が canceled** で API key が無効化されていました。OpenAI の billing page を開いて確認してみます。

![OpenAI Billing: Canceled (2026年1月30日に解約済)](/images/openclaw-06-discord-spike/07a-openai-billing-canceled.png)

`Your billing plan was canceled on 2026年1月30日 2:06 JST.` 確かに切れていました。ここで対応したのは 2 段です。

1. `OPENAI_API_KEY` を新規発行 → hostname の env に設定 → restart (キーローテーション自体は問題ないのですが、billing が切れているので解決はしません)
2. OpenAI 側で **Pay as you go** を再有効化、**Auto recharge** ($5 を切ったら $10 まで自動 top-up) を ON

![OpenAI Billing: Pay as you go 再有効化 ($10 + Auto recharge ON)](/images/openclaw-06-discord-spike/08-openai-billing-reactivated.png)

の 2 段で復活しました。hostname 側 daemon を restart したら DM で会話できるようになっています。

**今回の教訓**: Discord 側のエラー文 (`Something went wrong`) は OpenAI 側のエラー (`Your account is not active`) を Generic な文言でラップしているので、**Discord だけ見ていると原因特定が遅れます**。必ず `journalctl -u openclaw-gateway -n 50 --no-pager` で auth エラーの有無を見るのが安全です。

ちなみに timeline で並べるとこうなります (Bot が 2 種類のエラーを返している)。

![Discord 全景: Something went wrong → @openclaw-rpi5 OpenClaw 動く？ → Your account is not active](/images/openclaw-06-discord-spike/07b2-billing-error-timeline.png)

## Step 5: ハマり 3 — DISCORD_BOT_TOKEN rotation を 4 回やった話

billing 復旧前に「Discord 側が壊れた」と疑って Bot Token を rotate する選択肢を検討していたときに、**terminal に生 token を出す事故を 4 回連続で起こしました**。Alfred のクリップボードヒストリーに残っていた dump を後から解析していて発覚した話です。

事故パターンはこんな感じです。

```bash
# (BAD 1) echo で token を可視化してしまう
echo "DISCORD_BOT_TOKEN=$NEW_TOKEN" | sudo tee -a /etc/openclaw/openclaw.env

# (BAD 2) sudo cat で env を確認しに行ってヒストリーに残る
sudo cat /etc/openclaw/openclaw.env

# (BAD 3) printf で stdout に出してヒストリーに残る
printf 'DISCORD_BOT_TOKEN=%s\n' "$NEW_TOKEN"
```

これらは全部 **iTerm2 のスクロールバッファ + Alfred クリップボード** に残ってしまいます。後でスクショを取ったり貼ったりする時に **生 token がそのまま見える状態で記録される** という、結構怖い経路です。4 回ヒストリー dump 経由で漏れた = 4 回 rotate する羽目になりました (本セッションで該当のスクショ 5/53 枚を緊急削除しています)。

最終的に確立した「terminal に出さない」rotation 手順はこちらです。

```bash
# hostname 側
read -rs NEW_TOKEN                            # 入力時に画面表示なし
echo "length: ${#NEW_TOKEN} chars"            # 長さだけ確認 (期待: 72)

sudo cp /etc/openclaw/openclaw.env \
        /etc/openclaw/openclaw.env.bak.$(date +%s)

sudo sed -i "s|^DISCORD_BOT_TOKEN=.*|DISCORD_BOT_TOKEN=${NEW_TOKEN}|" \
  /etc/openclaw/openclaw.env

# verify (token 本体は ***** に置換した形でしか出さない)
sudo grep -E "^DISCORD_BOT_TOKEN=" /etc/openclaw/openclaw.env \
  | sed 's|=.*|=*****|'

unset NEW_TOKEN
sudo systemctl restart openclaw-gateway
sudo journalctl -u openclaw-gateway -n 10 --no-pager | tail
```

ポイントは 4 つです。

1. **`read -rs`** (silent) で受け取り、`${#NEW_TOKEN}` で長さだけ検査します
2. **置換は `sed -i`** で、その場で書き換えます (cat や echo で可視化しない)
3. **verify は `sed 's|=.*|=*****|'`** で値部分をマスクしてから出します
4. **`unset NEW_TOKEN`** で shell 変数からも消しておきます

terminal 全景はこんな感じです (token 部分はすべて伏字にしています)。

![DISCORD_BOT_TOKEN rotation 全工程 (token 本体は伏字)](/images/openclaw-06-discord-spike/09b-token-rotation-token-masked.png)

ちなみに OPENAI_API_KEY の rotation も同じパターンです。

![OPENAI_API_KEY rotation 全工程 (key 本体は伏字)](/images/openclaw-06-discord-spike/07d-openai-key-rotation-terminal.png)

:::message alert
**`echo "$TOKEN"` / `cat .env` / `printf '%s' "$TOKEN"` は禁止**です。一度でも terminal に出した token は **immediately rotate** が安全です。terminal scrollback / iTerm2 history / クリップボード履歴 (Alfred 等) / スクショ全部に残ってしまうので、masked 化したつもりでも漏れます。
:::

## Step 6: 案 D の決定打 — Bot に persona を「会話で」設定させる

billing 復旧後、Bot とまともに会話できるようになりました。ここで本来の目的だった「Bot に persona (名前 / 雰囲気 / 署名 emoji) を設定する」フェーズに入ります。

最初は CLI で叩こうとしていました。

```bash
# CLI 経由でやろうとしていた (これは結局やらなかった)
ssh hostname 'sudo -n -u openclaw openclaw agents set-identity \
  --agent main --name polka --emoji 🎪'

# さらに「雰囲気」を反映するために IDENTITY.md を別ファイルで書いて --from-identity で読ませる
ssh hostname 'sudo -n -u openclaw openclaw agents set-identity \
  --agent main --from-identity /tmp/IDENTITY-polka.md'
```

ここで「Discord からやったほうが速くない？」と指摘が入って、試してみました。すると Bot 自身が DM で「俺、今ちょうど『起きたて』状態。誰として動けばいい？」と**会話で promptしてきていた**のです。

![DM: Bot が persona を会話で促している (test → 動いてるよ → 誰として動けばいい？)](/images/openclaw-06-discord-spike/10-end-to-end-dm-and-bot-asks-persona.png)

channel 側でも同じ promptが出ていました。(a) 最終確認として `@openclaw-rpi5 最終確認` を投げると、Bot が「動いてます。最終確認としては OK ✅」と答えつつ persona checklist を返してきます。

![channel: 最終確認 → Bot OK + persona checklist (名前 / 雰囲気 / 署名 emoji)](/images/openclaw-06-discord-spike/12a-bot-asks-persona-channel-checklist.png)

(b) `test` だけでも同じく persona prompt が出ます。

![channel: test → Bot 動いてるよ + 俺の名前 / どんな感じの存在か / 口調・雰囲気 / 署名っぽい絵文字](/images/openclaw-06-discord-spike/12b-bot-asks-persona-bullet-list.png)

ここで CLI 経路ではなく、**Discord で直接答える** ことにしました。

```
@openclaw-rpi5 Bot persona — 決め事 3 つ
  - 名前: polka (ポルカ)
    - 雰囲気: フランクな仲間
    - 署名 emoji: 🎪
```

Bot がこの内容を受け取って、**workspace の IDENTITY.md / USER.md / 今日のメモを自動で書いて、git commit まで完走** してくれました。

![Bot reply: 反映したよ (IDENTITY.md / USER.md / 今日のメモを書いて commit 済み)](/images/openclaw-06-discord-spike/15-bot-persona-reflected.png)

```
反映したよ。

  - 名前: polka (ポルカ)
  - 雰囲気: フランクな仲間
  - 署名: 🎪

  IDENTITY.md / USER.md / 今日のメモに書いて、コミットも済ませた。

  次は SOUL.md の確認が残ってる。 ざっくりでいいので
  「こういう振る舞いは好き / 苦手」「ここは勝手にやってOK」
  「ここは必ず確認して」みたいな境界線を教えて。
```

`ssh + sudo + 別ファイル経由 + --from-identity` で組み立てようとしていた CLI 経路と比べて、**Bot 1 reply で IDENTITY.md + USER.md + notes/<日付>.md + git commit まで完走** しています。速度・整合性・体験すべてにおいて、Discord 経路の圧勝でした。

channel 全景でも persona が反映されています (フルスクリーン)。

![channel 全景: Bot 反映後の polka persona](/images/openclaw-06-discord-spike/11a-end-to-end-channel-fullscreen.png)

クローズアップはこちら。

![channel zoom: polka 🎪 で会話が成立](/images/openclaw-06-discord-spike/11b-end-to-end-channel-zoomed.png)

:::message
**Bot/Agent が「これ教えて」と会話で promptしてきている時は、CLI で先回りせず Discord で直接答える**のが得策、という学びでした。これは feedback memory として残しています (`feedback_use_agent_conversation_when_offered.md`)。「ssh + sudo + 別ファイル + --from-identity」のような迂回経路を組み立てそうになったら、「Bot に直接訊くほうが速くないか？」を一度考えてみるとよさそうです。
:::

## Step 7: ハマり 4 — channel は @mention 必須、DM は不要

最後に、小さいけれど見落としやすい trap です。channel で `OpenClaw 動く？` と **mention 無しで** 投げると、Bot は **完全に無反応** でした (エラーログも出ません)。

![channel: mention 無しの post → Bot silent (反応なし、エラーもなし)](/images/openclaw-06-discord-spike/13-channel-no-mention-silent.png)

同じ内容を `@openclaw-rpi5 OpenClaw 動く？` と mention 付きで投げると、Bot がメッセージに 👀 reaction を付けて返答してきます。

![channel: @mention 付き → Bot が 👀 reaction で受信応答](/images/openclaw-06-discord-spike/14-mention-eyes-reaction.png)

これは **Discord API の仕様** で、Bot は `MessageCreate` event を受け取れるのですが、OpenClaw 側で「自分宛 mention を含むか」でフィルタしているようです。channel で「Bot 反応してくれない、壊れた」と疑う前に、まず @mention が付いているかを確認するのが安全です。

DM は 1:1 なので mention 不要 — テキストだけ送れば Bot が読んでくれます。

## ハマりポイントまとめ

| # | 症状 | 原因 | 解決 |
|---|---|---|---|
| 1 | Bot が channel mention に反応しない | `Server Members Intent` が OFF | Developer Portal で両 Privileged Intents を ON、daemon restart |
| 2 | Bot が `Something went wrong` を返し続ける | OpenAI billing canceled (Generic な Discord エラー文でラップされる) | OpenAI Pay as you go 再有効化 + Auto recharge ON、API key rotation |
| 3 | DISCORD_BOT_TOKEN を terminal に echo して 4 回漏らした | `echo` / `cat` / `printf` で可視化、iTerm2 scrollback / Alfred / スクショに残る | `read -rs` 受け + `sed -i` 置換 + `sed 's\|=.*\|=*****\|'` で verify、`unset` |
| 4 | Bot persona 設定で CLI を組み立てそうになった | Bot が「会話で教えて」と prompt しているのに気付かなかった | Bot の prompt に Discord で直接答える (= IDENTITY.md / USER.md / notes / git commit を Bot 自身が完走) |
| 5 | channel で mention 無し post に Bot 無反応 | Discord API + OpenClaw の filter 仕様 | channel post は @mention 必須 (DM は不要) |
| 6 | Mac と RPi5 両方に同じ Bot Token を貼ったら片方が kick された | Discord は 1 Bot User = 1 Gateway connection | (D) ハイブリッド: RPi5 受信のみ、Windows LLM forward は別経路 (acp) で開通 |

## 次回予告 (#7 以降)

本記事で **Discord 受信窓口は RPi5 で 24h 常駐** までは完了しました。次回 #7 では、**LLM 推論を OpenAI API から Windows タワーの self-hosted LLM に切り替える** ところを書く予定です。残課題はこんなところです。

- **Windows タワーに self-hosted LLM 環境構築**: LM Studio / Ollama / vLLM 等のうち、tool calling と日本語推論で使えるモデル + runtime を選定。GPU は手持ちの RTX 系を活かす想定
- **RPi5 → Windows LLM forward 経路 (acp) 開通**: RPi5 が Discord で受け取ったメッセージを Windows の LLM endpoint に転送して返答を Discord に流す protocol を設計。これで OpenAI 依存を切る
- **Bot SOUL.md (境界線) 設定**: 「こういう振る舞いは好き / 苦手 / 勝手にやって OK / 必ず確認して」を Discord で会話設定
- **複数 channel 統合**: 現状 1 channel + 1 DM のみ → 複数 channel に Bot を配置して「用途別 routing」できるようにする
- **Bot 応答速度の計測**: 現在 `@mention → 👀 reaction → 返答` までの latency が体感で 5-10 秒。OpenAI 側のレスポンスが支配的なので、self-hosted に切り替えた後の比較もしたいところ

## 参考リンク

- OpenClaw: https://openclaw.ai
- Discord Developer Portal: https://discord.com/developers/applications
- Discord Privileged Intents: https://support-dev.discord.com/hc/en-us/articles/4404772028055
- OpenAI Pay as you go: https://platform.openai.com/settings/organization/billing/overview
- 前回 #5 (OpenClaw daemon + hardening): https://zenn.dev/harieshokunin/articles/openclaw-05-openclaw-install
