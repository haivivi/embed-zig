package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

func main() {
	// Read configuration from environment
	sdkconfigPath := os.Getenv("ESP_SDKCONFIG_PATH")
	configDir := os.Getenv("ESP_CONFIG_DIR")
	includeDirsFile := os.Getenv("ESP_INCLUDE_DIRS_FILE")
	requires := os.Getenv("ESP_REQUIRES")
	idfComponentYml := os.Getenv("ESP_IDF_COMPONENT_YML")

	if sdkconfigPath == "" || configDir == "" || includeDirsFile == "" {
		fmt.Fprintln(os.Stderr, "[esp_configure] Error: Required environment variables not set")
		os.Exit(1)
	}

	if requires == "" {
		requires = "freertos"
	}

	// Setup environment
	setupHome()
	if err := setupIDFEnv(); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: %v\n", err)
		os.Exit(1)
	}

	// Verify idf.py is available
	if _, err := exec.LookPath("idf.py"); err != nil {
		fmt.Fprintln(os.Stderr, "[esp_configure] Error: idf.py not found")
		os.Exit(1)
	}

	// Create temporary work directory
	workDir, err := os.MkdirTemp("", "esp_configure_*")
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to create temp dir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(workDir)

	projectDir := filepath.Join(workDir, "project")
	mainDir := filepath.Join(projectDir, "main")
	if err := os.MkdirAll(mainDir, 0755); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to create project dir: %v\n", err)
		os.Exit(1)
	}

	// Generate minimal CMakeLists.txt
	cmakeContent := `cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(esp_configure)
`
	if err := os.WriteFile(filepath.Join(projectDir, "CMakeLists.txt"), []byte(cmakeContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to write CMakeLists.txt: %v\n", err)
		os.Exit(1)
	}

	// Generate main component CMakeLists.txt
	mainCmakeContent := fmt.Sprintf(`idf_component_register(
    SRCS "main.c"
    REQUIRES %s
)
`, requires)
	if err := os.WriteFile(filepath.Join(mainDir, "CMakeLists.txt"), []byte(mainCmakeContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to write main CMakeLists.txt: %v\n", err)
		os.Exit(1)
	}

	// Generate main.c
	mainCContent := `void app_main(void) {}`
	if err := os.WriteFile(filepath.Join(mainDir, "main.c"), []byte(mainCContent), 0644); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to write main.c: %v\n", err)
		os.Exit(1)
	}

	// Generate idf_component.yml if needed
	if idfComponentYml != "" {
		ymlContent := fmt.Sprintf("dependencies:\n%s", idfComponentYml)
		if err := os.WriteFile(filepath.Join(mainDir, "idf_component.yml"), []byte(ymlContent), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to write idf_component.yml: %v\n", err)
			os.Exit(1)
		}
	}

	// Copy sdkconfig
	if err := copyFile(sdkconfigPath, filepath.Join(projectDir, "sdkconfig.defaults")); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to copy sdkconfig: %v\n", err)
		os.Exit(1)
	}

	// Extract chip type from sdkconfig
	chip, err := extractChipFromSdkconfig(filepath.Join(projectDir, "sdkconfig.defaults"))
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("[esp_configure] Chip: %s\n", chip)

	// Change to project directory
	if err := os.Chdir(projectDir); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to cd to project dir: %v\n", err)
		os.Exit(1)
	}

	// Run idf.py set-target
	if err := runCommand("idf.py", "set-target", chip); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: idf.py set-target failed: %v\n", err)
		os.Exit(1)
	}

	// Run idf.py reconfigure
	if err := runCommand("idf.py", "reconfigure"); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: idf.py reconfigure failed: %v\n", err)
		os.Exit(1)
	}

	// Copy generated config directory
	buildConfigDir := filepath.Join(projectDir, "build", "config")
	if err := copyDir(buildConfigDir, configDir); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to copy config dir: %v\n", err)
		os.Exit(1)
	}

	// Extract include directories
	fmt.Println("[esp_configure] Extracting include directories...")
	if err := extractIncludeDirs(projectDir, includeDirsFile, configDir); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to extract include dirs: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("[esp_configure] Done. Config at %s\n", configDir)
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

// setupIDFEnv sets up ESP-IDF environment (PATH and IDF_PYTHON).
func setupIDFEnv() error {
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
						break
					}
				}
			}
		}
	}

	if idfPythonEnv == "" {
		os.Setenv("IDF_PYTHON", "python3")
		return nil
	}

	// Build PATH with ESP-IDF tools
	espressifTools := filepath.Join(home, ".espressif", "tools")
	var idfToolsPaths []string

	if _, err := os.Stat(espressifTools); err == nil {
		filepath.Walk(espressifTools, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return nil
			}
			if info.IsDir() && info.Name() == "bin" {
				rel, _ := filepath.Rel(espressifTools, path)
				if strings.Count(rel, string(os.PathSeparator)) <= 3 {
					idfToolsPaths = append(idfToolsPaths, path)
				}
			}
			return nil
		})
	}

	idfPath := os.Getenv("IDF_PATH")
	pathComponents := []string{filepath.Join(idfPythonEnv, "bin")}
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

// extractChipFromSdkconfig extracts CONFIG_IDF_TARGET from sdkconfig.defaults.
func extractChipFromSdkconfig(path string) (string, error) {
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

// extractIncludeDirs extracts include directories from CMake and writes to file.
func extractIncludeDirs(projectDir, outputFile, configDir string) error {
	f, err := os.Create(outputFile)
	if err != nil {
		return err
	}
	defer f.Close()

	// Get include dirs from CMake cache
	buildDir := filepath.Join(projectDir, "build")
	cmd := exec.Command("cmake", "-L", buildDir)
	output, err := cmd.Output()
	if err != nil {
		// Ignore error, CMake might not have all info we need
	}

	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	re := regexp.MustCompile(`(_INCLUDE_DIRS|_DIR)=(.+)`)
	for scanner.Scan() {
		line := scanner.Text()
		if matches := re.FindStringSubmatch(line); len(matches) > 2 {
			fmt.Fprintln(f, matches[2])
		}
	}

	// Add standard paths that are always needed
	fmt.Fprintln(f, configDir)
	idfPath := os.Getenv("IDF_PATH")
	if idfPath != "" {
		fmt.Fprintln(f, filepath.Join(idfPath, "components", "esp_common", "include"))
		fmt.Fprintln(f, filepath.Join(idfPath, "components", "esp_system", "include"))
	}

	return nil
}

// runCommand runs a command and streams output to stdout/stderr.
func runCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// copyFile copies a file from src to dst.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
}

// copyDir recursively copies a directory.
func copyDir(src, dst string) error {
	return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		relPath, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		dstPath := filepath.Join(dst, relPath)

		if info.IsDir() {
			return os.MkdirAll(dstPath, info.Mode())
		}

		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(dstPath, data, info.Mode())
	})
}
