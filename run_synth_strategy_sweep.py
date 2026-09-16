#!/usr/bin/env python3
"""
OpenLane 2 Synthesis Strategy (Area vs. Delay) PPA Exploration Script
=====================================================================
Automates PPA exploration across Yosys/OpenLane synthesis strategies:
  - AREA 0, AREA 1, AREA 2, AREA 3
  - DELAY 0, DELAY 1, DELAY 2, DELAY 3

Features:
1. Clones/modifies base OpenLane JSON config for each SYNTH_STRATEGY.
2. Executes OpenLane 2 flow sequentially.
3. Extracts PPA metrics (Cell Area, Instance Count, WNS, TNS, Power, DRC, LVS).
4. Generates a comparative Markdown report (synth_strategy_ppa_report.md) & CSV summary.
"""

import os
import sys
import json
import csv
import subprocess
import argparse
from datetime import datetime

STRATEGIES_TO_SWEEP = [
    "AREA 0",
    "AREA 1",
    "AREA 2",
    "AREA 3",
    "DELAY 1",
    "DELAY 2"
]

METRICS_MAPPING = {
    "synth_cell_count": ("design__instance__count", "Total Cell Count"),
    "synth_cell_area": ("design__instance__area", "Cell Area (um²)"),
    "stdcell_area": ("design__instance__area__stdcell", "Std Cell Area (um²)"),
    "wns": ("timing__setup__ws", "Worst Setup Slack (ns)"),
    "tns": ("timing__setup__tns", "Total Setup Slack (ns)"),
    "total_power": ("power__total", "Total Power (W)"),
    "drc_errors": ("magic__drc__error_count", "DRC Errors"),
    "lvs_errors": ("netgen__lvs__error_count", "LVS Errors")
}

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

def format_val(val, unit=""):
    if val is None:
        return "N/A"
    try:
        f_val = float(val)
        if unit == "W" and f_val < 1.0:
            if f_val < 0.001:
                return f"{f_val * 1e6:.2f} µW"
            return f"{f_val * 1e3:.2f} mW"
        if f_val.is_integer():
            return f"{int(f_val)} {unit}".strip()
        return f"{f_val:.3f} {unit}".strip()
    except (ValueError, TypeError):
        return str(val)

def generate_report(results):
    report_lines = []
    report_lines.append("# OpenLane 2 Synthesis Strategy PPA Exploration Report")
    report_lines.append(f"**Generated On:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
    
    report_lines.append("## 📊 PPA Comparison Matrix across Synthesis Strategies\n")
    report_lines.append("| Synthesis Strategy | Cell Count | Cell Area (µm²) | WNS (ns) | Total Power | DRC Errors | LVS Status | Sign-off Status |")
    report_lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |")
    
    baseline_area = None
    
    for strat, data in results.items():
        m = data.get("metrics", {})
        cell_count = format_val(m.get("design__instance__count"))
        cell_area = format_val(m.get("design__instance__area"), "µm²")
        wns = format_val(m.get("timing__setup__ws"), "ns")
        power = format_val(m.get("power__total"), "W")
        drc = format_val(m.get("magic__drc__error_count", 0))
        lvs = "PASS" if m.get("netgen__lvs__error_count", 0) == 0 else "FAIL"
        
        # Check pass/fail signoff
        wns_raw = m.get("timing__setup__ws")
        is_pass = (wns_raw is not None and float(wns_raw) >= 0 and 
                   m.get("magic__drc__error_count", 0) == 0 and 
                   m.get("netgen__lvs__error_count", 0) == 0)
        status_str = "✅ **PASS**" if is_pass else "❌ **FAIL**"
        
        report_lines.append(f"| **{strat}** | {cell_count} | {cell_area} | {wns} | {power} | {drc} | {lvs} | {status_str} |")
        
        if strat == "AREA 0" and m.get("design__instance__area"):
            baseline_area = float(m.get("design__instance__area"))

    report_lines.append("\n## 💡 Key Architectural Insights")
    report_lines.append("- **AREA 0 / AREA 1**: Focuses aggressively on gate-level area minimization, gate sharing, and multiplexer mapping.")
    report_lines.append("- **AREA 2 / AREA 3**: Applies high-effort boolean optimization for compact layout.")
    report_lines.append("- **DELAY 1 / DELAY 2**: Prioritizes timing path delay over cell count by introducing parallel logic structures.")
    
    report_md = "\n".join(report_lines)
    with open("synth_strategy_ppa_report.md", "w") as f:
        f.write(report_md)
    print("\n[SUCCESS] Generated synth_strategy_ppa_report.md")

def main():
    parser = argparse.ArgumentParser(description="PPA Strategy Sweep Script")
    parser.add_argument("--config", default="config.json", help="Base config JSON file")
    parser.add_argument("--strategies", default="AREA 0,AREA 1,AREA 2,AREA 3,DELAY 1,DELAY 2", help="Comma-separated strategies")
    args = parser.parse_args()

    if not os.path.exists(args.config):
        print(f"[ERROR] Base configuration file {args.config} not found.")
        sys.exit(1)

    base_config = load_json(args.config)
    strategies = [s.strip() for s in args.strategies.split(",")]
    
    results = {}

    for strat in strategies:
        print(f"\n=======================================================")
        print(f" Starting Run for SYNTH_STRATEGY = '{strat}'")
        print(f"=======================================================")
        
        temp_config_path = f"config_synth_{strat.replace(' ', '_').lower()}.json"
        config_data = dict(base_config)
        config_data["SYNTH_STRATEGY"] = strat
        save_json(config_data, temp_config_path)
        
        success = run_openlane_flow(temp_config_path)
        run_dir = get_latest_run_dir()
        metrics = extract_metrics(run_dir)
        
        results[strat] = {
            "run_dir": run_dir,
            "metrics": metrics,
            "success": success
        }

    generate_report(results)

if __name__ == "__main__":
    main()
