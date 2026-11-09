#!/usr/bin/env python3
"""図 1（articles/transcript-redact-before-s3.md）: 実データ検証 3 回での「辞書語の残り」の推移。

伏せ処理と同じ正規表現を使う伏せ漏れスキャンの検出は、その 1・その 2 とも 0 件だった。
残りの数は、別の道具（Python の部分一致）で数え直した値。
データは sources/transcript-redact-before-s3.yaml の S11 / S12 / S13 と同じ値をインライン化している
（再現用。値を変えるときは yaml と本文の両方を直す）。
実行: python3 scripts/figures/transcript-redact-before-s3-01.py  （repo ルートから）
"""
import pathlib

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

# Hiragino Sans（macOS）が無い環境では IPAGothic 等にフォールバックする
plt.rcParams["font.family"] = ["Hiragino Sans", "IPAGothic", "Noto Sans CJK JP", "sans-serif"]
plt.rcParams["axes.unicode_minus"] = False

OUT = pathlib.Path("images/transcript-redact-before-s3/01-leftover-trend.png")

LABELS = ["その 1\n境界あり（辞書 24 規則）", "その 2\n+ 部分一致フラグ p", "その 3\n+ JSON エスケープ直後の\n境界判定を修正"]
LEFT = [935, 248, 11]  # S11 / S12 / S13（その 3 は人名 7 + ID 系 4、いずれも許容）
FILES = [37, 4, None]  # その 3 はファイル数の合計を取っていない（人名 2 ファイル・ID 系 1 ファイル、重なりは未確認）
SCAN = ["0 件", "0 件", "—"]

fig, ax = plt.subplots(figsize=(8, 4.5), dpi=150)
bars = ax.bar(LABELS, LEFT, color=["#c0504d", "#e0a040", "#4f81bd"], width=0.55)
ax.set_xticks(range(len(LABELS)), [f"{lb}\n（スキャン検出: {s}）" for lb, s in zip(LABELS, SCAN)])
for b, n, f in zip(bars, LEFT, FILES):
    ax.text(b.get_x() + b.get_width() / 2, b.get_height() + 15, (f"{n} か所（{f} ファイル）" if f else f"{n} か所"),
            ha="center", va="bottom", fontsize=10)
ax.set_ylim(0, 1050)
ax.set_ylabel("辞書語が残っていた箇所")
ax.set_title("伏せ漏れスキャンは 0 件でも、数え直すと残っていた（実データ 7 日分）")
ax.spines[["top", "right"]].set_visible(False)
fig.subplots_adjust(bottom=0.3)
OUT.parent.mkdir(parents=True, exist_ok=True)
fig.savefig(OUT)
print(OUT)
