// mqtt_client — Go MQTT client for cross-testing with Zig mqtt0 broker.
//
// Usage:
//   go run . [-addr tcp://127.0.0.1:1883] [-id test-go-client] [-topic test/#] [-pub test/hello] [-msg hello]
//
// Modes:
//   - Subscribe mode (default): subscribes and prints received messages
//   - Publish mode (-pub): publishes a message then exits
//   - Both: subscribes, publishes, receives echo
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/haivivi/giztoy/go/pkg/mqtt0"
)

func main() {
	addr := flag.String("addr", "tcp://127.0.0.1:1883", "Broker address")
	clientID := flag.String("id", "test-go-client", "Client ID")
	subTopic := flag.String("topic", "test/#", "Subscribe topic (empty to skip)")
	pubTopic := flag.String("pub", "", "Publish topic (empty to skip)")
	pubMsg := flag.String("msg", "hello from Go", "Publish message")
	v5 := flag.Bool("v5", false, "Use MQTT 5.0 (default: 3.1.1)")
	flag.Parse()

	version := mqtt0.ProtocolV4
	if *v5 {
		version = mqtt0.ProtocolV5
	}

	ctx := context.Background()

	client, err := mqtt0.Connect(ctx, mqtt0.ClientConfig{
		Addr:            *addr,
		ClientID:        *clientID,
		ProtocolVersion: version,
		KeepAlive:       30,
	})
	if err != nil {
		log.Fatalf("Connect failed: %v", err)
	}
	defer client.Close()

	fmt.Printf("Connected to %s as %s (v%d)\n", *addr, *clientID, version)

	// Subscribe
	if *subTopic != "" {
		if err := client.Subscribe(ctx, *subTopic); err != nil {
			log.Fatalf("Subscribe failed: %v", err)
		}
		fmt.Printf("Subscribed to: %s\n", *subTopic)
	}

	// Publish
	if *pubTopic != "" {
		if err := client.Publish(ctx, *pubTopic, []byte(*pubMsg)); err != nil {
			log.Fatalf("Publish failed: %v", err)
		}
		fmt.Printf("Published: %s -> %s\n", *pubTopic, *pubMsg)

		// If no subscription, exit after publish
		if *subTopic == "" {
			return
		}
	}

	// Receive loop
	if *subTopic != "" {
		fmt.Println("Waiting for messages (Ctrl+C to quit)...")

		// Graceful shutdown
		ctx, cancel := context.WithCancel(ctx)
		go func() {
			sigCh := make(chan os.Signal, 1)
			signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
			<-sigCh
			cancel()
		}()

		for {
			msg, err := client.RecvTimeout(2 * time.Second)
			if err != nil {
				if ctx.Err() != nil {
					fmt.Println("\nStopped.")
					return
				}
				log.Printf("Recv error: %v", err)
				return
			}
			if msg != nil {
				fmt.Printf("[MSG] topic=%s payload=%s retain=%v\n",
					msg.Topic, string(msg.Payload), msg.Retain)
			}
			if ctx.Err() != nil {
				fmt.Println("\nStopped.")
				return
			}
		}
	}
}
