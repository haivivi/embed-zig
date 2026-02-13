package main

import (
	"embed-zig/bazel/esp/tools/common"
	"fmt"
	"os"
	"os/exec"
)

type Config struct {
	Board string
	Baud  string
	Port  string
}

func main() {
	// Load configuration from environment (set by Bazel rule wrapper script)
	cfg := Config{
		Board: os.Getenv("ESP_BOARD"),
		Baud:  os.Getenv("ESP_MONITOR_BAUD"),
		Port:  os.Getenv("ESP_PORT_CONFIG"),
	}

	// Setup environment
	common.SetupHome()

	// Find ESP-IDF Python
	idfPython, err := common.FindIDFPython("[esp_monitor]")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_monitor] Error: %v\n", err)
		os.Exit(1)
	}

	// Detect serial port
	port, err := common.DetectSerialPort(cfg.Port, "[esp_monitor]")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_monitor] Error: %v\n", err)
		os.Exit(1)
	}
	cfg.Port = port

	// Kill any process using the port
	common.KillPortProcess(cfg.Port, "[esp_monitor]")

	fmt.Printf("[esp_monitor] Board: %s\n", cfg.Board)
	fmt.Printf("[esp_monitor] Monitoring %s at %s baud...\n", cfg.Port, cfg.Baud)
	fmt.Println("[esp_monitor] Press Ctrl+C to exit")

	// Run Python serial monitor
	pythonCode := fmt.Sprintf(`
import serial
import sys

try:
    ser = serial.Serial('%s', %s, timeout=0.5)
    ser.setDTR(False)  # Don't trigger reset
    ser.setRTS(False)
    print('Connected to %s at %s baud')
    print('Waiting for data... (press RST on device if needed)')
    print('---')
    while True:
        data = ser.read(ser.in_waiting or 1)
        if data:
            text = data.decode('utf-8', errors='replace')
            sys.stdout.write(text)
            sys.stdout.flush()
except KeyboardInterrupt:
    print('\n--- Monitor stopped ---')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
`, cfg.Port, cfg.Baud, cfg.Port, cfg.Baud)

	cmd := exec.Command(idfPython, "-c", pythonCode)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_monitor] Error: Monitor failed: %v\n", err)
		os.Exit(1)
	}
}
