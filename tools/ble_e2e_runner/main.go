// Package main implements a BLE x_proto E2E test runner.
//
// Orchestrates macOS BLE tool + ESP32 monitor processes, captures output,
// and reports throughput results. Uses Go's os/exec for reliable subprocess
// management (vs unreliable shell background processes).
//
// Usage:
//
//	bazel run //tools/ble_e2e_runner -- --mode=mac-server --esp-port=/dev/cu.usbmodem11301
//	bazel run //tools/ble_e2e_runner -- --mode=mac-client --esp-port=/dev/cu.usbmodem11101
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

func main() {
	mode := flag.String("mode", "", "Test mode: mac-server, mac-client")
	espPort := flag.String("esp-port", "", "ESP32 serial port (e.g. /dev/cu.usbmodem11301)")
	timeout := flag.Duration("timeout", 5*time.Minute, "Test timeout")
	flag.Parse()

	if *mode == "" || *espPort == "" {
		fmt.Println("BLE X-Proto E2E Test Runner")
		fmt.Println()
		fmt.Println("Usage:")
		fmt.Println("  bazel run //tools/ble_e2e_runner -- --mode=mac-server --esp-port=/dev/cu.usbmodem11301")
		fmt.Println("  bazel run //tools/ble_e2e_runner -- --mode=mac-client --esp-port=/dev/cu.usbmodem11101")
		fmt.Println()
		fmt.Println("Flags:")
		flag.PrintDefaults()
		os.Exit(1)
	}

	// Find workspace root (walk up from $BUILD_WORKING_DIRECTORY or cwd)
	wsRoot := findWorkspaceRoot()
	if wsRoot == "" {
		fmt.Println("ERROR: cannot find workspace root (no WORKSPACE.bazel found)")
		os.Exit(1)
	}

	zigBin := filepath.Join(wsRoot, "tools/macos_ble_x_proto/zig-out/bin/macos_ble_x_proto")
	if _, err := os.Stat(zigBin); err != nil {
		fmt.Printf("ERROR: Mac BLE tool not found at %s\n", zigBin)
		fmt.Println("Build it first: cd tools/macos_ble_x_proto && zig build")
		os.Exit(1)
	}

	var macArg string
	switch *mode {
	case "mac-server":
		macArg = "--server"
	case "mac-client":
		macArg = "--client"
	default:
		fmt.Printf("ERROR: unknown mode %q (use mac-server or mac-client)\n", *mode)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	fmt.Println("==========================================")
	fmt.Printf("BLE X-Proto E2E Runner — %s\n", *mode)
	fmt.Printf("ESP port: %s\n", *espPort)
	fmt.Printf("Timeout:  %s\n", *timeout)
	fmt.Println("==========================================")
	fmt.Println()

	// Collectors for output lines
	var macLines, espLines []string
	var mu sync.Mutex

	// --- 1. Start Mac process ---
	fmt.Printf("[runner] Starting Mac tool (%s)...\n", macArg)
	macCmd := exec.CommandContext(ctx, zigBin, macArg)
	macOut, _ := macCmd.StdoutPipe()
	macCmd.Stderr = macCmd.Stdout // merge stderr into stdout
	if err := macCmd.Start(); err != nil {
		fmt.Printf("[runner] ERROR: Mac start failed: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("[runner] Mac PID=%d\n", macCmd.Process.Pid)

	// Tee Mac output to terminal + buffer
	go func() {
		scanner := bufio.NewScanner(macOut)
		scanner.Buffer(make([]byte, 64*1024), 64*1024)
		for scanner.Scan() {
			line := scanner.Text()
			fmt.Printf("[mac] %s\n", line)
			mu.Lock()
			macLines = append(macLines, line)
			mu.Unlock()
		}
	}()

	// --- 2. Wait for Mac to start advertising/scanning ---
	fmt.Println("[runner] Waiting 4s for Mac BLE to initialize...")
	time.Sleep(4 * time.Second)

	// --- 3. Start ESP monitor (triggers USB-JTAG reset) ---
	fmt.Printf("[runner] Starting ESP monitor on %s (triggers reset)...\n", *espPort)
	espCmd := exec.CommandContext(ctx, "bazel", "run",
		"//bazel/esp:monitor", "--//bazel:port="+*espPort)
	espCmd.Dir = wsRoot
	espOut, _ := espCmd.StdoutPipe()
	espCmd.Stderr = espCmd.Stdout
	if err := espCmd.Start(); err != nil {
		fmt.Printf("[runner] ERROR: ESP monitor start failed: %v\n", err)
		macCmd.Process.Kill()
		os.Exit(1)
	}
	fmt.Printf("[runner] ESP monitor PID=%d\n", espCmd.Process.Pid)

	// Tee ESP output to terminal + buffer
	go func() {
		scanner := bufio.NewScanner(espOut)
		scanner.Buffer(make([]byte, 64*1024), 64*1024)
		for scanner.Scan() {
			line := scanner.Text()
			fmt.Printf("[esp] %s\n", line)
			mu.Lock()
			espLines = append(espLines, line)
			mu.Unlock()
		}
	}()

	// --- 4. Wait for Mac to finish (it exits after both tests) ---
	fmt.Println("[runner] Waiting for tests to complete...")
	macErr := macCmd.Wait()

	// --- 5. Kill ESP monitor ---
	fmt.Println("[runner] Mac process exited, killing ESP monitor...")
	espCmd.Process.Kill()
	espCmd.Wait()

	// --- 6. Parse and report results ---
	fmt.Println()
	fmt.Println("==========================================")
	fmt.Println("RESULTS")
	fmt.Println("==========================================")

	mu.Lock()
	printResults("Mac", macLines)
	fmt.Println()
	printResults("ESP", espLines)
	mu.Unlock()

	fmt.Println()
	if macErr != nil {
		fmt.Printf("Mac process error: %v\n", macErr)
	}

	// Check for PASS/FAIL
	allPass := true
	mu.Lock()
	for _, line := range append(macLines, espLines...) {
		if strings.Contains(line, "integrity: FAIL") {
			allPass = false
		}
	}
	mu.Unlock()

	if allPass {
		fmt.Println("OVERALL: ALL TESTS PASSED")
	} else {
		fmt.Println("OVERALL: SOME TESTS FAILED")
		os.Exit(1)
	}
}

func printResults(label string, lines []string) {
	keywords := []string{"ReadX", "WriteX", "KB/s", "DONE", "PASS", "FAIL", "integrity", "Test", "error"}
	fmt.Printf("--- %s Output (filtered) ---\n", label)
	for _, line := range lines {
		for _, kw := range keywords {
			if strings.Contains(line, kw) {
				fmt.Printf("  %s\n", line)
				break
			}
		}
	}
}

func findWorkspaceRoot() string {
	// Try BUILD_WORKING_DIRECTORY (set by `bazel run`)
	if dir := os.Getenv("BUILD_WORKING_DIRECTORY"); dir != "" {
		return findUp(dir)
	}
	// Fall back to cwd
	cwd, _ := os.Getwd()
	return findUp(cwd)
}

func findUp(dir string) string {
	markers := []string{"MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE"}
	for {
		for _, m := range markers {
			if _, err := os.Stat(filepath.Join(dir, m)); err == nil {
				return dir
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// Ensure pipes are drained even if process dies (avoid deadlock)
var _ io.Reader
