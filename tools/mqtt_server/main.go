// mqtt_server — Go MQTT broker for cross-testing with Zig mqtt0.
//
// Uses mochi-mqtt (pure Go broker). Supports MQTT 3.1.1 and 5.0.
//
// Usage:
//   go run . [-addr :1883]
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"

	mqtt "github.com/mochi-mqtt/server/v2"
	"github.com/mochi-mqtt/server/v2/hooks/auth"
	"github.com/mochi-mqtt/server/v2/listeners"
)

func main() {
	addr := flag.String("addr", ":1883", "Listen address")
	flag.Parse()

	server := mqtt.New(&mqtt.Options{
		InlineClient: true,
	})

	// Allow all connections
	if err := server.AddHook(new(auth.AllowHook), nil); err != nil {
		log.Fatal(err)
	}

	// Add TCP listener
	tcp := listeners.NewTCP(listeners.Config{
		ID:      "tcp",
		Address: *addr,
	})
	if err := server.AddListener(tcp); err != nil {
		log.Fatal(err)
	}

	// Start
	go func() {
		if err := server.Serve(); err != nil {
			log.Fatal(err)
		}
	}()

	fmt.Printf("MQTT broker listening on %s (v3.1.1 + v5.0)\n", *addr)

	// Wait for signal
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	server.Close()
	fmt.Println("Broker stopped")
}
