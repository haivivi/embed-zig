package main

import (
	"bufio"
	"embed-zig/bazel/bk/tools/common"
	"flag"
	"fmt"
	"os"
	"strings"
)

const prefix = "[bk_flash]"

type Config struct {
	Port       string
	Baud       string
	BkLoader   string
	BinPath    string
	ApBinPath  string
	PartCSV    string
	AppOnly    bool
}

func main() {
	appOnly := flag.Bool("app-only", false, "Flash AP partition only (skip bootloader/CP)")
	flag.Parse()

	cfg := Config{
		Port:      os.Getenv("BK_PORT_CONFIG"),
		Baud:      getEnvDefault("BK_BAUD", "115200"),
		BkLoader:  os.Getenv("BK_LOADER"),
		BinPath:   os.Getenv("BK_BIN"),
		ApBinPath: os.Getenv("BK_AP_BIN"),
		PartCSV:   os.Getenv("BK_PARTITIONS"),
		AppOnly:   *appOnly,
	}

	// Find bk_loader
	loader, err := common.FindBkLoader(cfg.BkLoader, prefix)
	if err != nil {
		fatal(err)
	}
	cfg.BkLoader = loader

	// Detect port
	port, err := common.DetectPort(cfg.Port, prefix)
	if err != nil {
		fatal(err)
	}
	cfg.Port = port

	// Kill existing process on port
	common.KillPortProcess(cfg.Port, prefix)

	if err := flash(&cfg); err != nil {
		fatal(err)
	}

	fmt.Printf("%s Done!\n", prefix)
}

func flash(cfg *Config) error {
	if cfg.AppOnly && cfg.ApBinPath != "" && cfg.PartCSV != "" && common.FileExists(cfg.ApBinPath) && common.FileExists(cfg.PartCSV) {
		return flashAppOnly(cfg)
	}
	return flashFull(cfg)
}

func flashFull(cfg *Config) error {
	fmt.Printf("%s Flashing all-app.bin to %s (%s baud)\n", prefix, cfg.Port, cfg.Baud)
	return common.RunCommand(cfg.BkLoader, "download",
		"-p", cfg.Port,
		"-b", cfg.Baud,
		"--reset_baudrate", cfg.Baud,
		"--reset_type", "1",
		"-i", cfg.BinPath,
		"--reboot")
}

func flashAppOnly(cfg *Config) error {
	// Read partition offset for primary_ap_app
	offset, err := findAPOffset(cfg.PartCSV)
	if err != nil {
		return err
	}

	fmt.Printf("%s APP-ONLY (experimental): flashing AP to %s at offset %s (%s baud)\n", prefix, cfg.Port, offset, cfg.Baud)
	fmt.Printf("%s WARNING: if device boot-loops, use full flash (without --app-only)\n", prefix)

	return common.RunCommand(cfg.BkLoader, "download",
		"-p", cfg.Port,
		"-b", cfg.Baud,
		"--reset_baudrate", cfg.Baud,
		"--reset_type", "1",
		"-i", cfg.ApBinPath,
		"-s", offset,
		"--reboot")
}

func findAPOffset(partCSV string) (string, error) {
	f, err := os.Open(partCSV)
	if err != nil {
		return "", fmt.Errorf("open partition table: %w", err)
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, "primary_ap_app") {
			parts := strings.Split(line, ",")
			if len(parts) >= 2 {
				return strings.TrimSpace(parts[1]), nil
			}
		}
	}
	return "", fmt.Errorf("cannot find primary_ap_app offset in partition table")
}

func getEnvDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "%s Error: %v\n", prefix, err)
	os.Exit(1)
}
