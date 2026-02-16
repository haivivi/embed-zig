package common

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// SetupArminoEnv validates ARMINO_PATH and activates Python venv if available.
func SetupArminoEnv(toolPrefix string) (string, error) {
	arminoPath := os.Getenv("ARMINO_PATH")
	if arminoPath == "" {
		return "", fmt.Errorf("ARMINO_PATH not set\nAdd to .bazelrc.user:\n  build --//bazel:armino_path=/path/to/bk_avdk_smp")
	}

	if info, err := os.Stat(arminoPath); err != nil || !info.IsDir() {
		return "", fmt.Errorf("ARMINO_PATH=%s does not exist", arminoPath)
	}

	// Activate Python venv if available
	venvActivate := filepath.Join(arminoPath, "venv", "bin", "activate")
	if _, err := os.Stat(venvActivate); err == nil {
		venvBin := filepath.Join(arminoPath, "venv", "bin")
		path := os.Getenv("PATH")
		os.Setenv("PATH", venvBin+string(os.PathListSeparator)+path)
	}

	fmt.Printf("%s Armino SDK: %s\n", toolPrefix, arminoPath)
	return arminoPath, nil
}

// FindBkLoader locates the bk_loader binary.
func FindBkLoader(configured string, toolPrefix string) (string, error) {
	if configured != "" {
		if _, err := os.Stat(configured); err == nil {
			return configured, nil
		}
	}

	envPath := os.Getenv("BK_LOADER_PATH")
	if envPath != "" {
		if info, err := os.Stat(envPath); err == nil && !info.IsDir() {
			return envPath, nil
		}
	}

	return "", fmt.Errorf("BK_LOADER_PATH not set or not executable\nAdd to .bazelrc.user:\n  build --//bazel:bk_loader_path=/path/to/bk_loader")
}

// DetectPort validates the configured serial port.
func DetectPort(configured string, toolPrefix string) (string, error) {
	if configured != "" {
		return configured, nil
	}

	return "", fmt.Errorf("port not specified\nUsage: bazel run //xxx:flash --//bazel:port=/dev/cu.usbserial-XXX")
}

// KillPortProcess kills any process using the specified port.
func KillPortProcess(port string, toolPrefix string) {
	cmd := exec.Command("lsof", port)
	if err := cmd.Run(); err == nil {
		fmt.Printf("%s Killing process using %s...\n", toolPrefix, port)
		killCmd := exec.Command("sh", "-c", fmt.Sprintf("lsof -t '%s' | xargs kill 2>/dev/null || true", port))
		_ = killCmd.Run()
		time.Sleep(500 * time.Millisecond)
	}
}

// RunCommand executes a command with stdout/stderr redirected.
func RunCommand(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// RunCommandInDir executes a command in a specific directory.
func RunCommandInDir(dir string, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
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

// CopyFileIfExists copies a file if it exists, returns false if not found.
func CopyFileIfExists(src, dst string) bool {
	if err := CopyFile(src, dst); err != nil {
		return false
	}
	return true
}

// FileExists checks if a file exists.
func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// FindFileWithPath finds a file under root where the path contains the given substring.
func FindFileWithPath(root, name, pathContains string) string {
	var result string
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() && info.Name() == name {
			if pathContains == "" || strings.Contains(path, pathContains) {
				if result == "" {
					result = path
				}
			}
		}
		return nil
	})
	return result
}

// FindFileWithPathExclude finds a file matching name+pathContains but NOT pathExcludes.
func FindFileWithPathExclude(root, name, pathContains, pathExcludes string) string {
	var result string
	filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() && info.Name() == name {
			if (pathContains == "" || strings.Contains(path, pathContains)) &&
				(pathExcludes == "" || !strings.Contains(path, pathExcludes)) {
				if result == "" {
					result = path
				}
			}
		}
		return nil
	})
	return result
}

// ReplaceInFile performs a string replacement in a file.
func ReplaceInFile(path, old, new string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	content := string(data)
	if !strings.Contains(content, old) {
		return nil // nothing to replace
	}
	updated := strings.ReplaceAll(content, old, new)
	return os.WriteFile(path, []byte(updated), 0644)
}

// FileSize returns the file size in bytes, or 0 if stat fails.
func FileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}
