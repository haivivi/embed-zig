// HTTP Speed Test Server - Go Version
// High performance server for ESP32 HTTP speed testing
//
// Usage: go run server.go
// Or build: go build -o server server.go && ./server

package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultPort = 8080
	chunkSize   = 64 * 1024 // 64KB chunks for streaming
)

// Generate test data (random-ish bytes)
func generateData(size int) []byte {
	data := make([]byte, size)
	for i := range data {
		data[i] = byte((i * 7) % 256)
	}
	return data
}

// Pre-generate common test sizes for faster response
var testData = map[string][]byte{
	"1k":   generateData(1024),
	"10k":  generateData(10 * 1024),
	"100k": generateData(100 * 1024),
	"1m":   generateData(1024 * 1024),
	"10m":  generateData(10 * 1024 * 1024),
}

func testHandler(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/test/")
	
	var data []byte
	var size int
	
	// Check if it's a predefined size
	if pregenerated, ok := testData[path]; ok {
		data = pregenerated
		size = len(data)
	} else {
		// Parse as bytes count
		var err error
		size, err = strconv.Atoi(path)
		if err != nil || size <= 0 {
			http.Error(w, "Invalid size", http.StatusBadRequest)
			return
		}
		// For large sizes, stream the data
		if size > 10*1024*1024 {
			streamLargeData(w, size)
			return
		}
		data = generateData(size)
	}
	
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(size))
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(data)
}

func streamLargeData(w http.ResponseWriter, size int) {
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(size))
	w.Header().Set("Cache-Control", "no-cache")
	
	chunk := generateData(chunkSize)
	written := 0
	
	for written < size {
		toWrite := chunkSize
		if written+toWrite > size {
			toWrite = size - written
		}
		n, err := w.Write(chunk[:toWrite])
		if err != nil {
			log.Printf("Write error after %d bytes: %v", written, err)
			return
		}
		written += n
		
		// Flush periodically for better streaming
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
}

func infoHandler(w http.ResponseWriter, r *http.Request) {
	info := map[string]interface{}{
		"server": "ESP32 HTTP Speed Test Server (Go)",
		"endpoints": []string{
			"/test/1k",
			"/test/10k", 
			"/test/100k",
			"/test/1m",
			"/test/10m",
			"/test/<bytes>",
		},
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(info)
}

func getLocalIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "0.0.0.0"
	}
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
			if ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	return "0.0.0.0"
}

func main() {
	port := defaultPort
	if len(os.Args) > 1 {
		if p, err := strconv.Atoi(os.Args[1]); err == nil {
			port = p
		}
	}
	
	localIP := getLocalIP()
	
	http.HandleFunc("/test/", testHandler)
	http.HandleFunc("/info", infoHandler)
	
	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", port),
		ReadTimeout:  5 * time.Minute,
		WriteTimeout: 5 * time.Minute,
		IdleTimeout:  2 * time.Minute,
	}
	
	fmt.Println("==========================================")
	fmt.Println("  HTTP Speed Test Server (Go)")
	fmt.Println("==========================================")
	fmt.Printf("Local IP: %s\n", localIP)
	fmt.Printf("Listening on: http://0.0.0.0:%d\n", port)
	fmt.Println()
	fmt.Println("Endpoints:")
	fmt.Println("  /info          - Server info")
	fmt.Println("  /test/1k       - Download 1KB")
	fmt.Println("  /test/10k      - Download 10KB")
	fmt.Println("  /test/100k     - Download 100KB")
	fmt.Println("  /test/1m       - Download 1MB")
	fmt.Println("  /test/10m      - Download 10MB")
	fmt.Println("  /test/<bytes>  - Download custom size")
	fmt.Println()
	fmt.Printf("For ESP32, set CONFIG_TEST_SERVER_IP=\"%s\"\n", localIP)
	fmt.Println("==========================================")
	
	log.Fatal(server.ListenAndServe())
}
