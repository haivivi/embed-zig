// websim_serve — Local HTTP server for WebSim WASM apps.
//
// Serves a directory of static files (HTML/JS/CSS/WASM) and opens the browser.
// Used by the websim_app Bazel rule's :serve target.
//
// Usage: websim_serve <site_dir> [--port=8080]
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"runtime"
)

func main() {
	port := flag.Int("port", 0, "port to listen on (0 = auto)")
	noOpen := flag.Bool("no-open", false, "don't open browser")
	flag.Parse()

	if flag.NArg() < 1 {
		fmt.Fprintf(os.Stderr, "usage: websim_serve <site_dir> [--port=N]\n")
		os.Exit(1)
	}
	siteDir := flag.Arg(0)

	// Verify directory exists
	if info, err := os.Stat(siteDir); err != nil || !info.IsDir() {
		fmt.Fprintf(os.Stderr, "error: %s is not a directory\n", siteDir)
		os.Exit(1)
	}

	// Set correct MIME type for .wasm files
	mux := http.NewServeMux()
	fs := http.FileServer(http.Dir(siteDir))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if len(r.URL.Path) > 5 && r.URL.Path[len(r.URL.Path)-5:] == ".wasm" {
			w.Header().Set("Content-Type", "application/wasm")
		}
		fs.ServeHTTP(w, r)
	})

	// Find available port
	listenAddr := fmt.Sprintf(":%d", *port)
	listener, err := net.Listen("tcp", listenAddr)
	if err != nil {
		log.Fatalf("failed to listen: %v", err)
	}
	actualPort := listener.Addr().(*net.TCPAddr).Port

	url := fmt.Sprintf("http://localhost:%d", actualPort)
	fmt.Printf("\n  WebSim running at %s\n", url)
	fmt.Printf("  Press Ctrl+C to stop\n\n")

	// Open browser
	if !*noOpen {
		openBrowser(url)
	}

	// Serve
	if err := http.Serve(listener, mux); err != nil {
		log.Fatal(err)
	}
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "linux":
		cmd = exec.Command("xdg-open", url)
	default:
		return
	}
	_ = cmd.Start()
}
