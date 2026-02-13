package common

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// SetupHome sets HOME if not already set.
func SetupHome() {
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

// SetupIDFEnv sets up ESP-IDF environment (PATH and IDF_PYTHON).
// toolPrefix is used for log messages (e.g., "[esp_build]").
func SetupIDFEnv(toolPrefix string) error {
	home := os.Getenv("HOME")
	pythonEnvDir := filepath.Join(home, ".espressif", "python_env")

	var idfPythonEnv string
	if _, err := os.Stat(pythonEnvDir); err == nil {
		entries, err := os.ReadDir(pythonEnvDir)
		if err == nil {
			for _, entry := range entries {
				if entry.IsDir() && strings.HasPrefix(entry.Name(), "idf") && strings.HasSuffix(entry.Name(), "_env") {
					envPath := filepath.Join(pythonEnvDir, entry.Name())
					pythonPath := filepath.Join(envPath, "bin", "python")
					if _, err := os.Stat(pythonPath); err == nil {
						idfPythonEnv = envPath
						// Keep iterating to select the last match (highest version)
					}
				}
			}
		}
	}

	if idfPythonEnv == "" {
		fmt.Printf("%s Warning: ESP-IDF Python env not found\n", toolPrefix)
		// Try to use system python3 and hope export.sh was sourced
		os.Setenv("IDF_PYTHON", "python3")
		return nil
	}

	fmt.Printf("[esp] Using Python env: %s\n", idfPythonEnv)

	// Build PATH with ESP-IDF tools
	espressifTools := filepath.Join(home, ".espressif", "tools")
	var idfToolsPaths []string

	if _, err := os.Stat(espressifTools); err == nil {
		// Find all bin directories under tools
		filepath.Walk(espressifTools, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() && info.Name() == "bin" {
				// Limit depth to 4 levels (same as shell script)
				rel, _ := filepath.Rel(espressifTools, path)
				if strings.Count(rel, string(os.PathSeparator)) <= 3 {
					idfToolsPaths = append(idfToolsPaths, path)
				}
			}
			return nil
		})
	}

	idfPath := os.Getenv("IDF_PATH")
	pathComponents := []string{
		filepath.Join(idfPythonEnv, "bin"),
	}
	pathComponents = append(pathComponents, idfToolsPaths...)
	if idfPath != "" {
		pathComponents = append(pathComponents, filepath.Join(idfPath, "tools"))
	}
	pathComponents = append(pathComponents, os.Getenv("PATH"))

	newPath := strings.Join(pathComponents, string(os.PathListSeparator))
	os.Setenv("PATH", newPath)
	os.Setenv("IDF_PYTHON", filepath.Join(idfPythonEnv, "bin", "python"))

	return nil
}

// FindIDFPython finds the ESP-IDF Python interpreter.
// toolPrefix is used for log messages (e.g., "[esp_flash]").
func FindIDFPython(toolPrefix string) (string, error) {
	home := os.Getenv("HOME")
	pythonEnvDir := filepath.Join(home, ".espressif", "python_env")

	var lastPythonPath string
	if _, err := os.Stat(pythonEnvDir); err == nil {
		entries, err := os.ReadDir(pythonEnvDir)
		if err == nil {
			for _, entry := range entries {
				if entry.IsDir() && strings.HasPrefix(entry.Name(), "idf") && strings.HasSuffix(entry.Name(), "_env") {
					pythonPath := filepath.Join(pythonEnvDir, entry.Name(), "bin", "python")
					if _, err := os.Stat(pythonPath); err == nil {
						lastPythonPath = pythonPath
						// Keep iterating to select the last match (highest version)
					}
				}
			}
		}
	}

	if lastPythonPath != "" {
		return lastPythonPath, nil
	}

	fmt.Printf("%s Warning: ESP-IDF Python env not found, using system python3\n", toolPrefix)
	return "python3", nil
}

// DetectSerialPort auto-detects or validates the serial port.
// toolPrefix is used for log messages (e.g., "[esp_monitor]").
func DetectSerialPort(configured string, toolPrefix string) (string, error) {
	// Priority: configured > ESP_PORT env > auto-detect
	if configured != "" {
		return configured, nil
	}

	if envPort := os.Getenv("ESP_PORT"); envPort != "" {
		return envPort, nil
	}

	// Auto-detect
	fmt.Printf("%s Auto-detecting serial port...\n", toolPrefix)

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
		fmt.Printf("%s Auto-detected: %s\n", toolPrefix, ports[0])
		return ports[0], nil
	}

	// Multiple ports found
	fmt.Printf("%s Multiple serial ports found:\n", toolPrefix)
	for i, port := range ports {
		fmt.Printf("  [%d] %s\n", i, port)
	}
	return "", fmt.Errorf("please specify port:\n" +
		"    bazel run <target> --//bazel:port=%s", ports[0])
}

// KillPortProcess kills any process using the specified port.
// toolPrefix is used for log messages (e.g., "[esp_monitor]").
func KillPortProcess(port string, toolPrefix string) {
	cmd := exec.Command("lsof", port)
	if err := cmd.Run(); err == nil {
		fmt.Printf("%s Killing process using %s...\n", toolPrefix, port)
		killCmd := exec.Command("sh", "-c", fmt.Sprintf("lsof -t %s | xargs kill 2>/dev/null || true", port))
		_ = killCmd.Run()
		exec.Command("sleep", "0.5").Run()
	}
}

// RunCommand executes a command with stdout/stderr redirected.
func RunCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// CopyFile copies a file from src to dst.
func CopyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}

// ExtractChipFromSdkconfig extracts chip target from sdkconfig.defaults.
func ExtractChipFromSdkconfig(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("failed to open %s: %w", path, err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	re := regexp.MustCompile(`^CONFIG_IDF_TARGET="(.+)"`)

	for scanner.Scan() {
		line := scanner.Text()
		if matches := re.FindStringSubmatch(line); len(matches) > 1 {
			return matches[1], nil
		}
	}

	if err := scanner.Err(); err != nil {
		return "", fmt.Errorf("error reading %s: %w", path, err)
	}

	return "", fmt.Errorf("CONFIG_IDF_TARGET not found in %s", path)
}
