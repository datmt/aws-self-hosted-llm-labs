#!/usr/bin/env python3
"""Render docs/*.png from data/results.json.  usage: python3 tools/plots.py"""
import json, pathlib
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

root = pathlib.Path(__file__).resolve().parent.parent
data = json.loads((root / "data/results.json").read_text())
out = root / "docs"; out.mkdir(exist_ok=True)

# validated categorical slots 1-2 (blue, orange) on the light surface; see dataviz palette
SURF, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
BLUE, ORANGE = "#2a78d6", "#eb6834"
COLORS = {"EC2": BLUE, "ECS on EC2": ORANGE}
plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF,
    "font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
})

def style(ax, grid_axis="y"):
    ax.grid(axis=grid_axis, color=GRID, linewidth=0.8); ax.set_axisbelow(True)
    ax.tick_params(length=0)

def title(fig, t, sub):
    fig.text(0.06, 0.95, t, fontsize=13, fontweight="bold", ha="left", va="top")
    fig.text(0.06, 0.885, sub, fontsize=9.5, color=INK2, ha="left", va="top")

# 1 -- smoke latency, grouped bars -------------------------------------------------
def smoke():
    d = data["smoke_latency_s"]; labs = list(d)
    fig, ax = plt.subplots(figsize=(7.5, 4.2)); fig.subplots_adjust(top=0.82, bottom=0.14, left=0.08, right=0.97)
    w = 0.34; xs = range(3)
    for i, lab in enumerate(labs):
        pos = [x + (i - 0.5) * (w + 0.03) for x in xs]
        bars = ax.bar(pos, d[lab], w, color=COLORS[lab], edgecolor=SURF, linewidth=1.5, label=lab)
        for b, v in zip(bars, d[lab]):
            ax.text(b.get_x() + b.get_width() / 2, v + 0.2, f"{v:.2f}s", ha="center", va="bottom", fontsize=9, color=INK)
    ax.set_xticks(list(xs)); ax.set_xticklabels(["Request 1\n(cold)", "Request 2", "Request 3\n(steady state)"])
    ax.set_ylabel("End-to-end latency, seconds"); ax.set_ylim(0, 13.5); style(ax)
    ax.legend(frameon=False, loc="upper right", ncol=2)
    title(fig, "First requests are warm-up; steady state is 0.47 s on both",
          "10-token chat completion on one T4, through an SSM tunnel (tunnel latency included)")
    fig.savefig(out / "smoke-latency.png", dpi=160); plt.close(fig)

# 2 -- cold start composition, stacked horizontal ---------------------------------
def cold():
    d = data["cold_start_min"]; labs = list(d)[::-1]
    parts = [("apply", "terraform apply", "#9ec5f4"), ("boot_pull_download", "boot + image pull + model download", BLUE),
             ("engine_init", "vLLM engine init", "#184f95")]
    fig, ax = plt.subplots(figsize=(7.5, 3.4)); fig.subplots_adjust(top=0.66, bottom=0.2, left=0.14, right=0.97)
    for row, lab in enumerate(labs):
        left = 0
        for key, name, col in parts:
            v = d[lab][key]
            ax.barh(row, v, 0.5, left=left, color=col, edgecolor=SURF, linewidth=1.5, label=name if row == 0 else None)
            if v > 2: ax.text(left + v / 2, row, f"{v:.1f}", ha="center", va="center", color="white", fontsize=9, fontweight="bold")
            left += v
        ax.text(left + 0.25, row, f"{left:.1f} min", va="center", fontsize=9.5, color=INK)
    ax.set_yticks(range(len(labs))); ax.set_yticklabels(labs); ax.set_xlim(0, 20)
    ax.set_xlabel("Minutes from `terraform apply` to server ready"); style(ax, "x")
    ax.legend(frameon=False, loc="lower center", bbox_to_anchor=(0.5, 1.0), ncol=3, fontsize=8.5)
    title(fig, "Cold start is the image pull, not the model",
          "ECS figure includes a crash loop and an in-place fix; the middle segment is the remainder")
    fig.savefig(out / "cold-start.png", dpi=160); plt.close(fig)

# 3/4 -- benchmark (rendered only when data/results.json has a "bench" section) ----
def bench():
    b = data.get("bench") or {}
    if not b: return
    models = list(b); mcol = {m: c for m, c in zip(models, [BLUE, ORANGE, "#1baf7a"])}
    # aggregate throughput vs concurrency
    fig, ax = plt.subplots(figsize=(7.5, 4.2)); fig.subplots_adjust(top=0.82, bottom=0.14, left=0.12, right=0.86)
    labelled = []   # (x, y) already given a value label, to avoid stacking near-identical ones
    for m in models:
        c = [str(x) for x in b[m]["concurrency"]]; y = b[m]["agg_tok_s"]
        pts = [(i, v) for i, v in enumerate(y) if v is not None]
        ax.plot([i for i, _ in pts], [v for _, v in pts], color=mcol[m], linewidth=2, marker="o", markersize=7,
                markeredgecolor=SURF, markeredgewidth=2)
        for i, v in pts:
            if any(i == lx and abs(v - ly) < 40 for lx, ly in labelled): continue
            labelled.append((i, v)); ax.text(i, v + 18, f"{v:,.0f}", ha="center", va="bottom", fontsize=9, color=INK)
        last_i, last_v = pts[-1]
        ax.text(last_i + 0.12, last_v, m.split("/")[-1], va="center", fontsize=9, color=INK)
        for key, msg in (b[m].get("failed") or {}).items():   # failed level: marker at the axis, labelled
            fi = c.index(key)
            ax.plot([fi], [0], marker="X", markersize=10, color=mcol[m], markeredgecolor=SURF, markeredgewidth=1.5, clip_on=False, zorder=5)
            ax.text(fi, 40, msg, ha="center", va="bottom", fontsize=8.5, color=INK)
    ax.set_xticks(range(len(c))); ax.set_xticklabels(c); ax.set_xlim(-0.2, len(c) - 0.4)
    ax.set_xlabel("Concurrent requests"); ax.set_ylabel("Aggregate tokens generated / s")
    top = max(v for m in models for v in b[m]["agg_tok_s"] if v is not None)
    ax.set_ylim(-70, top * 1.15); ax.set_yticks(range(0, int(top * 1.1), 200)); style(ax)
    title(fig, "Batching is where a T4 earns its keep",
          "256 tokens per request, measured on the instance (no tunnel), g4dn.xlarge / vLLM 0.10.2")
    fig.savefig(out / "bench-throughput.png", dpi=160); plt.close(fig)
    # TTFT + single stream decode: two small panels, one axis each
    fig, axes = plt.subplots(1, 2, figsize=(7.5, 3.8)); fig.subplots_adjust(top=0.7, bottom=0.2, left=0.1, right=0.97, wspace=0.35)
    for ax, key, lab, fmt in [(axes[0], "ttft_ms", "TTFT, ms (lower is better)", "{:.0f}"),
                              (axes[1], "decode_tok_s", "Decode, tokens/s (higher is better)", "{:.0f}")]:
        vals = [b[m][key] for m in models]
        bars = ax.bar(range(len(models)), vals, 0.5, color=[mcol[m] for m in models], edgecolor=SURF, linewidth=1.5)
        for bar, v in zip(bars, vals): ax.text(bar.get_x() + bar.get_width() / 2, v, fmt.format(v), ha="center", va="bottom", fontsize=9.5)
        ax.set_xticks(range(len(models))); ax.set_xticklabels([m.split("/")[-1].replace("-Instruct", "").replace("-Chat-v1.0", "") for m in models], fontsize=8.5)
        ax.set_title(lab, fontsize=9, color=INK2, loc="left", pad=10); ax.set_ylim(0, max(vals) * 1.18); style(ax)
    title(fig, "At batch 1 both models decode at about the same speed",
          "Single stream, 256 generated tokens, T4; decode = (N-1)/(t_N - t_1)")
    fig.savefig(out / "bench-single-stream.png", dpi=160); plt.close(fig)

smoke(); cold(); bench()
print("wrote", *sorted(p.name for p in out.glob("*.png")))
