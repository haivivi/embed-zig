// mqtt_server — Go MQTT broker for cross-testing with Zig mqtt0 client.
//
// Usage:
//   go run . [-addr :1883] [-v4] [-v5]
//
// Features:
//   - Supports both MQTT 3.1.1 and 5.0 (auto-detection)
//   - Logs all CONNECT/SUBSCRIBE/PUBLISH/DISCONNECT events
//   - AllowAll auth (no authentication)
//   - Useful for testing Zig mqtt0 client against a real broker
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/haivivi/giztoy/go/pkg/mqtt0"
)

func main() {
	addr := flag.String("addr", ":1883", "Listen address")
	flag.Parse()

	broker := &mqtt0.Broker{
		Authenticator: mqtt0.AllowAll{},
		Handler: mqtt0.HandlerFunc(func(clientID string, msg *mqtt0.Message) {
			log.Printf("[MSG] client=%s topic=%s payload=%s retain=%v",
				clientID, msg.Topic, string(msg.Payload), msg.Retain)
		}),
		OnConnect: func(clientID string) {
			log.Printf("[CONNECT] client=%s", clientID)
		},
		OnDisconnect: func(clientID string) {
			log.Printf("[DISCONNECT] client=%s", clientID)
		},
	}

	ln, err := mqtt0.Listen("tcp", *addr, nil)
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	fmt.Printf("MQTT broker listening on %s\n", *addr)
	fmt.Println("Supports MQTT 3.1.1 and 5.0 (auto-detect)")
	fmt.Println("Press Ctrl+C to stop")

	// Graceful shutdown
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		fmt.Println("\nShutting down...")
		broker.Close()
		ln.Close()
		os.Exit(0)
	}()

	if err := broker.Serve(ln); err != nil {
		log.Fatalf("Broker error: %v", err)
	}
}
