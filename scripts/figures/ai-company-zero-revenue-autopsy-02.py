#!/usr/bin/env python3
"""図 2（articles/ai-company-zero-revenue-autopsy.md）: 一人 AI 会社 5 ヶ月の実測。

左: 月別 dispatch 台帳（完了 / 滞留）と朝レポ配信日数
右: 毎朝の「会長判断待ち」件数（2026-08-25〜09-16、23 日）

データは sources/ai-company-zero-revenue-autopsy.yaml の S04 / S06 / S07 / S02 と同じ値をインライン化している
（再現用。値を変えるときは yaml と本文の両方を直す）。
実行: python3 scripts/figures/ai-company-zero-revenue-autopsy-02.py  （repo ルートから）
"""
import datetime as dt
import pathlib

import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates  # noqa: E402
import matplotlib.pyplot as plt  # noqa: E402

plt.rcParams["font.family"] = "Hiragino Sans"
plt.rcParams["axes.unicode_minus"] = False

OUT = pathlib.Path("images/ai-company-zero-revenue-autopsy/02-five-months-trend.png")

# --- 左: 月別 dispatch 台帳（corp dispatches/2026-0[6-9].jsonl の state を月別集計、date <= 2026-09-16）---
MONTHS = ["2026-06", "2026-07", "2026-08", "2026-09\n(〜16日)"]
EXECUTED = [32, 5, 47, 1]
STUCK = [2, 2, 18, 8]
REPORTS = [11, 1, 26, 16]  # 朝レポ配信日数（corp reports/*.md、2026-06-06〜09-16）

# --- 右: 会長判断待ち件数（corp reports/2026-08-25.md〜2026-09-16.md の「⏭ N 件が会長の番」）---
PENDING = {
    "2026-08-25": 16, "2026-08-26": 17, "2026-08-27": 10, "2026-08-28": 9, "2026-08-29": 3,
    "2026-08-30": 4, "2026-08-31": 5, "2026-09-01": 3, "2026-09-02": 3, "2026-09-03": 6,
    "2026-09-04": 5, "2026-09-05": 7, "2026-09-06": 8, "2026-09-07": 4, "2026-09-08": 5,
    "2026-09-09": 6, "2026-09-10": 6, "2026-09-11": 6, "2026-09-12": 5, "2026-09-13": 6,
    "2026-09-14": 6, "2026-09-15": 6, "2026-09-16": 7,
}


def main() -> None:
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 4.6), dpi=160)
    fig.patch.set_facecolor("white")

    x = range(len(MONTHS))
    ax1.bar(x, EXECUTED, color="#2b6cb0", label="executed（完了）")
    ax1.bar(x, STUCK, bottom=EXECUTED, color="#e2a03f", label="dispatched 滞留")
    for i, (e, s, r) in enumerate(zip(EXECUTED, STUCK, REPORTS)):
        ax1.text(i, e + s + 1.2, f"朝レポ {r} 日", ha="center", fontsize=9, color="#444")
    ax1.set_xticks(list(x))
    ax1.set_xticklabels(MONTHS)
    ax1.set_ylabel("dispatch 件数（台帳）")
    ax1.set_ylim(0, 80)
    ax1.set_title("月別 dispatch 台帳と朝レポ配信日数", fontsize=11)
    ax1.legend(loc="upper left", fontsize=9, frameon=False)
    ax1.annotate(
        "7/4→8/6 朝レポ 33 日\nサイレント停止（corp#92）",
        xy=(1, 9), xytext=(0.15, 52), fontsize=9, color="#b03030", ha="left",
        arrowprops=dict(arrowstyle="->", color="#b03030"),
    )
    for s in ("top", "right"):
        ax1.spines[s].set_visible(False)

    dates = [dt.date.fromisoformat(d) for d in PENDING]
    vals = list(PENDING.values())
    ax2.plot(dates, vals, marker="o", color="#2b6cb0", lw=1.8, ms=4)
    avg = sum(vals) / len(vals)
    ax2.axhline(avg, color="#b03030", ls="--", lw=1)
    ax2.text(dates[-1], avg + 0.4, f"平均 {avg:.1f} 件/朝", ha="right", fontsize=9, color="#b03030")
    ax2.xaxis.set_major_formatter(mdates.DateFormatter("%m/%d"))
    ax2.xaxis.set_major_locator(mdates.DayLocator(interval=4))
    ax2.set_ylabel("会長判断待ち（件）")
    ax2.set_ylim(0, 20)
    ax2.set_yticks(range(0, 21, 4))
    ax2.set_title("毎朝の「会長判断待ち」件数（2026-08-25〜09-16, 23 日）", fontsize=11)
    for s in ("top", "right"):
        ax2.spines[s].set_visible(False)

    fig.suptitle(
        "一人 AI 会社 5 ヶ月の実測: 売上 ¥0 ／ Stripe 顧客 0 ／ 直近 30 日 PR merged 145",
        fontsize=11, y=1.02,
    )
    fig.tight_layout()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(OUT, bbox_inches="tight")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
