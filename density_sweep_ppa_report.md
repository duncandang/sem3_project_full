# OpenLane 2 Placement Density Sweep PPA Report
**Generated On:** 2026-09-17 11:58:53

## 📊 PPA Comparison Matrix across Placement Target Densities

| Density Target (%) | Std Cell Area (µm²) | Util (%) | WNS (ns) | Fmax (MHz) | Slew Viols | Cap Viols | Power | DRC | LVS | Antenna | Sign-off Status |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **35%** | N/A | N/A | N/A | N/A | 0 | 0 | N/A | 0 | PASS | 0 | ❌ **FAIL** |
| **40%** | N/A | N/A | N/A | N/A | 0 | 0 | N/A | 0 | PASS | 0 | ❌ **FAIL** |
| **45%** | 104363 µm² | 44.0 % | 75.331 ns | 40.54 MHz | 0 | 0 | 1.11 mW | 0 | PASS | 0 | ✅ **PASS** |
| **50%** | 103541 µm² | 43.7 % | 75.918 ns | 41.53 MHz | 0 | 0 | 1.06 mW | 0 | PASS | 0 | ✅ **PASS** |
| **55%** | 103108 µm² | 43.5 % | 74.998 ns | 40.00 MHz | 0 | 0 | 1.03 mW | 0 | PASS | 0 | ✅ **PASS** |
| **60%** | 103526 µm² | 43.7 % | 75.604 ns | 40.99 MHz | 0 | 0 | 1.06 mW | 0 | PASS | 0 | ✅ **PASS** |

## 💡 Key Architectural Insights
- **Lower Placement Density (35% - 40%)**: Spreads standard cells apart, creating whitespace for buffer insertion to resolve long-wire transition (slew) violations. Reduces congestion but slightly increases total wirelength.
- **Medium Placement Density (45% - 50%)**: Provides a balanced trade-off between compact layout area and sufficient routability.
- **Higher Placement Density (55% - 60%)**: Packs cells tightly, reducing parasitic wire capacitance and dynamic power, but increases risk of localized routing congestion and max slew violations if buffer insertion whitespace is insufficient.