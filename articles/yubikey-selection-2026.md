---
title: "YubiKey を買おうとしたら売り切れだった件"
emoji: "🔑"
type: "idea"
topics: ["yubikey", "passkey", "fido2", "security", "webauthn"]
published: false
---

:::message
この記事は 2026-10-26 時点の調べです。キーはまだ買えていないので、実機では試していません。購入できたら結果を追記します。
:::

## TL;DR

- 調べた範囲では、**Yubico Security Key C NFC（5,900 円）を 2 本**で足りそうです。公式の仕様では、上位の YubiKey 5C NFC（11,700 円）と同じくパスキー（FIDO2）に対応し、保存できる数も同じ 100 個です
- YubiKey 5C NFC が必要になるのは、Okta や PingID の「YubiKey のワンタイムパスワード」、Windows や Microsoft Entra のスマートカード（証明書）でのログイン、GPG の鍵の保存、認証アプリの 6 桁コードをキーに入れる使い方をするときです
- 2026-10-26 に私が見た範囲では、国内の正規代理店も量販店も売り切れでした。Amazon には海外からの輸入品がありましたが、ファームウェアが分からないので見送りました
- Yubico と Apple は、キーを 2 本以上登録するよう勧めています。Apple の公式サポートには、キーを全部なくすとアカウントに入れなくなる可能性があると書かれています
- YubiKey が防ぐのは、漏れたパスワードでのログインです。企業のサーバーからの流出そのものは防げません

## はじめに

https://www.yubico.com/?lang=ja

<!-- hearing:H2 -->
きっかけは、ここ最近の流出ニュースでした。

ここ数か月、国内では情報流出の公表が相次いでいます。10 月には IPA が PHP の脆弱性について注意喚起を出しました。

出典: [IPA「PHPの脆弱性対策について」](https://www.ipa.go.jp/security/security-alert/2026/alert20261022.html)

そこに GMO インターネットの件が重なりました。クラウドサービスが不正アクセスを受け、利用者とみられる個人情報が公開されたという報道です。

出典: [Yahoo!ニュース「GMO 24年にシステム脆弱性指摘」](https://news.yahoo.co.jp/pickup/6600878)

パスワードが漏れる前提で考えると、パスワードだけで入れる状態は危ないと感じました。そこで、物理キーの代表である YubiKey を調べ始めました。

## 全体像: YubiKey は何をしてくれるのか

YubiKey は FIDO2（パスキー）の認証器です。サービス側が WebAuthn（ブラウザ標準のパスキーの仕組み）に対応していれば、YubiKey 専用の対応がなくても使えます。

仕組みとしては、以下のようになっています。

- ログインするとき、キーに触れないと認証が通りません。パスワードが漏れても、キーがなければ入れません
- パスキーは登録したドメインでしか動きません。偽サイトに誘導されても認証が通らないので、フィッシングに強いです
- キーの中の秘密鍵は取り出せません。そのため、予備のキーはサービスごとに別に登録する必要があります

## Step 0: 条件を決める

自分の条件は以下でした。

- **USB-C と NFC の両方に対応**。PC には USB-C で挿し、iPhone には NFC でかざして使いたい
- **2 本買う**。1 本は持ち歩き、1 本は家に置く（理由は後半で書きます）
- **ファームウェア 5.7 以上**。5.7 より前だとパスキーを 25 個しか保存できず、後からファームウェアを上げることもできないとされています

出典: [Yubico「YubiKey 5 Series and Security Key Series with new 5.7 firmware」](https://www.yubico.com/blog/now-available-for-purchase-yubikey-5-series-and-security-key-series-with-new-5-7-firmware/)

## Step 1: モデルを比べる

USB-C と NFC の両方に対応するモデルを比べました。価格は 2026-10-26 時点の表示です。

| 製品 | 日本の価格（税込） | 米国公式 | パスキー保存数 | 対応方式 |
|---|---|---|---|---|
| **Yubico Security Key C NFC** | 5,900 円（Yubion） | $29 | 100 | FIDO2・U2F |
| Yubico YubiKey 5C NFC | 11,700 円（Yubion） | $58 | 100 | FIDO2・U2F・Yubico OTP・TOTP・PIV・OpenPGP |
| Google Titan（USB-C） | 未確認 | $35 | 250 | FIDO2・U2F |
| Token2 T2F2 / PIN+ Dual | 未確認 | 約 €26〜$28 | 300 | FIDO2.1・PIV・OpenPGP・OTP |

出典: [Yubico「Security Key C NFC」](https://www.yubico.com/product/security-key-series/security-key-c-nfc-by-yubico-black/)、[Yubico「YubiKey 5C NFC」](https://www.yubico.com/product/yubikey-5-series/yubikey-5c-nfc/)、[Yubion](https://ykey.yubion.com/)、[Top 5 Hardware Security Keys 2026](https://guptadeepak.com/tools/top-5-hardware-security-keys-2026/)

Security Key C NFC は「FIDO だけの安いモデル」ですが、古いモデルではありません。Yubico の製品ページでは、ファームウェアは 5.8、パスキーの保存数は 5C NFC と同じ 100 となっています。

YubiKey 5 NFC と 5C NFC の違いは端子（USB-A か USB-C か）で、機能は同じです。

Titan と Token2 は保存数が多く安いですが、今回は YubiKey を使いたかったので候補から外しました。

## Step 2: 使いたいサービスで使えるか

<!-- hearing:H3 -->
一番迷ったのはここでした。安い Security Key で、自分が口座を持っている SBI証券・楽天証券・マネックス証券や、Apple・Google で本当に使えるのか、という点です。

公式情報と、ほかの人の報告を調べた結果は以下です。

| サービス | 方式 | Security Key C NFC | YubiKey 5C NFC |
|---|---|---|---|
| マネックス証券 | パスキー | ○（公式 FAQ に記載） | ○ |
| 三菱UFJ eスマート証券 | パスキー | ○（公式に「外部セキュリティキー」） | ○ |
| SBI証券・楽天証券 | パスキー | △（公式の記載なし、個人の成功報告あり） | △ |
| 国内の銀行 | — | 物理キー対応を確認できず | 同左 |
| Apple Account | FIDO | ○（公式） | ○ |
| Google・GitHub・Microsoft など | FIDO / WebAuthn | ○ | ○ |
| Okta の「YubiKey」要素 | Yubico OTP | × | ○ |
| PingID の「YubiKey」認証 | Yubico OTP | ×（FIDO2 での登録なら可） | ○ |
| Microsoft Entra の証明書ベース認証 | PIV（スマートカード） | × | ○ |
| Windows のスマートカードログオン | PIV | × | ○ |
| 認証アプリの 6 桁コードをキーに保存 | TOTP | × | ○ |

出典: [マネックス証券 FAQ](https://faq.monex.co.jp/faq/show/26093?site_domain=default)、[証券会社のパスキー必須化と YubiKey 対応（個人ブログ）](https://infomation-sytem-security.hatenablog.com/entry/shoken-passkey-hissuka-yubikey-taiou)、[三菱UFJ eスマート証券「パスキー」](https://kabu.com/support/security/passkey.html)、[Apple「Apple Account のセキュリティキーについて」](https://support.apple.com/en-au/102637)、[Yubico「Okta and YubiKeys」](https://support.yubico.com/hc/en-us/articles/12357152446236-Okta-and-YubiKeys)、[PingID「Configuring YubiKey authentication (Yubico OTP)」](https://docs.pingidentity.com/pingid/pingid_service_management/pid_configuring_yubikey_authentication_yubico_otp.html)、[Microsoft「Microsoft Entra certificate-based authentication on iOS devices」](https://learn.microsoft.com/entra/identity/authentication/concept-certificate-based-authentication-mobile-ios)

表の最後の行は、Google Authenticator などで使う 6 桁のコード（TOTP）の元になる値を、スマホではなく YubiKey に入れておく使い方です。コードは Yubico Authenticator というアプリで読み出します。ログインで入力するのは今までどおり 6 桁のコードなので、サービス側から見ると何も変わりません。キーに触れるだけでログインできるようになるわけではない点に注意が必要です。

調べた範囲では、**パスキーで使う分には Security Key C NFC で足りそうです**。古いから使えない、という情報は見つかりませんでした。

ただし、SBI証券と楽天証券は公式には物理キーに触れていません。個人ブログで成功したという報告がある段階なので、実際に登録できるかは購入後に試して追記します。

## Step 3: どこで買うか

<!-- hearing:H3 -->
次に困ったのが、どこにも売っていないことでした。

2026-10-26 に国内の店を順に見た結果は以下です。

| 販売店 | 状態 |
|---|---|
| Yubion（ソフト技研、国内の正規代理店） | 全商品が「完売」表示。10/22〜11/1 は注文受付を一時停止 |
| ヨドバシ.com | Security Key C NFC（5,570 円）は販売終了、5C NFC（11,150 円）は販売休止 |
| ビックカメラ | 5C NFC（10,560 円）は販売終了 |
| ソフマップ・アスクル | 在庫切れ |
| モノタロウ・NTT-X Store | 取扱終了・完売 |
| 楽天市場（国内正規品） | 在庫切れ |
| Amazon.co.jp | 在庫はあるが、Amazon Global Store の輸入品 |

Amazon には在庫がありました。ただ、どれも海外からの輸入品で、中身のファームウェアは商品ページから分かりません。5.7 より前の古い在庫だと、パスキーが 25 個までになってしまいます。

正規代理店の受付停止は「在庫調整と販売体制の準備」のためとされているので、再開を待って正規代理店で買うことにしました。

中古（フリマアプリ）も考えましたが、やめました。物理キーは「信頼できる経路で買った」ことが安全の前提です。前の持ち主の設定が残っていないか、改造されていないかを自分で確かめるのは大変です。

## ハマりどころ

### 似た名前のモデルを取り違えやすい

Amazon で「YubiKey 5C NFC」を検索すると、同じページで 5 NFC（USB-A）や 5C（NFC なし）も選べます。安い方を選ぶと、端子が合わなかったり NFC が無かったりします。

| 表示 | 端子 | NFC | 価格（Amazon、輸入品） |
|---|---|---|---|
| YubiKey 5 NFC | USB-A | あり | 9,793 円 |
| YubiKey 5C | USB-C | **なし** | 10,936 円 |
| YubiKey 5C NFC | USB-C | あり | 13,919 円 |

### 値段は上がるのか

需要が急に増えて値上がりするのでは、という心配もありました。調べた範囲では以下です。

- 世界全体では、急に値上がりする気配は見つかりませんでした。Yubico の 2026 年上半期の売上は前年比 -8.8% で、米国の Amazon では 5C NFC が年初に $68 から $58 に下がっていました
- 一方で国内は、2026 年 3 月ごろから売り切れが頻発し、価格も数年前より約 6 割上がったと書いている販売業者の記事があります

出典: [Yubico 2026 年第 2 四半期報告（PDF）](https://investors.yubico.com/en/wp-content/uploads/sites/2/2021/10/report-interim-report-q2-2026-260806.pdf)、[camelcamelcamel（Amazon US の価格推移）](https://camelcamelcamel.com/product/B08DHL1YDL)、[YubiKey の購入ガイド（販売業者の記事）](https://pj-tc.com/purchase-guide-yubikey/)

国内の品薄はしばらく続くかもしれません。再開日に早めに注文するつもりです。

## 2 本必要な理由

Yubico は、予備のキーを 1 本目と同時に登録するよう勧めています。

- 1 本なくしても、もう 1 本でログインして、なくしたキーを各サービスから削除できます
- キーの中身は複製もバックアップもできないので、2 本目も各サービスに登録しておく必要があります

出典: [Yubico「Spare YubiKeys」](https://www.yubico.com/products/spare/)

キーを全部なくしたときの扱いは、サービスごとに公式の説明があります。

| サービス | キーを全部なくしたとき（公式の説明） |
|---|---|
| Apple Account | 信頼できるデバイスもなければ、アカウントに永久に入れなくなる可能性がある。キーは最低 2 本の登録が必要 |
| Google（高度な保護機能） | 復旧の申請から本人確認まで数日かかる |
| 一般のサービス | バックアップコードや別の 2 段階認証で復旧する。無ければ各社のサポートへ |

出典: [Apple「Apple Account のセキュリティキーについて」](https://support.apple.com/en-au/102637)、[Google「高度な保護機能プログラムのよくある質問」](https://support.google.com/accounts/answer/7539956?hl=en)

## YubiKey で守れないこと

最近の流出ニュースの多くは、企業のサーバーのソフトの穴を突かれたものです。仕組み上、YubiKey が防げるのは「自分のアカウントに他人がログインすること」で、それ以外は守備範囲の外です。

| 問題 | YubiKey で防げるか |
|---|---|
| 漏れたパスワードで別のサービスにログインされる | 防げる |
| 偽サイトでのフィッシング | 防げる |
| 企業のサーバーからの流出そのもの | 防げない |
| 流出した氏名・住所・カード番号の悪用 | 防げない |
| 自分の PC のマルウェアによるセッション乗っ取り | 防げない |
| メールや SMS だけでのパスワード再設定 | 防げない（鍵を迂回される） |
| SIM スワップ（携帯番号の乗っ取り） | 防げない |

YubiKey を買ったら終わり、ではありません。パスワードの再設定経路を確かめる、カードの利用通知を ON にする、といった対策と組み合わせる必要があります。

## まとめ

<!-- hearing:H4 -->
まだキーは買えていませんが、失敗ではなく途中だと思っています。何を買うか（Security Key C NFC を 2 本）と、どこで買うか（正規代理店の再開を待つ）は決まりました。

調べた範囲では、パスキーを使うだけなら YubiKey 5C NFC でなくても Security Key C NFC で足りそうです。買うときは、正規品であることとファームウェアのバージョンを確かめるつもりです。購入できたら、届いたキーのファームウェアと、各サービスでの登録結果をこの記事に追記します。

## 参考リンク

- [Yubico 公式サイト](https://www.yubico.com/?lang=ja)
- [Yubico: Security Key C NFC](https://www.yubico.com/product/security-key-series/security-key-c-nfc-by-yubico-black/)
- [Yubico: YubiKey 5C NFC](https://www.yubico.com/product/yubikey-5-series/yubikey-5c-nfc/)
- [Yubico: FAQ](https://support.yubico.com/hc/en-us/articles/4404456942738-FAQ)
- [Yubico: Spare YubiKeys](https://www.yubico.com/products/spare/)
- [Apple: Apple Account のセキュリティキーについて](https://support.apple.com/en-au/102637)
- [Google: 高度な保護機能プログラムのよくある質問](https://support.google.com/accounts/answer/7539956?hl=en)
- [マネックス証券 FAQ: 複数のデバイスでパスキーを登録するには](https://faq.monex.co.jp/faq/show/26093?site_domain=default)
- [IPA: PHPの脆弱性対策について](https://www.ipa.go.jp/security/security-alert/2026/alert20261022.html)
- [Yahoo!ニュース: GMO 24年にシステム脆弱性指摘](https://news.yahoo.co.jp/pickup/6600878)
- [YubiKey 購入｜Yubion（正規代理店）](https://ykey.yubion.com/)

<!-- 出典の再検証: bash scripts/verify-sources.sh yubikey-selection-2026 -->
