package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

type Config struct {
	Board string
	Baud  string
	Port  string
}

func main() {
	// Load configuration from environment (set by Bazel rule)
	cfg := Config{
		Board: os.Getenv("ESP_BOARD"),
		Baud:  os.Getenv("ESP_MONITOR_BAUD"),
		Port:  os.Getenv("ESP_PORT_CONFIG"),
	}

	// Initialize runfiles (not used for monitor, but keep for consistency)
	_, err := runfiles.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_monitor] Error: Failed to initialize runfiles: %v\n", err)
		os.Exit(1)
	}

	// Setup environment
	setupHome()

	// Find ESP-IDF Python
	idfPython, err := findIDFPython()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_monitor] Error: %v\n", err)
		os.Exit(1)
	}

	// Detect serial port
	port, err := detectSerialPort(cfg.Port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_monitor] Error: %v\n", err)
		os.Exit(1)
	}
	cfg.Port = port

	// Kill any process using the port
	killPortProcess(cfg.Port)

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

// setupHome sets HOME if not already set.
func setupHome() {
	if os.Getenv("HOME") == "" {
		idfPath := os.Getenv("IDF_PATH")
		if idfPath != "" {
			re := regexp.MustCompile(`^(/[^/]+/[^/]+)/`)
			matches := re.FindStringSubmatch(idfPath)
			if len(matches) > 1 {
				os.Setenv("HOME", matches[1])
				return
			}
		}
		os.Setenv("HOME", "/tmp")
	}
}

// findIDFPython finds the ESP-IDF Python interpreter.
func findIDFPython() (string, error) {
	home := os.Getenv("HOME")
	pythonEnvDir := filepath.Join(home, ".espressif", "python_env")

	if _, err := os.Stat(pythonEnvDir); err == nil {
		entries, err := os.ReadDir(pythonEnvDir)
		if err == nil {
			for _, entry := range entries {
				if entry.IsDir() && strings.HasPrefix(entry.Name(), "idf") && strings.HasSuffix(entry.Name(), "_env") {
					pythonPath := filepath.Join(pythonEnvDir, entry.Name(), "bin", "python")
					if _, err := os.Stat(pythonPath); err == nil {
						return pythonPath, nil
					}
				}
			}
		}
	}

	fmt.Println("[esp_monitor] Warning: ESP-IDF Python env not found, using system python3")
	return "python3", nil
}

// detectSerialPort auto-detects or validates the serial port.
func detectSerialPort(configured string) (string, error) {
	// Priority: configured > ESP_PORT env > auto-detect
	if configured != "" {
		return configured, nil
	}

	if envPort := os.Getenv("ESP_PORT"); envPort != "" {
		return envPort, nil
	}

	// Auto-detect
	fmt.Println("[esp_monitor] Auto-detecting serial port...")

	var ports []string
	patterns := []string{"/dev/cu.usb*", "/dev/ttyUSB*", "/dev/ttyACM*"}
	for _, pattern := range patterns {
		matches, _ := filepath.Glob(pattern)
		ports = append(ports, matches...)
	}

	if len(ports) == 0 {
		return "", fmt.Errorf("no USB serial ports found\n" +
			"Please connect your ESP32 board or specify port:\n" +
			"    bazel run <target> --//bazel:port=/dev/xxx")
	}

	if len(ports) == 1 {
		fmt.Printf("[esp_monitor] Auto-detected: %s\n", ports[0])
		return ports[0], nil
	}

	// Multiple ports found
	fmt.Println("[esp_monitor] Multiple serial ports found:")
	for i, port := range ports {
		fmt.Printf("  [%d] %s\n", i, port)
	}
	return "", fmt.Errorf("please specify port:\n" +
		"    bazel run <target> --//bazel:port=%s", ports[0])
}

// killPortProcess kills any process using the specified port.
func killPortProcess(port string) {
	cmd := exec.Command("lsof", port)
	if err := cmd.Run(); err == nil {
		fmt.Printf("[esp_monitor] Killing process using %s...\n", port)
		killCmd := exec.Command("sh", "-c", fmt.Sprintf("lsof -t %s | xargs kill 2>/dev/null || true", port))
		_ = killCmd.Run()
		exec.Command("sleep", "0.5").Run()
	}
}
