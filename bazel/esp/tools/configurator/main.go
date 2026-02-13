package main

import (
	"bufio"
	"embed-zig/bazel/esp/tools/common"
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

	// Convert output paths to absolute before Chdir
	// (Bazel passes relative paths from exec root)
	var err error
	configDir, err = filepath.Abs(configDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to resolve config_dir: %v\n", err)
		os.Exit(1)
	}
	includeDirsFile, err = filepath.Abs(includeDirsFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to resolve include_dirs_file: %v\n", err)
		os.Exit(1)
	}

	// Setup environment
	common.SetupHome()
	if err := common.SetupIDFEnv("[esp_configure]"); err != nil {
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
		// Content arrives via heredoc (<<'EOF'), no unescaping needed
		ymlContent := fmt.Sprintf("dependencies:\n%s", idfComponentYml)
		if err := os.WriteFile(filepath.Join(mainDir, "idf_component.yml"), []byte(ymlContent), 0644); err != nil {
			fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to write idf_component.yml: %v\n", err)
			os.Exit(1)
		}
	}

	// Copy sdkconfig
	if err := common.CopyFile(sdkconfigPath, filepath.Join(projectDir, "sdkconfig.defaults")); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: Failed to copy sdkconfig: %v\n", err)
		os.Exit(1)
	}

	// Extract chip type from sdkconfig
	chip, err := common.ExtractChipFromSdkconfig(filepath.Join(projectDir, "sdkconfig.defaults"))
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
	if err := common.RunCommand("idf.py", "set-target", chip); err != nil {
		fmt.Fprintf(os.Stderr, "[esp_configure] Error: idf.py set-target failed: %v\n", err)
		os.Exit(1)
	}

	// Run idf.py reconfigure
	if err := common.RunCommand("idf.py", "reconfigure"); err != nil {
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
	// Match cmake -L output format: KEY:TYPE=VALUE
	re := regexp.MustCompile(`(_INCLUDE_DIRS|_DIR):[^=]+=(.+)`)
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
