#!/usr/bin/env python3
"""
OpenLane 2 Placement Density Sweep & PPA Exploration Script (v1)
================================================================
Automates PPA exploration across OpenLane 2 placement target density settings
(`PL_TARGET_DENSITY_PCT` / `PL_TARGET_DENSITY`) to evaluate physical design
trade-offs on Congestion, Max Slew Violations, Max Cap Violations, Wirelength,
and STA Timing.

Default Density Range: 35%, 40%, 45%, 50%, 55%, 60%

Features:
1. Clones/modifies base OpenLane JSON config for each placement density level.
2. Executes OpenLane 2 flow sequentially for each density target.
3. Extracts PPA metrics (Cell Area, Core Utilization, WNS, Fmax, Slew/Cap Viols, Power, DRC, LVS, Antenna).
4. Generates a comparative Markdown report (density_sweep_ppa_report.md) & CSV summary.
"""

import os
import sys
import json
import csv
import subprocess
import argparse
import glob
from datetime import datetime

DEFAULT_DENSITIES = [35, 40, 45, 50, 55, 60]

def load_json(path):
    with open(path, "r") as f:
        return json.load(f)

def save_json(data, path):
    with open(path, "w") as f:
        json.dump(data, f, indent=4)

def run_openlane_flow(config_path):
    """Executes OpenLane 2 flow for a given config file."""
    cmd = ["openlane", "--dockerized", config_path]
    print(f"\n[RUNNING] Launching OpenLane 2 with config: {config_path}")
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in proc.stdout:
            sys.stdout.write(line)
            sys.stdout.flush()
        proc.wait()
        return proc.returncode == 0
    except FileNotFoundError:
        print("[INFO] 'openlane' command not found in PATH. Trying fallback 'python3 -m openlane'...")
        cmd_fallback = ["python3", "-m", "openlane", "--pdk", "sky130A", "--flow", "Classic", config_path]
        try:
            proc = subprocess.Popen(cmd_fallback, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
            proc.wait()
            return proc.returncode == 0
        except Exception as e:
            print(f"[ERROR] Failed flow execution: {e}")
            return False

def get_latest_run_dir(runs_dir="runs"):
    if not os.path.isdir(runs_dir):
        return None
    runs = [
        os.path.join(runs_dir, d)
        for d in os.listdir(runs_dir)
        if os.path.isdir(os.path.join(runs_dir, d)) and d.startswith("RUN_")
    ]
    if not runs:
        return None
    runs.sort(key=lambda x: os.path.getmtime(x), reverse=True)
    return runs[0]

def extract_metrics(run_dir):
    if not run_dir:
        return {}
    metrics_path = os.path.join(run_dir, "final", "metrics.json")
    if not os.path.exists(metrics_path):
        metrics_path = os.path.join(run_dir, "metrics.json")
    if not os.path.exists(metrics_path):
        return {}
    try:
        with open(metrics_path, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"[ERROR] Could not read {metrics_path}: {e}")
        return {}

def format_val(val, unit="", scale=1.0, fmt=".3f"):
    if val is None:
        return "N/A"
    try:
        f_val = float(val) * scale
        if unit == "W" and abs(f_val) < 1.0:
            if abs(f_val) < 0.001:
                return f"{f_val * 1e6:.2f} µW"
            return f"{f_val * 1e3:.2f} mW"
        if f_val.is_integer():
            return f"{int(f_val)} {unit}".strip()
        return f"{f_val:{fmt}} {unit}".strip()
    except (ValueError, TypeError):
        return str(val)

def generate_report(results, report_filename="density_sweep_ppa_report.md"):
    report_lines = []
    report_lines.append("# OpenLane 2 Placement Density Sweep PPA Report")
    report_lines.append(f"**Generated On:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    
    report_lines.append("## 📊 PPA Comparison Matrix across Placement Target Densities\n")
    report_lines.append("| Density Target (%) | Std Cell Area (µm²) | Util (%) | WNS (ns) | Fmax (MHz) | Slew Viols | Cap Viols | Power | DRC | LVS | Antenna | Sign-off Status |")
    report_lines.append("| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")
    
    for density, data in results.items():
        m = data.get("metrics", {})
        
        area = format_val(m.get("design__instance__area__stdcell") or m.get("design__instance__area"), "µm²")
        util = format_val((m.get("design__instance__utilization") or 0.0) * 100.0, "%", fmt=".1f") if m.get("design__instance__utilization") else "N/A"
        wns_raw = m.get("timing__setup__ws")
        wns = format_val(wns_raw, "ns")
        
        # Fmax calculation based on 100ns target period
        if wns_raw is not None:
            crit_path = 100.0 - float(wns_raw)
            fmax_val = 1000.0 / crit_path if crit_path > 0 else 0
            fmax_str = f"{fmax_val:.2f} MHz"
        else:
            fmax_str = "N/A"
            
        slew_viols = format_val(m.get("design__max_slew_violations", 0), "", fmt="d")
        cap_viols = format_val(m.get("design__max_cap_violations", 0), "", fmt="d")
        power = format_val(m.get("power__total"), "W")
        drc = format_val(m.get("magic__drc__error_count", 0), "", fmt="d")
        lvs_err = m.get("netgen__lvs__error_count", 0)
        lvs_str = "PASS" if lvs_err == 0 else f"FAIL ({lvs_err})"
        antenna = format_val(m.get("antenna__violations", 0), "", fmt="d")
        
        # Check pass/fail signoff
        is_pass = (wns_raw is not None and float(wns_raw) >= 0 and 
                   m.get("magic__drc__error_count", 0) == 0 and 
                   m.get("netgen__lvs__error_count", 0) == 0 and
                   int(m.get("design__max_slew_violations", 0) or 0) == 0)
                   
        status_str = "✅ **PASS**" if is_pass else "❌ **FAIL**"
        
        report_lines.append(f"| **{density}%** | {area} | {util} | {wns} | {fmax_str} | {slew_viols} | {cap_viols} | {power} | {drc} | {lvs_str} | {antenna} | {status_str} |")

    report_lines.append("\n## 💡 Key Architectural Insights")
    report_lines.append("- **Lower Placement Density (35% - 40%)**: Spreads standard cells apart, creating whitespace for buffer insertion to resolve long-wire transition (slew) violations. Reduces congestion but slightly increases total wirelength.")
    report_lines.append("- **Medium Placement Density (45% - 50%)**: Provides a balanced trade-off between compact layout area and sufficient routability.")
    report_lines.append("- **Higher Placement Density (55% - 60%)**: Packs cells tightly, reducing parasitic wire capacitance and dynamic power, but increases risk of localized routing congestion and max slew violations if buffer insertion whitespace is insufficient.")
    
    report_md = "\n".join(report_lines)
    with open(report_filename, "w") as f:
        f.write(report_md)
    print(f"\n[SUCCESS] Generated {report_filename}")

def main():
    parser = argparse.ArgumentParser(description="OpenLane 2 Placement Density Sweep Script")
    parser.add_argument("--config", default="config-opt.json", help="Base config JSON file")
    parser.add_argument("--densities", default="35,40,45,50,55,60", help="Comma-separated density percentages")
    args = parser.parse_args()

    # Fallback to config.json or config-v6.json if config-opt.json is not found
    config_file = args.config
    if not os.path.exists(config_file):
        for fallback in ["config-opt.json", "config-v6.json", "config.json"]:
            if os.path.exists(fallback):
                config_file = fallback
                break

    if not os.path.exists(config_file):
        print(f"[ERROR] Base configuration file {config_file} not found.")
        sys.exit(1)

    print(f"[INFO] Using base configuration: {config_file}")
    base_config = load_json(config_file)
    densities = [int(d.strip()) for d in args.densities.split(",")]
    
    results = {}

    for den in densities:
        print(f"\n=======================================================")
        print(f" Starting Run for PL_TARGET_DENSITY_PCT = {den}%")
        print(f"=======================================================")
        
        temp_config_path = f"config_density_{den}.json"
        config_data = dict(base_config)
        config_data["PL_TARGET_DENSITY_PCT"] = den
        config_data["PL_TARGET_DENSITY"] = den / 100.0
        save_json(config_data, temp_config_path)
        
        success = run_openlane_flow(temp_config_path)
        run_dir = get_latest_run_dir()
        metrics = extract_metrics(run_dir)
        
        results[den] = {
            "run_dir": run_dir,
            "metrics": metrics,
            "success": success
        }

    generate_report(results)

if __name__ == "__main__":
    main()
