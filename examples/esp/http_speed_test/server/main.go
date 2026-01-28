// HTTP Speed Test Server
package main

import (
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
)

const httpPort = 8080

func main() {
	http.HandleFunc("/test/", handleTest)
	http.HandleFunc("/info", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `{"server":"HTTP Speed Test","port":%d}`, httpPort)
	})

	fmt.Println("HTTP Speed Test Server")
	fmt.Printf("Listening on :%d\n", httpPort)
	fmt.Println("Endpoints: /test/10m, /test/50m, /test/<bytes>")

	log.Fatal(http.ListenAndServe(fmt.Sprintf(":%d", httpPort), nil))
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

	chunk := make([]byte, 16*1024)
	for size > 0 {
		n := len(chunk)
		if size < n {
			n = size
		}
		w.Write(chunk[:n])
		size -= n
	}
}
