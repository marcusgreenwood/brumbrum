#!/usr/bin/env python3
"""Analyses a Brumbrum drive log (Settings › Drive logs › share the CSV).

Usage: python3 Tools/analyze_log.py drive-YYYYMMDD-HHMMSS.csv [--plot out.png]

Reports:
  * GPS lag: the shift that best lines GPS speed up with the sensor-led speed
    estimate. Put this into Settings › Estimation › GPS lag.
  * How well the estimate agrees with GPS once that lag is removed.
  * Accelerometer bias range, time spent stopped, blips.
"""
import csv, sys
import numpy as np


def load(path):
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("empty log")
    cols = {k: np.array([float(r[k]) if k != "mode" else 0 for r in rows]) for k in rows[0] if k != "mode"}
    cols["mode"] = np.array([r["mode"] for r in rows])
    return cols


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    d = load(sys.argv[1])
    live = d["mode"] == "live"
    if live.sum() < 200:
        print("note: fewer than 2 s of live-mode data; analysing all rows")
        live = np.ones_like(live, dtype=bool)
    t, v = d["t"][live], d["speed"][live]
    print(f"duration {t[-1] - t[0]:.0f} s, {len(t)} rows, top speed {v.max() * 3.6:.0f} km/h")

    g = live & (d["gps_new"] == 1) & (d["gps_speed"] >= 0)
    tg, zg = d["t"][g], d["gps_speed"][g]
    moving = zg > 1.0
    if moving.sum() < 10:
        print("not enough moving GPS fixes to measure lag")
    else:
        best = None
        for lag in np.arange(0, 2.51, 0.05):
            est = np.interp(tg[moving] - lag, t, v)
            rms = np.sqrt(np.mean((zg[moving] - est) ** 2))
            if best is None or rms < best[1]:
                best = (lag, rms)
        zero = np.sqrt(np.mean((zg[moving] - np.interp(tg[moving], t, v)) ** 2))
        print(f"GPS lag ≈ {best[0]:.2f} s  (agreement {best[1]:.2f} m/s rms at that lag, {zero:.2f} m/s with no lag)")
        print(f"  → set Settings › Estimation › GPS lag to {best[0]:.2f}")

    innov = d["gps_innov"][g]
    if len(innov):
        print(f"GPS innovation rms {np.sqrt(np.mean(innov ** 2)):.2f} m/s, max {np.abs(innov).max():.2f}")
    b = d["bias"][live]
    print(f"accelerometer bias {b.min():+.3f} … {b.max():+.3f} m/s² (≈ {np.degrees(np.arcsin(np.clip(b.max() / 9.81, -1, 1))):.1f}° slope-equivalent max)")
    print(f"stopped {100 * d['stationary'][live].mean():.0f}% of the time; mean confidence {d['confidence'][live].mean():.2f}")
    blips = d["t"][d["blip"] == 1]
    if len(blips):
        print(f"{len(blips)} blip(s) at t = " + ", ".join(f"{x - t[0]:.1f}s" for x in blips))

    if "--plot" in sys.argv:
        out = sys.argv[sys.argv.index("--plot") + 1]
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(3, 1, figsize=(12, 8), sharex=True)
        ax[0].plot(t - t[0], v * 3.6, label="estimate")
        ax[0].plot(tg - t[0], zg * 3.6, ".", label="GPS")
        ax[0].set_ylabel("km/h"); ax[0].legend()
        ax[1].plot(t - t[0], d["raw_accel"][live], lw=0.3, label="raw")
        ax[1].plot(t - t[0], d["accel"][live], label="filtered")
        ax[1].plot(t - t[0], b, label="bias")
        ax[1].set_ylabel("m/s²"); ax[1].legend()
        ax[2].plot(t - t[0], d["rpm"][live], label="rpm")
        ax[2].set_ylabel("rpm"); ax[2].set_xlabel("s")
        fig.tight_layout(); fig.savefig(out, dpi=120)
        print("plot written to", out)


if __name__ == "__main__":
    main()
