import os
import glob
import json
import re
import sys

# Find all RUN directories in runs/ sorted by creation time (most recent first)
all_run_dirs = sorted(glob.glob("runs/RUN_*"), key=os.path.getmtime, reverse=True)
if not all_run_dirs:
    print("[ERROR] No runs/ directory found in the current path!")
    sys.exit(1)

# Select the last N runs (up to 6)
MAX_RUNS = 6
sweep_runs = all_run_dirs[:MAX_RUNS]

print("=" * 115)
print(f"   OPENLANE 2 PPA & SIGNOFF MULTI-RUN SWEEP REPORT (v4)")
print(f"   Analyzing the latest {len(sweep_runs)} run directories out of {len(all_run_dirs)} total")
print("=" * 115)

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

def parse_run(run_dir):
    metrics_path = os.path.join(run_dir, "final", "metrics.json")
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

    # Area & Utilization
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

    # Timing
    wns = get_val(["timing__setup__ws", "timing__setup__worst_slack"])
    tns = get_val(["timing__setup__tns"])
    whs = get_val(["timing__hold__ws", "timing__hold__worst_slack"])
    clk_period = get_val(["clock__period"]) or 10.0

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
            run_dir, ["slew", "maxslew"],
            [r"no max slew violations", r"0 max slew violation", r"max slew violations:\s*0"],
            [r"(\d+)\s+max slew violation", r"max slew violations:\s*(\d+)"]
        )
    if max_cap_viols is None:
        max_cap_viols = scan_logs_for_pattern(
            run_dir, ["cap", "maxcap"],
            [r"no max cap violations", r"0 max cap violation", r"max cap violations:\s*0"],
            [r"(\d+)\s+max cap violation", r"max cap violations:\s*(\d+)"]
        )
    if antenna_violations is None:
        antenna_violations = scan_logs_for_pattern(
            run_dir, ["antenna"],
            [r"no antenna violations", r"\*\s*antenna\s+passed", r"0 antenna violation"],
            [r"(\d+)\s+antenna violation", r"pin violations:\s*(\d+)"]
        )

    # Power
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
            glob.glob(f"{run_dir}/*stapostpnr*/power.rpt")
            + glob.glob(f"{run_dir}/*stapostpnr*/sta.log")
            + glob.glob(f"{run_dir}/*sta*/*.log")
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

    # Signoff
    magic_drc = get_val(["magic__drc__error_count", "magic__drc_error__count", "checker__drc__error_count"])
    klayout_drc = get_val(["klayout__drc__error_count", "klayout__drc_error__count"])
    lvs_errors = get_val(["netgen__lvs__error_count", "netgen__lvs_error__count", "checker__lvs"])

    lvs_status = "N/A"
    if lvs_errors is not None:
        lvs_status = "PASS" if str(lvs_errors) == "0" else f"{lvs_errors} Errs"
    else:
        lvs_logs = glob.glob(f"{run_dir}/*lvs*/*.log")
        for llog in lvs_logs:
            try:
                if "Circuits match uniquely" in open(llog, errors="ignore").read():
                    lvs_status = "PASS"
                    break
            except Exception:
                pass

    f_max = None
    if wns is not None:
        try:
            f_max = 1000.0 / (float(clk_period) - float(wns))
        except Exception:
            pass

    return {
        "run_name": os.path.basename(run_dir),
        "std_cell_area": std_cell_area,
        "die_area": die_area,
        "core_area": core_area,
        "cell_count": cell_count,
        "utilization_pct": utilization_pct,
        "wns": wns,
        "tns": tns,
        "whs": whs,
        "f_max": f_max,
        "max_slew_viols": max_slew_viols,
        "max_cap_viols": max_cap_viols,
        "antenna_violations": antenna_violations,
        "p_dynamic": p_dynamic,
        "p_leakage": p_leakage,
        "p_total": p_total,
        "magic_drc": magic_drc,
        "klayout_drc": klayout_drc,
        "lvs_status": lvs_status,
    }

def fmt_pwr(val):
    if val is None:
        return "N/A"
    try:
        v = float(val)
        if abs(v) < 1e-3:
            return f"{v * 1e6:.1f} uW"
        else:
            return f"{v * 1e3:.2f} mW"
    except Exception:
        return str(val)

def fmt_num(val, fmt=".2f"):
    if val is None:
        return "N/A"
    try:
        return f"{float(val):{fmt}}"
    except Exception:
        return str(val)

results = []
for idx, r_dir in enumerate(sweep_runs, 1):
    res = parse_run(r_dir)
    results.append(res)
    print(f"\n[RUN {idx}/{len(sweep_runs)}] {res['run_name']}")
    print(f"  Area        : {fmt_num(res['std_cell_area'])} um² | Cells: {fmt_num(res['cell_count'], 'd')} | Util: {fmt_num(res['utilization_pct'])}%")
    print(f"  Timing      : WNS: {fmt_num(res['wns'])} ns | Fmax: {fmt_num(res['f_max'])} MHz | Slew Viols: {fmt_num(res['max_slew_viols'], 'd')}")
    print(f"  Power       : Dyn: {fmt_pwr(res['p_dynamic'])} | Leak: {fmt_pwr(res['p_leakage'])} | Total: {fmt_pwr(res['p_total'])}")
    print(f"  Signoff     : DRC(Magic/KL): {fmt_num(res['magic_drc'], 'd')}/{fmt_num(res['klayout_drc'], 'd')} | LVS: {res['lvs_status']} | Ant: {fmt_num(res['antenna_violations'], 'd')}")

# Print Comparative Matrix Table
print("\n" + "=" * 115)
print("   COMPARATIVE PPA SWEEP MATRIX (LAST 6 RUNS)")
print("=" * 115)
header = f"{'Run Directory':<28} | {'Area(um²)':<10} | {'Util%':<6} | {'WNS(ns)':<8} | {'Fmax(MHz)':<10} | {'Power(Total)':<12} | {'DRC':<6} | {'LVS':<6}"
print(header)
print("-" * 115)

for r in results:
    run_str = r['run_name'][:27]
    area_str = fmt_num(r['std_cell_area'], ".1f")
    util_str = fmt_num(r['utilization_pct'], ".1f")
    wns_str = fmt_num(r['wns'], ".2f")
    fmax_str = fmt_num(r['f_max'], ".1f")
    pwr_str = fmt_pwr(r['p_total'])
    drc_str = fmt_num(r['magic_drc'], "d") if r['magic_drc'] is not None else "0"
    lvs_str = r['lvs_status']

    print(f"{run_str:<28} | {area_str:<10} | {util_str:<6} | {wns_str:<8} | {fmax_str:<10} | {pwr_str:<12} | {drc_str:<6} | {lvs_str:<6}")

print("=" * 115)
