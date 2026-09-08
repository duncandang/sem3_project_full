# MAX30102 PPG to UART ASIC/FPGA Processing Pipeline

This repository contains the complete, highly modular, and synthesizable RTL Verilog design and physical implementation configuration files for a real-time photoplethysmogram (PPG) data acquisition system. The design functions as a bridge that reads raw Red and Infrared (IR) light transmission data from a **MAX30102** sensor via an **I2C Master**, buffers the streaming traffic using a synchronous **FIFO buffer** to prevent overrun, packetizes the bytes, and transmits them over a **UART transmitter** to a host PC.

The design is optimized for both **ASIC (RTL-to-GDSII using OpenLane 2)** and **FPGA (Vivado for Basys 3)**, utilizing conditional compilation directives to manage physical I/O constraints dynamically.

---

## 🗺️ System Architecture

```
                       +-------------------------------------------------------------+
                       |                       TOP_MODULE (ASIC/FPGA)                |
                       |                                                             |
                       |   +-----------------------+     +-------------+   +-------+ |
                       |   |  MAX30102_CONTROLLER  |     | FIFO_BUFFER |   |UART_TX| |
  MAX30102 Sensor <===>|   | (I2C Master + Config) |====>| (16-Deep)   |==>| (8N1) |===> UART (TX)
   (SDA/SCL Bus)       |   |                       |     |             |   |       | |  (115200 Baud)
                       |   +-----------------------+     +-------------+   +-------+ |
                       |       | led_blink                      |              |     |
                       +-------v--------------------------------v--------------v-----+
                               | (ifdef FPGA)                   |              |
                            LED[0]                           LED[2]          LED[1]
                         (Read Success)                  (I2C Error)     (UART Active)
```

The hardware pipeline operates as follows:
1. **Sensor Configuration & Polling**: Upon reset, the system configures the MAX30102's registers (Mode, SpO2, and LED pulse amplitudes) and polls the sensor at a stable **100 Hz** sampling rate.
2. **I2C Byte Transfer**: A custom I2C master drives the serial interface. Bidirectional pins are separated on-chip to prevent internal tri-state driver issues during ASIC cell mapping.
3. **Data Buffering (FIFO)**: The sensor transmits a 6-byte burst (3 bytes Red, 3 bytes IR) for each sample. A 16-deep synchronous FIFO absorbs this burst to bridge the speed gap between the fast I2C read cycle and the slower UART serialization.
4. **Packet Framing**: The top-level controller reads bytes from the FIFO, wraps them in a secure packet protocol, and forwards them to the UART module.

---

## 📦 Repository Structure

The project files are organized to support both logic simulation and physical design exploration:

```text
├── config-v2.json              # Warning-free OpenLane 2 configuration
├── pin_order-v2.cfg            # Physical placement boundaries for ASIC pads (No LEDs)
├── requirements.txt            # Python dependencies for host utility and PPA tools
├── run_and_compare_fifo-v2.py  # Automation tool for sweeps of FIFO depths (8, 16, 32, 64)
├── src/                        # RTL Verilog source directory
│   ├── top_module.v            # Top-level wrapper with conditional compilation
│   ├── max30102_controller.v   # FSM controller and register config for MAX30102
│   ├── i2c_master.v            # Byte-level I2C master core (Tri-state separated)
│   ├── fifo_buffer.v           # 16-deep synchronous FIFO data buffer
│   └── uart_tx.v               # 115200 Baud UART transmitter (8N1 frame format)
└── test/                       # Verification scripts and testbenches
    ├── fifo_tb.v               # Self-checking testbench for FIFO operations
    └── host_monitor.py         # Real-time PPG wave visualizer (Matplotlib/PySerial)
```

---

## 📥 Data Frame Protocol

To ensure perfect packet alignment on the host machine, raw 24-bit Red and 24-bit IR samples are packetized into an 8-byte frame bounded by custom sync tokens:

| Byte Index | Field Name | Description | Value |
| :---: | :--- | :--- | :---: |
| **0** | **Header** | Sync byte indicating start of packet | `0xAA` |
| **1** | **Red[23:16]** | LED Red channel Most Significant Byte (MSB) | *Variable* |
| **2** | **Red[15:8]** | LED Red channel Middle Byte (MID) | *Variable* |
| **3** | **Red[7:0]** | LED Red channel Least Significant Byte (LSB) | *Variable* |
| **4** | **IR[23:16]** | Infrared channel Most Significant Byte (MSB) | *Variable* |
| **5** | **IR[15:8]** | Infrared channel Middle Byte (MID) | *Variable* |
| **6** | **IR[7:0]** | Infrared channel Least Significant Byte (LSB) | *Variable* |
| **7** | **Footer** | Sync byte indicating end of packet | `0x55` |

---

## 🛠️ Cross-Platform Target Setup

To support multiple hardware deployment styles, the top-level module uses compiler macros to decouple the physical target environments:

### 🚀 Target A: ASIC Implementation (OpenLane 2)
For a warning-free physical compilation, the physical LED ports are removed from the top-level port list, preventing OpenROAD custom pin-placer warnings.

1. Ensure your Python virtual environment is active:
   ```bash
   source ~/openlane2-venv/bin/activate
   ```
2. Launch the standard classic RTL-to-GDSII implementation flow:
   ```bash
   openlane --dockerized config-v2.json
   ```
3. To visually inspect your floorplan, placement density, or final routed wiring, run the OpenROAD GUI:
   ```bash
   openlane --dockerized --flow OpenInOpenROAD resolved.json
   ```

### 🎛️ Target B: FPGA Verification (Basys 3)
For physically testing and debugging on an FPGA, configure your synthesis environment to compile the status indicator LEDs:

1. In your **Xilinx Vivado** project settings, add `-verilog_define FPGA` to your synthesis settings (or define `` `define FPGA `` in your top-level RTL).
2. Wire the bidirectional I2C lines (`scl`, `sda`), serial output (`uart_txd`), and clock/reset pins.
3. Map the three output status signals to your physical board LEDs:
   *   `led[0]` (Sample Acquisition Success blinker)
   *   `led[1]` (UART Transmitter Active)
   *   `led[2]` (I2C Communication NACK Error indicator)

---

## 📈 ASIC Design Space Exploration (FIFO sweeps)

An advanced design exploration utility is included to determine the most optimal buffer size:
```bash
python3 run_and_compare_fifo-v2.py --rtl src/fifo_buffer.v --config config-v2.json --depths 8,16,32,64 --baseline 16
```
This tool automatically:
1. Sweeps through FIFO sizes of **8, 16, 32, and 64 bytes**.
2. Evaluates physical sign-off compliance (Setup timing Worst Negative Slack \\(\ge 0\text{ ns}\\), zero DRC/LVS/Antenna errors).
3. Ranks valid layouts to recommend the best balanced architecture based on area, power, and buffering requirements.

---

## 💻 Python Host Visualizer

A real-time Python script is available to receive packets over your USB-to-UART bridge and draw real-time PPG/ECG waveforms.

1. Install Python dependencies:
   ```bash
   pip install -r requirements.txt
   ```
2. Run the host visualizer (adjust COM port for Windows or `/dev/ttyUSB` for Linux):
   ```bash
   python3 test/host_monitor.py --port COM3 --baud 115200
   ```
