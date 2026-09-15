#!/usr/bin/env python3
"""
===============================================================================
Real-Time PPG Waveform, Heart Rate (BPM) & SpO2 Visualizer
Project Sem3: MAX30102 Oximeter & Vital Signs Processing System
===============================================================================

Communicates via USB-UART (115200 Baud, 8N1) with the FPGA Basys 3 board or
ASIC chip. Parses the 8-byte framing protocol and displays live plots of:
  1. Red PPG AC Waveform
  2. Infrared (IR) PPG AC Waveform
  3. Real-Time Heart Rate (BPM)
  4. Real-Time Oxygen Saturation (SpO2 %)

Packet Structure (8 bytes):
  Byte 0: 0xAA (Header)
  Byte 1: Red_AC[15:8] (MSB)
  Byte 2: Red_AC[7:0]  (LSB)
  Byte 3: IR_AC[15:8]  (MSB)
  Byte 4: IR_AC[7:0]   (LSB)
  Byte 5: BPM (0-255)
  Byte 6: SpO2 % (0-100)
  Byte 7: 0x55 (Footer)
===============================================================================
"""

import sys
import time
from collections import deque
import matplotlib.pyplot as plt
import matplotlib.animation as animation

try:
    import serial
    import serial.tools.list_ports
    SERIAL_AVAILABLE = True
except ImportError:
    SERIAL_AVAILABLE = False
    print("[WARNING] 'pyserial' library not found. Running in demo/simulation mode.")

# --- System Configuration ---
DEFAULT_PORT = 'COM3'      # Update to '/dev/ttyUSB0' or '/dev/ttyACM0' on Linux
BAUD_RATE = 115200
MAX_SAMPLES = 200          # Number of points to display on chart (~2 seconds at 100Hz)

# --- Real-Time Data Buffers ---
red_wave = deque(maxlen=MAX_SAMPLES)
ir_wave = deque(maxlen=MAX_SAMPLES)
bpm_history = deque(maxlen=20)
spo2_history = deque(maxlen=20)

# Pre-fill buffers with zeros
for _ in range(MAX_SAMPLES):
    red_wave.append(0)
    ir_wave.append(0)

# --- Serial Port Initialization ---
ser = None
if SERIAL_AVAILABLE:
    target_port = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PORT
    try:
        ser = serial.Serial(target_port, BAUD_RATE, timeout=0.1)
        print(f"[SUCCESS] Connected to USB-UART on {target_port} at {BAUD_RATE} Baud.")
    except Exception as e:
        print(f"[WARNING] Could not open port '{target_port}': {e}")
        print("[INFO] Available serial ports on system:")
        ports = serial.tools.list_ports.comports()
        if ports:
            for p in ports:
                print(f"  - {p.device}: {p.description}")
        else:
            print("  - None detected. Make sure Basys 3 USB cable is connected.")

# --- Matplotlib GUI Setup ---
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 6), sharex=True)
fig.suptitle('Project Sem3: Real-Time MAX30102 PPG & Vital Signs Monitor', fontsize=14, fontweight='bold')

# Subplot 1: Red Channel PPG Waveform
line_red, = ax1.plot(range(MAX_SAMPLES), red_wave, color='crimson', linewidth=1.5, label='Red PPG AC')
ax1.set_ylabel('AC Amplitude', fontsize=10)
ax1.set_title('Red LED Filtered PPG Signal')
ax1.grid(True, linestyle='--', alpha=0.6)
ax1.legend(loc='upper right')

# Subplot 2: IR Channel PPG Waveform
line_ir, = ax2.plot(range(MAX_SAMPLES), ir_wave, color='darkred', linewidth=1.5, label='IR PPG AC')
ax2.set_xlabel('Sample Window (Recent 200 Samples)', fontsize=10)
ax2.set_ylabel('AC Amplitude', fontsize=10)
ax2.set_title('Infrared LED Filtered PPG Signal')
ax2.grid(True, linestyle='--', alpha=0.6)
ax2.legend(loc='upper right')

# Live Vital Signs Metric Text Boxes
text_bpm = fig.text(0.18, 0.02, 'Heart Rate: -- BPM', fontsize=12, fontweight='bold',
                    color='blue', bbox=dict(facecolor='aliceblue', edgecolor='blue', boxstyle='round,pad=0.5'))
text_spo2 = fig.text(0.58, 0.02, 'SpO2: -- %', fontsize=12, fontweight='bold',
                     color='green', bbox=dict(facecolor='honeydew', edgecolor='green', boxstyle='round,pad=0.5'))

# --- Animation Update Callback ---
def update_plot(frame):
    global ser
    if ser and ser.is_open:
        try:
            while ser.in_waiting >= 8:
                # Synchronize to 0xAA Header Byte
                if ser.read(1) == b'\xAA':
                    packet = ser.read(7)  # Read remaining 7 bytes
                    if len(packet) == 7 and packet[6] == 0x55:  # Confirm 0x55 Footer
                        # Unpack signed 16-bit Red AC
                        red_ac_raw = (packet[0] << 8) | packet[1]
                        red_ac = red_ac_raw - 65536 if red_ac_raw >= 32768 else red_ac_raw

                        # Unpack signed 16-bit IR AC
                        ir_ac_raw = (packet[2] << 8) | packet[3]
                        ir_ac = ir_ac_raw - 65536 if ir_ac_raw >= 32768 else ir_ac_raw

                        # Unpack BPM and SpO2
                        bpm = packet[4]
                        spo2 = packet[5]

                        # Append to plot queues
                        red_wave.append(red_ac)
                        ir_wave.append(ir_ac)
                        if bpm > 0:
                            bpm_history.append(bpm)
                        if spo2 > 0:
                            spo2_history.append(spo2)
        except Exception as e:
            pass

    # Update plot lines
    line_red.set_ydata(red_wave)
    line_ir.set_ydata(ir_wave)

    # Dynamic Y-axis autoscaling
    ax1.relim()
    ax1.autoscale_view()
    ax2.relim()
    ax2.autoscale_view()

    # Update metric displays
    curr_bpm = bpm_history[-1] if bpm_history else '--'
    curr_spo2 = spo2_history[-1] if spo2_history else '--'
    text_bpm.set_text(f'Heart Rate: {curr_bpm} BPM')
    text_spo2.set_text(f'SpO2: {curr_spo2} %')

    return line_red, line_ir, text_bpm, text_spo2

ani = animation.FuncAnimation(fig, update_plot, interval=30, blit=False)

if __name__ == '__main__':
    print("[INFO] Starting Real-Time PPG Plotter...")
    print("[INFO] Make sure your Basys 3 board is connected and programmed.")
    plt.tight_layout(rect=[0, 0.06, 1, 0.95])
    plt.show()
