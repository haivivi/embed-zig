// HTTPS Speed Test Server with TLS 1.2 (ESP32 compatible)
package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const httpsPort = 8443

func main() {
	// Find certificates
	execPath, _ := os.Executable()
	execDir := filepath.Dir(execPath)
	certFile := filepath.Join(execDir, "certs", "server.crt")
	keyFile := filepath.Join(execDir, "certs", "server.key")

	// Check if certs exist in exec dir, fallback to current dir
	if _, err := os.Stat(certFile); os.IsNotExist(err) {
		certFile = "certs/server.crt"
		keyFile = "certs/server.key"
	}

	fmt.Println("HTTPS Speed Test Server (TLS 1.2)")
	fmt.Printf("Cert: %s\n", certFile)
	fmt.Printf("Key:  %s\n", keyFile)

	http.HandleFunc("/test/", handleTest)
	http.HandleFunc("/info", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"server":"HTTPS Speed Test","port":%d}`, httpsPort)
	})

	fmt.Printf("Listening on :%d\n", httpsPort)
	fmt.Println("Endpoints: /test/10m, /test/50m, /test/<bytes>")

	// TLS 1.2 config for ESP32 compatibility
	tlsCfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
		MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{
			tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
			tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
			tls.TLS_RSA_WITH_AES_128_GCM_SHA256,
			tls.TLS_RSA_WITH_AES_256_GCM_SHA384,
			tls.TLS_RSA_WITH_AES_128_CBC_SHA,
			tls.TLS_RSA_WITH_AES_256_CBC_SHA,
		},
	}

	server := &http.Server{
		Addr:         fmt.Sprintf(":%d", httpsPort),
		TLSConfig:    tlsCfg,
		TLSNextProto: make(map[string]func(*http.Server, *tls.Conn, http.Handler)), // Disable HTTP/2
	}

	log.Fatal(server.ListenAndServeTLS(certFile, keyFile))
}

func handleTest(w http.ResponseWriter, r *http.Request) {
	sizeStr := strings.TrimPrefix(r.URL.Path, "/test/")

	var size int
	switch sizeStr {
	case "10m":
		size = 10 * 1024 * 1024
	case "50m":
		size = 50 * 1024 * 1024
	default:
		var err error
		size, err = strconv.Atoi(sizeStr)
		if err != nil || size > 100*1024*1024 {
			http.Error(w, "Invalid size", http.StatusBadRequest)
			return
		}
	}

	log.Printf("[%s] GET /test/%s", r.RemoteAddr, sizeStr)

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.Itoa(size))

	// Send in 4KB chunks for ESP32 TLS compatibility
	chunk := make([]byte, 4*1024)
	flusher, canFlush := w.(http.Flusher)

	for size > 0 {
		n := len(chunk)
		if size < n {
			n = size
		}
		_, err := w.Write(chunk[:n])
		if err != nil {
			log.Printf("[%s] Write error: %v", r.RemoteAddr, err)
			return
		}
		size -= n
		if canFlush {
			flusher.Flush()
		}
	}
}
