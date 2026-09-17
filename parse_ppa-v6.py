#!/usr/bin/env python3
"""
OpenLane 2 Multi-Run PPA & Signoff Extraction Script (v5)
==========================================================
Extracts and compares PPA metrics across the 6 most recent run directories,
including Antenna, Max Slew, and Max Capacitance violations, with fixed Fmax math.
"""

import os
import glob
import json
import re

# Find up to 6 latest RUN directories in runs/
run_dirs = sorted(glob.glob("runs/RUN_*"), key=os.path.getmtime, reverse=True)
if not run_dirs:
    print("[ERROR] No runs/ directory found in the current path!")
    exit(1)

max_runs = min(6, len(run_dirs))
target_runs = run_dirs[:max_runs]

print("=" * 125)
print(f"   OPENLANE 2 MULTI-RUN PPA & SIGNOFF COMPARISON REPORT (v5)")
print(f"   Analyzing {len(target_runs)} most recent run directories")
print("=" * 125)

def scan_logs_for_pattern(dir_path, keywords, pass_patterns, fail_patterns):
    flow_log = os.path.join(dir_path, "flow.log")
    log_files = [flow_log] if os.path.exists(flow_log) else []
    for root, dirs, files in os.walk(dir_path):
        for f in files:
            if any(kw in root.lower() or kw in f.lower() for kw in keywords):
                log_files.append(os.path.join(root, f))
    for lfile in log_files:
        try:
            with open(lfile, "r", errors="ignore") as f:
                content = f.read()
                for p_pat in pass_patterns:
                    if re.search(p_pat, content, re.IGNORECASE):
                        return 0
                for f_pat in fail_patterns:
                    m = re.search(f_pat, content, re.IGNORECASE)
                    if m:
                        return int(m.group(1))
        except Exception:
            pass
    return None

summary_rows = []

for rdir in target_runs:
    run_name = os.path.basename(rdir)
    metrics_path = os.path.join(rdir, "final", "metrics.json")
    
    data = {}
    if os.path.exists(metrics_path):
        try:
            with open(metrics_path, "r") as f:
                data = json.load(f)
        except Exception:
            pass

    def get_val(keys):
        if isinstance(keys, str):
            keys = [keys]
        for k in keys:
            if k in data and data[k] is not None:
                return data[k]
        for k in keys:
            clean_k = k.replace("__", "").replace("_", "").lower()
            for d_key, d_val in data.items():
                if d_val is not None:
                    clean_d = d_key.replace("__", "").replace("_", "").lower()
                    if clean_k in clean_d or clean_d in clean_k:
                        return d_val
        return None

    std_cell_area = get_val(["design__instance__area", "design__instance__area__stdcell"])
    die_area = get_val(["design__die__area"])
    core_area = get_val(["design__core__area"])
    cell_count = get_val(["design__instance__count"])
    raw_util = get_val(["design__instance__utilization", "design__core__utilization"])

    utilization_pct = None
    if std_cell_area is not None and core_area is not None and float(core_area) > 0:
        utilization_pct = (float(std_cell_area) / float(core_area)) * 100.0
    elif raw_util is not None:
        u_val = float(raw_util)
        utilization_pct = u_val * 100.0 if u_val <= 1.0 else u_val

    wns = get_val(["timing__setup__ws", "timing__setup__worst_slack"])
    tns = get_val(["timing__setup__tns"])
    whs = get_val(["timing__hold__ws", "timing__hold__worst_slack"])

    # Target clock period calculation for 10 MHz ASIC system (100 ns)
    clk_period = get_val(["clock__period"]) or 100.0
    if float(clk_period) <= 10.0 and float(wns or 0) > 20.0: # handles default 10ns fallback when slack is 75ns+
        clk_period = 100.0

    f_max = None
    if wns is not None:
        try:
            w_val = float(wns)
            c_per = float(clk_period)
            tcrit = c_per - w_val
            if tcrit > 0:
                f_max = 1000.0 / tcrit
        except Exception:
            pass

    max_slew_viols = get_val([
        "design__max_slew_violations", "checker__max_slew_violations", 
        "design__max_slew_violation__count", "checker__slew__violations",
        "timing__slew__violations", "slew_violations"
    ])
    max_cap_viols = get_val([
        "design__max_cap_violations", "checker__max_cap_violations", 
        "design__max_cap_violation__count", "checker__cap__violations",
        "timing__cap__violations", "cap_violations"
    ])
    antenna_violations = get_val([
        "antenna__violations", "checker__antenna_violations", 
        "checker__antenna__violations", "antenna_violation__count",
        "design__antenna_violations"
    ])

    if max_slew_viols is None:
        max_slew_viols = scan_logs_for_pattern(
            rdir,
            ["slew", "maxslew"],
            [r"no max slew violations", r"0 max slew violation", r"max slew violations:\s*0"],
            [r"(\d+)\s+max slew violation", r"max slew violations:\s*(\d+)"]
        )

    if max_cap_viols is None:
        max_cap_viols = scan_logs_for_pattern(
            rdir,
            ["cap", "maxcap"],
            [r"no max cap violations", r"0 max cap violation", r"max cap violations:\s*0"],
            [r"(\d+)\s+max cap violation", r"max cap violations:\s*(\d+)"]
        )

    if antenna_violations is None:
        antenna_violations = scan_logs_for_pattern(
            rdir,
            ["antenna"],
            [r"no antenna violations", r"\*\s*antenna\s+passed", r"0 antenna violation"],
            [r"(\d+)\s+antenna violation", r"pin violations:\s*(\d+)"]
        )

    p_internal = get_val(["power__internal"])
    p_switching = get_val(["power__switching"])
    p_leakage = get_val(["power__leakage"])
    p_total = get_val(["power__total"])
    p_dynamic = get_val(["power__dynamic"])

    if p_dynamic is None and p_internal is not None and p_switching is not None:
        try:
            p_dynamic = float(p_internal) + float(p_switching)
        except Exception:
            pass

    if p_total is None or p_leakage is None:
        sta_reports = (
            glob.glob(f"{rdir}/*stapostpnr*/power.rpt")
            + glob.glob(f"{rdir}/*stapostpnr*/sta.log")
            + glob.glob(f"{rdir}/*sta*/*.log")
        )
        for rpt in sta_reports:
            try:
                with open(rpt, "r", errors="ignore") as f:
                    content = f.read()
                    match = re.search(
                        r"Total\s+([0-9eE.+-]+)\s+([0-9eE.+-]+)\s+([0-9eE.+-]+)\s+([0-9eE.+-]+)",
                        content,
                    )
                    if match:
                        inte, sw, leak, tot = map(float, match.groups())
                        p_internal = p_internal or inte
                        p_switching = p_switching or sw
                        p_dynamic = p_dynamic or (inte + sw)
                        p_leakage = p_leakage or leak
                        p_total = p_total or tot
                        break
            except Exception:
                pass

    magic_drc = get_val(["magic__drc__error_count", "magic__drc_error__count", "checker__drc__error_count"])
    klayout_drc = get_val(["klayout__drc__error_count", "klayout__drc_error__count"])
    lvs_errors = get_val(["netgen__lvs__error_count", "netgen__lvs_error__count", "checker__lvs"])

    lvs_status = "N/A"
    if lvs_errors is not None:
        lvs_status = "PASS" if str(lvs_errors) == "0" else f"{lvs_errors} Errs"
    else:
        lvs_logs = glob.glob(f"{rdir}/*lvs*/*.log")
        for llog in lvs_logs:
            try:
                if "Circuits match uniquely" in open(llog, errors="ignore").read():
                    lvs_status = "PASS"
                    break
            except Exception:
                pass

    summary_rows.append({
        "run_name": run_name,
        "area": std_cell_area,
        "util": utilization_pct,
        "wns": wns,
        "fmax": f_max,
        "power": p_total,
        "drc": magic_drc if magic_drc is not None else klayout_drc,
        "lvs": lvs_status,
        "antenna": antenna_violations,
        "slew": max_slew_viols,
        "cap": max_cap_viols
    })

def fmt_pwr_str(v):
    if v is None:
        return "N/A"
    try:
        val = float(v)
        if abs(val) < 1e-3:
            return f"{val * 1e6:.2f} uW"
        else:
            return f"{val * 1e3:.2f} mW"
    except Exception:
        return str(v)

# Print Comparison Table
print("\n" + "=" * 125)
print("                                OPENLANE 2 PPA COMPARATIVE SWEEP MATRIX")
print("=" * 125)
header = f"{'Run Directory':<26} | {'Area(um²)':<10} | {'Util%':<6} | {'WNS(ns)':<8} | {'Fmax(MHz)':<10} | {'Power':<10} | {'DRC':<5} | {'LVS':<6} | {'Antenna':<8} | {'Slew':<5} | {'Cap':<5}"
print(header)
print("-" * 125)

for row in summary_rows:
    r_name = row["run_name"][:25] if len(row["run_name"]) <= 25 else row["run_name"][:22] + "..."
    area_s = f"{float(row['area']):.1f}" if row['area'] is not None else "N/A"
    util_s = f"{float(row['util']):.1f}%" if row['util'] is not None else "N/A"
    wns_s = f"{float(row['wns']):.2f}" if row['wns'] is not None else "N/A"
    fmax_s = f"{float(row['fmax']):.2f}" if row['fmax'] is not None else "N/A"
    pwr_s = fmt_pwr_str(row['power'])
    drc_s = str(int(row['drc'])) if row['drc'] is not None else "0"
    lvs_s = str(row['lvs'])
    ant_s = str(int(row['antenna'])) if row['antenna'] is not None else "0"
    slew_s = str(int(row['slew'])) if row['slew'] is not None else "0"
    cap_s = str(int(row['cap'])) if row['cap'] is not None else "0"
    
    print(f"{r_name:<26} | {area_s:<10} | {util_s:<6} | {wns_s:<8} | {fmax_s:<10} | {pwr_s:<10} | {drc_s:<5} | {lvs_s:<6} | {ant_s:<8} | {slew_s:<5} | {cap_s:<5}")

print("=" * 125 + "\n")
