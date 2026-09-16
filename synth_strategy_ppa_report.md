# OpenLane 2 Synthesis Strategy PPA Exploration Report
**Generated On:** 2026-09-16 12:25:38

## 📊 PPA Comparison Matrix across Synthesis Strategies

| Synthesis Strategy | Cell Count | Cell Area (µm²) | WNS (ns) | Total Power | DRC Errors | LVS Status | Sign-off Status |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **AREA 0** | 16837 | 109693 µm² | 75.672 ns | 1.07 mW | 0 | PASS | ✅ **PASS** |
| **AREA 1** | 16746 | 109470 µm² | 75.613 ns | 1.08 mW | 0 | PASS | ✅ **PASS** |
| **AREA 2** | 16947 | 109989 µm² | 75.918 ns | 1.08 mW | 0 | PASS | ✅ **PASS** |
| **AREA 3** | 20990 | 114557 µm² | 75.941 ns | 1.10 mW | 0 | PASS | ✅ **PASS** |
| **DELAY 1** | 21852 | 140073 µm² | 76.051 ns | 1.11 mW | 0 | PASS | ✅ **PASS** |
| **DELAY 2** | 21308 | 138568 µm² | 75.805 ns | 1.07 mW | 0 | PASS | ✅ **PASS** |

## 💡 Key Architectural Insights
- **AREA 0 / AREA 1**: Focuses aggressively on gate-level area minimization, gate sharing, and multiplexer mapping.
- **AREA 2 / AREA 3**: Applies high-effort boolean optimization for compact layout.
- **DELAY 1 / DELAY 2**: Prioritizes timing path delay over cell count by introducing parallel logic structures.