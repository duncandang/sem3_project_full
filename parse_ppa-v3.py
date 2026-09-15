import os
import glob
import json
import re

# Find the latest RUN directory in runs/
run_dirs = sorted(glob.glob("runs/RUN_*"), key=os.path.getmtime, reverse=True)
if not run_dirs:
    print("[ERROR] No runs/ directory found in the current path!")
    exit(1)

latest_run = run_dirs[0]  # Safe indexing: grabs the most recent run folder
metrics_path = os.path.join(latest_run, "final", "metrics.json")

print("=" * 65)
print(f"   OPENLANE 2 PPA & SIGNOFF REPORT (v3)")
print(f"   Latest Run: {os.path.basename(latest_run)}")
print("=" * 65)

data = {}
if os.path.exists(metrics_path):
    with open(metrics_path, "r") as f:
        data = json.load(f)

def get_val(keys):
    """Find first non-None value across multiple potential keys."""
    if isinstance(keys, str):
        keys = [keys]
    for k in keys:
        if k in data and data[k] is not None:
            return data[k]
    return None

# --- 1. AREA & UTILIZATION CALCULATION ---
std_cell_area = get_val(["design__instance__area", "design__instance__area__stdcell"])
die_area = get_val(["design__die__area"])
core_area = get_val(["design__core__area"])
cell_count = get_val(["design__instance__count"])
raw_util = get_val(["design__instance__utilization", "design__core__utilization"])

# Exact mathematical calculation of Core Utilization (%)
utilization_pct = None
if std_cell_area is not None and core_area is not None and float(core_area) > 0:
    utilization_pct = (float(std_cell_area) / float(core_area)) * 100.0
elif raw_util is not None:
    u_val = float(raw_util)
    utilization_pct = u_val * 100.0 if u_val <= 1.0 else u_val

# --- 2. TIMING METRICS ---
wns = get_val(["timing__setup__ws", "timing__setup__worst_slack"])
tns = get_val(["timing__setup__tns"])
whs = get_val(["timing__hold__ws", "timing__hold__worst_slack"])
clk_period = get_val(["clock__period"]) or 100.0  # default fallback 100ns

# Design Rule Violations (Slew & Cap)
max_slew_viols = get_val([
    "checker__slew__violations", "checker__max_slew_violations", 
    "design__max_slew_violations", "timing__slew__violations"
])
max_cap_viols = get_val([
    "checker__cap__violations", "checker__max_cap_violations", 
    "design__max_cap_violations", "timing__cap__violations"
])

# Fallback check for Max Slew / Max Cap from step logs if missing in JSON
if max_slew_viols is None:
    slew_logs = glob.glob(f"{latest_run}/*maxslew*/*.log") + glob.glob(f"{latest_run}/*slew*/*.log")
    for slog in slew_logs:
        try:
            content = open(slog).read()
            if "No max slew violations found" in content or "0 max slew violations" in content:
                max_slew_viols = 0
                break
            match = re.search(r'(\d+)\s+max slew violation', content, re.IGNORECASE)
            if match:
                max_slew_viols = int(match.group(1))
                break
        except Exception:
            pass

if max_cap_viols is None:
    cap_logs = glob.glob(f"{latest_run}/*maxcap*/*.log") + glob.glob(f"{latest_run}/*cap*/*.log")
    for clog in cap_logs:
        try:
            content = open(clog).read()
            if "No max cap violations found" in content or "0 max cap violations" in content:
                max_cap_viols = 0
                break
            match = re.search(r'(\d+)\s+max cap violation', content, re.IGNORECASE)
            if match:
                max_cap_viols = int(match.group(1))
                break
        except Exception:
            pass

# --- 3. POWER METRICS ---
p_internal = get_val(["power__internal"])
p_switching = get_val(["power__switching"])
p_leakage = get_val(["power__leakage"])
p_total = get_val(["power__total"])
p_dynamic = get_val(["power__dynamic"])

if p_dynamic is None and p_internal is not None and p_switching is not None:
    try:
        p_dynamic = float(p_internal) + float(p_switching)
    except:
        pass

# Fallback: Parse STA report if JSON power keys are missing or null
if p_total is None or p_leakage is None:
    sta_reports = (
        glob.glob(f"{latest_run}/*stapostpnr*/power.rpt")
        + glob.glob(f"{latest_run}/*stapostpnr*/sta.log")
        + glob.glob(f"{latest_run}/*sta*/*.log")
    )
    for rpt in sta_reports:
        try:
            with open(rpt, "r") as f:
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

# Formatting helper functions
def fmt_num(val, unit="", scale=1.0, fmt=".3f"):
    if val is None:
        return "N/A"
    try:
        return f"{float(val) * scale:{fmt}} {unit}".strip()
    except:
        return str(val)

def fmt_pwr(val):
    if val is None:
        return "N/A"
    try:
        v = float(val)
        if abs(v) < 1e-3:
            return f"{v * 1e6:.3f} uW"
        else:
            return f"{v * 1e3:.3f} mW"
    except:
        return str(val)

# --- 4. PHYSICAL SIGNOFF ---
magic_drc = get_val(["magic__drc__error_count", "magic__drc_error__count", "checker__drc__error_count"])
klayout_drc = get_val(["klayout__drc__error_count", "klayout__drc_error__count"])
lvs_errors = get_val(["netgen__lvs__error_count", "netgen__lvs_error__count", "checker__lvs"])
antenna_violations = get_val(["antenna__violations", "checker__antenna_violations"])

# Fallback LVS log check
lvs_status = "N/A"
if lvs_errors is not None:
    lvs_status = "PASS (0 Errors)" if str(lvs_errors) == "0" else f"{lvs_errors} Errors"
else:
    lvs_logs = glob.glob(f"{latest_run}/*lvs*/*.log")
    for llog in lvs_logs:
        try:
            if "Circuits match uniquely" in open(llog).read():
                lvs_status = "PASS (Circuits match uniquely)"
                break
        except:
            pass

print("\n1. AREA & UTILIZATION")
print(f"   - Standard Cell Area : {fmt_num(std_cell_area, 'um²')}")
print(f"   - Die Area           : {fmt_num(die_area, 'um²')}")
print(f"   - Core Area          : {fmt_num(core_area, 'um²')}")
print(f"   - Core Utilization   : {fmt_num(utilization_pct, '%', fmt='.2f')}")
print(f"   - Total Cell Count   : {fmt_num(cell_count, 'cells', fmt='d')}")

print("\n2. TIMING & DESIGN RULE PERFORMANCE")
print(f"   - Worst Setup Slack (WNS) : {fmt_num(wns, 'ns')}")
print(f"   - Total Setup Slack (TNS) : {fmt_num(tns, 'ns')}")
print(f"   - Worst Hold Slack (WHS)  : {fmt_num(whs, 'ns')}")
if wns is not None:
    try:
        f_max = 1000.0 / (float(clk_period) - float(wns))
        print(f"   - Estimated Max Freq(Fmax): {f_max:.2f} MHz")
    except:
        pass
print(f"   - Max Slew Violations     : {fmt_num(max_slew_viols, 'violations', fmt='d')}")
print(f"   - Max Cap Violations      : {fmt_num(max_cap_viols, 'violations', fmt='d')}")

print("\n3. POWER CONSUMPTION")
print(f"   - Internal Power     : {fmt_pwr(p_internal)}")
print(f"   - Switching Power    : {fmt_pwr(p_switching)}")
print(f"   - Dynamic Power      : {fmt_pwr(p_dynamic)}")
print(f"   - Leakage Power      : {fmt_pwr(p_leakage)}")
print(f"   - Total Power        : {fmt_pwr(p_total)}")

print("\n4. PHYSICAL SIGNOFF STATUS")
print(f"   - Magic DRC Errors   : {fmt_num(magic_drc, 'errors', fmt='d')}")
print(f"   - KLayout DRC Errors : {fmt_num(klayout_drc, 'errors', fmt='d')}")
print(f"   - Netgen LVS Status  : {lvs_status}")
print(f"   - Antenna Violations : {fmt_num(antenna_violations, 'violations', fmt='d')}")
print("=" * 65)
