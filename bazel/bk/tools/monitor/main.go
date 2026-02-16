package main

import (
	"embed-zig/bazel/bk/tools/common"
	"fmt"
	"os"
	"os/exec"
)

const prefix = "[bk_monitor]"

func main() {
	port, err := common.DetectPort(os.Getenv("BK_PORT_CONFIG"), prefix)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s Error: %v\n", prefix, err)
		os.Exit(1)
	}

	common.KillPortProcess(port, prefix)

	fmt.Printf("%s Board: BK7258\n", prefix)
	fmt.Printf("%s Monitoring %s at 115200 baud...\n", prefix, port)
	fmt.Println(prefix + " Press Ctrl+C to exit")

	// Pass port via sys.argv to avoid string injection in Python code
	pythonCode := `
import serial, sys
port = sys.argv[1]
try:
    ser = serial.Serial(port, 115200, timeout=0.5)
    ser.setDTR(False)
    ser.setRTS(False)
    print(f'Connected to {port} at 115200 baud')
    print('Waiting for data... (press RST on device if needed)')
    print('---')
    while True:
        data = ser.read(ser.in_waiting or 1)
        if data:
            sys.stdout.write(data.decode('utf-8', errors='replace'))
            sys.stdout.flush()
except KeyboardInterrupt:
    print('\n--- Monitor stopped ---')
except Exception as e:
    print(f'Error: {e}')
    sys.exit(1)
`

	cmd := exec.Command("python3", "-c", pythonCode, port)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "%s Error: Monitor failed: %v\n", prefix, err)
		os.Exit(1)
	}
}
