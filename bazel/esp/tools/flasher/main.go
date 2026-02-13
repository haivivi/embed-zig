package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/bazelbuild/rules_go/go/runfiles"
)

type Config struct {
	Board          string
	Baud           string
	Port           string
	BinPath        string
	BootloaderPath string
	PartitionPath  string
	FullFlash      bool
	DataFlashArgs  string
	NVSOffset      string
	NVSSize        string
	AppOnly        bool
	EraseNVS       bool
}

func main() {
	// Parse command-line flags
	appOnly := flag.Bool("app-only", false, "Flash app partition only (skip bootloader and partition table)")
	eraseNVS := flag.Bool("erase-nvs", false, "Erase NVS partition before flashing")
	flag.Parse()

	// Load configuration from environment (set by Bazel rule)
	cfg := Config{
		Board:          os.Getenv("ESP_BOARD"),
		Baud:           os.Getenv("ESP_BAUD"),
		Port:           os.Getenv("ESP_PORT_CONFIG"),
		BinPath:        os.Getenv("ESP_BIN"),
		BootloaderPath: os.Getenv("ESP_BOOTLOADER"),
		PartitionPath:  os.Getenv("ESP_PARTITION"),
		FullFlash:      os.Getenv("ESP_FULL_FLASH") == "1",
		DataFlashArgs:  os.Getenv("ESP_DATA_FLASH_ARGS"),
		NVSOffset:      os.Getenv("ESP_NVS_OFFSET"),
		NVSSize:        os.Getenv("ESP_NVS_SIZE"),
		AppOnly:        *appOnly,
		EraseNVS:       *eraseNVS,
	}

	// Resolve paths using Bazel runfiles
	r, err := runfiles.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_flash] Error: Failed to initialize runfiles: %v\n", err)
		os.Exit(1)
	}

	// Resolve file paths
	cfg.BinPath = resolvePath(r, cfg.BinPath)
	if cfg.BootloaderPath != "" {
		cfg.BootloaderPath = resolvePath(r, cfg.BootloaderPath)
	}
	if cfg.PartitionPath != "" {
		cfg.PartitionPath = resolvePath(r, cfg.PartitionPath)
	}

	// Setup environment
	setupHome()

	// Find ESP-IDF Python
	idfPython, err := findIDFPython()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_flash] Error: %v\n", err)
		os.Exit(1)
	}

	// Detect serial port
	port, err := detectSerialPort(cfg.Port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_flash] Error: %v\n", err)
		os.Exit(1)
	}
	cfg.Port = port

	// Kill any process using the port
	killPortProcess(cfg.Port)

	fmt.Printf("[esp_flash] Board: %s\n", cfg.Board)
	fmt.Printf("[esp_flash] Flashing to %s at %s baud...\n", cfg.Port, cfg.Baud)
	fmt.Printf("[esp_flash] Binary: %s\n", cfg.BinPath)

	// Detect reset mode based on port type
	beforeReset := "default_reset"
	afterReset := "hard_reset"
	usbJTAGMode := false
	if strings.Contains(cfg.Port, "usbmodem") {
		beforeReset = "usb_reset"
		afterReset = "no_reset"
		usbJTAGMode = true
		fmt.Println("[esp_flash] Using USB-JTAG mode (watchdog reset after flash)")
	}

	// Erase NVS if requested
	if cfg.EraseNVS {
		nvsOffset := cfg.NVSOffset
		nvsSize := cfg.NVSSize
		if nvsOffset == "" || nvsSize == "" {
			fmt.Println("[esp_flash] Warning: NVS partition info not available, using default (0x9000, 0x6000)")
			nvsOffset = "0x9000"
			nvsSize = "0x6000"
		}
		fmt.Printf("[esp_flash] Erasing NVS partition at %s (size: %s)...\n", nvsOffset, nvsSize)
		args := []string{"-m", "esptool", "--port", cfg.Port, "--baud", cfg.Baud,
			"--before", beforeReset, "--after", "no_reset",
			"erase_region", nvsOffset, nvsSize}
		if err := runCommand(idfPython, args...); err != nil {
			fmt.Fprintf(os.Stderr, "[esp_flash] Error: NVS erase failed: %v\n", err)
			os.Exit(1)
		}
	}

	// Build flash arguments
	var flashArgs []string
	if cfg.AppOnly {
		fmt.Println("[esp_flash] App-only mode")
		flashArgs = []string{"0x10000", cfg.BinPath}
	} else if cfg.FullFlash {
		fmt.Println("[esp_flash] Full flash mode (bootloader + partition + app)")
		flashArgs = []string{
			"0x0", cfg.BootloaderPath,
			"0x8000", cfg.PartitionPath,
			"0x10000", cfg.BinPath,
		}
		// Add data partitions if any
		if cfg.DataFlashArgs != "" {
			parts := strings.Fields(cfg.DataFlashArgs)
			flashArgs = append(flashArgs, parts...)
			fmt.Println("[esp_flash] Including data partitions")
		}
	} else {
		flashArgs = []string{"0x10000", cfg.BinPath}
	}

	// Run esptool
	args := []string{"-m", "esptool", "--port", cfg.Port, "--baud", cfg.Baud,
		"--before", beforeReset, "--after", afterReset,
		"write_flash", "-z"}
	args = append(args, flashArgs...)

	if err := runCommand(idfPython, args...); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_flash] Error: Flash failed: %v\n", err)
		os.Exit(1)
	}

	// For USB-JTAG, use watchdog reset
	if usbJTAGMode {
		fmt.Println("[esp_flash] Executing watchdog reset...")
		pythonCode := fmt.Sprintf(`
import esptool
esp = esptool.detect_chip('%s', 115200, 'usb_reset', False, 3)
esp = esp.run_stub()
esp.watchdog_reset()
`, cfg.Port)
		cmd := exec.Command(idfPython, "-c", pythonCode)
		cmd.Stdout = nil
		cmd.Stderr = nil
		_ = cmd.Run() // Ignore errors
		fmt.Println("[esp_flash] Watchdog reset complete (manual RST may be needed)")
	}

	fmt.Println("[esp_flash] Flash complete!")
}

// resolvePath resolves a path using Bazel runfiles.
// If path is already absolute, returns it as-is.
// Otherwise, tries to resolve it as a runfiles path.
func resolvePath(r *runfiles.Runfiles, path string) string {
	if filepath.IsAbs(path) {
		return path
	}
	// Try to resolve as runfiles path
	resolved, err := r.Rlocation(path)
	if err == nil && resolved != "" {
		return resolved
	}
	// If resolution fails, return original path
	return path
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

	fmt.Println("[esp_flash] Warning: ESP-IDF Python env not found, using system python3")
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
	fmt.Println("[esp_flash] Auto-detecting serial port...")

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
		fmt.Printf("[esp_flash] Auto-detected: %s\n", ports[0])
		return ports[0], nil
	}

	// Multiple ports found
	fmt.Println("[esp_flash] Multiple serial ports found:")
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
		fmt.Printf("[esp_flash] Killing process using %s...\n", port)
		killCmd := exec.Command("sh", "-c", fmt.Sprintf("lsof -t %s | xargs kill 2>/dev/null || true", port))
		_ = killCmd.Run()
		exec.Command("sleep", "0.5").Run()
	}
}

// runCommand runs a command and prints output.
func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
