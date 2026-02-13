package main

import (
	"embed-zig/bazel/esp/tools/common"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type Config struct {
	Board         string
	ProjectName   string
	BinOut        string
	ElfOut        string
	BootloaderOut string
	PartitionOut  string
	ZigInstall    string
	WorkDir       string
	ProjectPath   string
	ExecRoot      string
	// WiFi and test server settings
	WifiSSID       string
	WifiPassword   string
	TestServerIP   string
	TestServerPort string
}

func main() {
	// Load configuration from environment (set by Bazel wrapper)
	cfg := Config{
		Board:          os.Getenv("ESP_BOARD"),
		ProjectName:    os.Getenv("ESP_PROJECT_NAME"),
		BinOut:         os.Getenv("ESP_BIN_OUT"),
		ElfOut:         os.Getenv("ESP_ELF_OUT"),
		BootloaderOut:  os.Getenv("ESP_BOOTLOADER_OUT"),
		PartitionOut:   os.Getenv("ESP_PARTITION_OUT"),
		ZigInstall:     os.Getenv("ZIG_INSTALL"),
		WorkDir:        os.Getenv("ESP_WORK_DIR"),
		ProjectPath:    os.Getenv("ESP_PROJECT_PATH"),
		ExecRoot:       os.Getenv("ESP_EXECROOT"),
		WifiSSID:       getEnvWithFallback("ESP_WIFI_SSID", "WIFI_SSID"),
		WifiPassword:   getEnvWithFallback("ESP_WIFI_PASSWORD", "WIFI_PASSWORD"),
		TestServerIP:   getEnvWithFallback("ESP_TEST_SERVER_IP", "TEST_SERVER_IP"),
		TestServerPort: getEnvWithFallback("ESP_TEST_SERVER_PORT", "TEST_SERVER_PORT"),
	}

	// Validate required variables
	if err := validateConfig(&cfg); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_build] Error: %v\n", err)
		os.Exit(1)
	}

	// Run build
	if err := build(&cfg); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_build] Error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("[esp_build] Build complete!")
}

func validateConfig(cfg *Config) error {
	required := map[string]string{
		"ESP_BOARD":        cfg.Board,
		"ESP_PROJECT_NAME": cfg.ProjectName,
		"ESP_BIN_OUT":      cfg.BinOut,
		"ESP_ELF_OUT":      cfg.ElfOut,
		"ESP_WORK_DIR":     cfg.WorkDir,
		"ESP_PROJECT_PATH": cfg.ProjectPath,
		"ESP_EXECROOT":     cfg.ExecRoot,
	}

	for name, value := range required {
		if value == "" {
			return fmt.Errorf("%s not set", name)
		}
	}
	return nil
}

func build(cfg *Config) error {
	projectDir := filepath.Join(cfg.WorkDir, cfg.ProjectPath)

	fmt.Printf("[esp_build] Work directory: %s\n", cfg.WorkDir)
	fmt.Printf("[esp_build] Project path: %s\n", cfg.ProjectPath)
	fmt.Printf("[esp_build] Board: %s\n", cfg.Board)

	// Setup environment
	os.Setenv("ZIG_BOARD", cfg.Board)
	common.SetupHome()

	fmt.Printf("[esp_build] IDF_PATH: %s\n", os.Getenv("IDF_PATH"))
	fmt.Printf("[esp_build] ZIG_INSTALL: %s\n", cfg.ZigInstall)
	fmt.Printf("[esp_build] ZIG_BOARD: %s\n", cfg.Board)

	// Setup ESP-IDF environment (PATH, IDF_PYTHON)
	if err := common.SetupIDFEnv("[esp_build]"); err != nil {
		return err
	}

	// Verify idf.py is available
	if _, err := exec.LookPath("idf.py"); err != nil {
		path := os.Getenv("PATH")
		return fmt.Errorf("idf.py not found\nPATH: %s", path)
	}

	// Change to project directory
	if err := os.Chdir(projectDir); err != nil {
		return fmt.Errorf("failed to cd to %s: %w", projectDir, err)
	}

	// Extract chip type from sdkconfig.defaults
	chip, err := common.ExtractChipFromSdkconfig(filepath.Join(projectDir, "sdkconfig.defaults"))
	if err != nil {
		return err
	}
	fmt.Printf("[esp_build] Chip (from sdkconfig): %s\n", chip)

	// Run idf.py set-target
	fmt.Printf("[esp_build] Running: idf.py set-target %s\n", chip)
	if err := common.RunCommand("idf.py", "set-target", chip); err != nil {
		return fmt.Errorf("idf.py set-target failed: %w", err)
	}

	// Build CMake arguments
	cmakeArgs := []string{fmt.Sprintf("-DZIG_BOARD=%s", cfg.Board)}

	if cfg.WifiSSID != "" {
		cmakeArgs = append(cmakeArgs, fmt.Sprintf("-DCONFIG_WIFI_SSID=%s", cfg.WifiSSID))
		fmt.Printf("[esp_build] WiFi SSID: %s\n", cfg.WifiSSID)
	}
	if cfg.WifiPassword != "" {
		cmakeArgs = append(cmakeArgs, fmt.Sprintf("-DCONFIG_WIFI_PASSWORD=%s", cfg.WifiPassword))
	}
	if cfg.TestServerIP != "" {
		cmakeArgs = append(cmakeArgs, fmt.Sprintf("-DCONFIG_TEST_SERVER_IP=%s", cfg.TestServerIP))
		fmt.Printf("[esp_build] Test server IP: %s\n", cfg.TestServerIP)
	}
	if cfg.TestServerPort != "" {
		cmakeArgs = append(cmakeArgs, fmt.Sprintf("-DCONFIG_TEST_SERVER_PORT=%s", cfg.TestServerPort))
		fmt.Printf("[esp_build] Test server port: %s\n", cfg.TestServerPort)
	}

	// Run idf.py build
	args := append(cmakeArgs, "build")
	fmt.Printf("[esp_build] Running: idf.py %s\n", strings.Join(args, " "))
	if err := common.RunCommand("idf.py", args...); err != nil {
		return fmt.Errorf("idf.py build failed: %w", err)
	}

	// Copy outputs back to Bazel execroot
	buildDir := filepath.Join(projectDir, "build")

	if err := common.CopyFile(
		filepath.Join(buildDir, cfg.ProjectName+".bin"),
		filepath.Join(cfg.ExecRoot, cfg.BinOut),
	); err != nil {
		return fmt.Errorf("failed to copy .bin: %w", err)
	}

	if err := common.CopyFile(
		filepath.Join(buildDir, cfg.ProjectName+".elf"),
		filepath.Join(cfg.ExecRoot, cfg.ElfOut),
	); err != nil {
		return fmt.Errorf("failed to copy .elf: %w", err)
	}

	if cfg.BootloaderOut != "" {
		if err := common.CopyFile(
			filepath.Join(buildDir, "bootloader", "bootloader.bin"),
			filepath.Join(cfg.ExecRoot, cfg.BootloaderOut),
		); err != nil {
			return fmt.Errorf("failed to copy bootloader: %w", err)
		}
	}

	if cfg.PartitionOut != "" {
		if err := common.CopyFile(
			filepath.Join(buildDir, "partition_table", "partition-table.bin"),
			filepath.Join(cfg.ExecRoot, cfg.PartitionOut),
		); err != nil {
			return fmt.Errorf("failed to copy partition table: %w", err)
		}
	}

	return nil
}

// getEnvWithFallback returns the value of the first environment variable that is set.
func getEnvWithFallback(primary, fallback string) string {
	if val := os.Getenv(primary); val != "" {
		return val
	}
	return os.Getenv(fallback)
}
