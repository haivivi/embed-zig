package main

import (
	"embed-zig/bazel/esp/tools/common"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
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

	// Load configuration from environment (set by Bazel rule wrapper script)
	// Paths are already resolved by the wrapper using runfiles
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

	// Setup environment
	common.SetupHome()

	// Find ESP-IDF Python
	idfPython, err := common.FindIDFPython("[esp_flash]")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_flash] Error: %v\n", err)
		os.Exit(1)
	}

	// Detect serial port
	port, err := common.DetectSerialPort(cfg.Port, "[esp_flash]")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_flash] Error: %v\n", err)
		os.Exit(1)
	}
	cfg.Port = port

	// Kill any process using the port
	common.KillPortProcess(cfg.Port, "[esp_flash]")

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
		if err := common.RunCommand(idfPython, args...); err != nil {
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

	if err := common.RunCommand(idfPython, args...); err != nil {
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
