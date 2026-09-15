# Project Sem3: Integrated MAX30102 PPG Heart Rate & SpO2 ASIC & FPGA System

## 📌 Project Overview
- **Design Name**: `top_module` (ASIC Top) / `top_fpga` (FPGA Top Wrapper)
- **Application**: Fully integrated MAX30102 Photoplethysmogram (PPG) Pulse Oximeter & Heart Rate ($SpO_2\%$ and BPM) Processing System.
- **Target ASIC PDK**: SkyWater SKY130A (`sky130_fd_sc_hd`) via OpenLane 2 (Dockerized flow).
- **Target FPGA**: Digilent Basys 3 (Xilinx Artix-7 `XC7A35T-1CPG236C`) via Xilinx Vivado.

---

## 🏗️ System Architecture & Block Diagram

```
+-----------------------------------------------------------------------------------------+
|                                    FPGA / ASIC TOP                                      |
|                                                                                         |
|  +--------------------+     +-------------------+     +------------------+              |
|  | MAX30102 CONTROLLER|     | DUAL PPG FILTERS  |     | PEAK DETECTOR &  |              |
|  | - I2C Master       |---->| - Red AC/DC & PP  |---->|   BPM CALC       |              |
|  | - Sampling Timer   |     | - IR AC/DC & PP   |     +------------------+              |
|  +--------------------+     +-------------------+              |                        |
|            ^                          |                        v                        |
|            | (I2C)                    |               +------------------+              |
|            v                          +-------------->| SpO2 CALCULATOR  |              |
|     [MAX30102 Sensor]                                 +------------------+              |
|                                                                |                        |
|                                                                v                        |
|     +------------------+     +-------------------+    +------------------+              |
|     |  USB-UART TX     |<----|   FIFO BUFFER     |<---| 8-Byte Packet    |              |
|     |  (115200 Baud)   |     |   (16-byte Depth) |    | Framing FSM      |              |
|     +------------------+     +-------------------+    +------------------+              |
|               |                                                                         |
|               v                                                                         |
|         [PC / Python]                                                                   |
+-----------------------------------------------------------------------------------------+
```

### Module Breakdown
1. **`i2c_master.v`**: Standard I2C Master controller handling start/stop, byte reads/writes, ACK checking, and tristate `sda` line driving.
2. **`max30102_controller.v`**: FSM initializing MAX30102 sensor registers, triggering periodic sampling (200 Hz), and fetching 6-byte raw Red/IR FIFO samples.
3. **`ppg_filter_v4.v`**: Dual IIR/FIR filter pipeline separating raw Red/IR PPG signals into AC dynamic pulse and DC baseline levels, tracking peak-to-peak amplitudes ($AC_{pp}$).
4. **`peak_detector-v2.v`**: Adaptive threshold peak-to-peak interval tracker measuring Heart Rate in Beats Per Minute (BPM).
5. **`spo2_calculator-v2.v`**: Sequential division hardware calculating $R = \frac{AC_{Red}/DC_{Red}}{AC_{IR}/DC_{IR}}$ and mapping to $SpO_2\% = 104 - 17 \times R$.
6. **`fifo_buffer.v`**: 16-byte depth circular FIFO buffer bridging high-burst data packet framing to serial UART transmission.
7. **`uart_tx.v`**: 115200 Baud 8N1 UART transmitter module with glitch rejection.
8. **`top_module-v5.v`**: Full top-level ASIC module integrating the DSP and control units, packetizing data into an 8-byte frame (`0xAA -> Red_MSB -> Red_LSB -> IR_MSB -> IR_LSB -> BPM -> SpO2 -> 0x55`).
9. **`top_fpga.v`**: Top FPGA wrapper for Basys 3 board with 100MHz to 10MHz clock division and LED diagnostic status driving.

---

## 🛠️ OpenLane 2 ASIC Implementation Flow

### Project Configuration (`config.json` / `config-v6.json` to `config-v11.json`)
```json
{
    "DESIGN_NAME": "top_module",
    "VERILOG_FILES": [
        "dir::src/top_module-v5.v",
        "dir::src/ppg_filter_v4.v",
        "dir::src/spo2_calculator-v2.v",
        "dir::src/peak_detector-v2.v",
        "dir::src/i2c_master.v",
        "dir::src/max30102_controller.v",
        "dir::src/fifo_buffer.v",
        "dir::src/uart_tx.v"
    ],
    "CLOCK_PORT": "clk",
    "CLOCK_PERIOD": 100,
    "FP_CORE_UTIL": 40,
    "PL_TARGET_DENSITY_PCT": 45,
    "SYNTH_STRATEGY": "DELAY 1",
    "MAX_FANOUT_CONSTRAINT": 15,
    "FP_PIN_ORDER_CFG": "dir::pin_order-v2.cfg",
    "RUN_IRDROP_REPORT": true,
    "RUN_ANTENNA_REPAIR": true,
    "GRT_REPAIR_ANTENNAS": true,
    "DIODE_INSERTION_STRATEGY": 4,
    "PL_RESIZER_DESIGN_OPTIMIZATION": true,
    "PL_RESIZER_TIMING_OPTIMIZATION": true,
    "GLB_RESIZER_DESIGN_OPTIMIZATION": true,
    "GLB_RESIZER_TIMING_OPTIMIZATION": true
}
```

### ASIC Build & PPA Metrics Parsing
1. Run OpenLane 2 Docker container:
   ```bash
   openlane --dockerized config.json
   ```
2. Parse PPA and Physical Signoff results:
   ```bash
   python3 parse_ppa-v4.py
   ```

---

## 💻 Xilinx Vivado Step-by-Step FPGA Guide (Basys 3)

### Step 1: Create a New Vivado Project
1. Open **Xilinx Vivado** (2020.2 or newer).
2. Click **Create Project** $\rightarrow$ **Next**.
3. Set your **Project Name** (e.g., `max30102_ppg_fpga`) and select the project directory.
4. Select **RTL Project** and click **Next**.
5. **Select Target Device/Board**:
   - **Part**: `xc7a35tcpg236-1`
   - *(Or select **Basys 3** under the Boards tab)*.

### Step 2: Add Design Files & Constraints
1. Under **Flow Navigator** $\rightarrow$ **Add Sources** $\rightarrow$ **Add or create design sources**:
   - Add `top_fpga.v` *(Top wrapper containing 100MHz to 10MHz clock divider)*
   - Add `top_module-v5.v`
   - Add `max30102_controller.v`
   - Add `i2c_master.v`
   - Add `ppg_filter_v4.v`
   - Add `peak_detector-v2.v`
   - Add `spo2_calculator-v2.v`
   - Add `fifo_buffer.v`
   - Add `uart_tx.v`
2. Under **Add Sources** $\rightarrow$ **Add or create constraints**:
   - Add `constraint.xdc`
3. In the **Sources** pane, right-click `top_fpga.v` and choose **Set as Top**.

### Step 3: Enable the `FPGA` Macro (`define FPGA` (add flag before top_module-v5.v))
1. Open **Settings** $\rightarrow$ **Project Settings** $\rightarrow$ **Synthesis**.
2. Scroll to **Verilog Options** $\rightarrow$ **Verilog Define**.
3. Add `FPGA` to activate diagnostic LED mappings in ``ifdef FPGA` blocks.

### Step 4: Generate Bitstream
1. In the **Flow Navigator** panel, click **Generate Bitstream**.
2. Confirm to run **Synthesis** and **Implementation** sequentially.
3. Wait for compilation to complete (3–5 minutes).

### Step 5: Program Basys 3 Board
1. Connect the **Basys 3 board** via Micro-USB and turn ON the power switch.
2. Connect MAX30102 sensor to **Pmod Header JA** (Pin J1 for SDA, Pin J2 for SCL, VCC 3.3V, GND).
3. In Vivado **Flow Navigator** $\rightarrow$ **Open Hardware Manager** $\rightarrow$ **Open Target** $\rightarrow$ **Auto Connect**.
4. Right-click `xc7a35t_0` $\rightarrow$ **Program Device** $\rightarrow$ Select `top_fpga.bit` $\rightarrow$ Click **Program**.

---

## 📈 Real-Time Python Visualization
Run the provided Python script on your PC (`pyserial` + `matplotlib` on `COMx` port, 115200 Baud) to stream and view Red/IR PPG waveforms, Heart Rate (BPM), and $SpO_2\%$ live.
