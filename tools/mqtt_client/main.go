// mqtt_client — Go MQTT client for cross-testing with Zig mqtt0 broker.
//
// Uses paho.mqtt.golang (standard Go MQTT client).
//
// Usage:
//   go run . [-addr 127.0.0.1:1883] [-id go-client] [-sub test/#] [-pub test/hello] [-msg "hello from Go"] [-v5]
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	pahov3 "github.com/eclipse/paho.mqtt.golang"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:1883", "Broker address (host:port)")
	clientID := flag.String("id", "go-test-client", "Client ID")
	subTopic := flag.String("sub", "", "Subscribe topic (empty to skip)")
	pubTopic := flag.String("pub", "", "Publish topic (empty to skip)")
	pubMsg := flag.String("msg", "hello from Go", "Message payload")
	flag.Parse()

	opts := pahov3.NewClientOptions()
	opts.AddBroker(fmt.Sprintf("tcp://%s", *addr))
	opts.SetClientID(*clientID)
	opts.SetKeepAlive(30 * time.Second)
	opts.SetCleanSession(true)
	opts.SetProtocolVersion(4) // MQTT 3.1.1

	opts.SetDefaultPublishHandler(func(client pahov3.Client, msg pahov3.Message) {
		fmt.Printf("[RECV] topic=%s payload=%s retain=%v\n", msg.Topic(), string(msg.Payload()), msg.Retained())
	})

	client := pahov3.NewClient(opts)
	token := client.Connect()
	if !token.WaitTimeout(10 * time.Second) {
		log.Fatal("Connect timeout")
	}
	if token.Error() != nil {
		log.Fatalf("Connect error: %v", token.Error())
	}
	fmt.Printf("Connected to %s as %s\n", *addr, *clientID)

	// Subscribe
	if *subTopic != "" {
		token := client.Subscribe(*subTopic, 0, nil)
		if !token.WaitTimeout(5 * time.Second) {
			log.Fatal("Subscribe timeout")
		}
		if token.Error() != nil {
			log.Fatalf("Subscribe error: %v", token.Error())
		}
		fmt.Printf("Subscribed to %s\n", *subTopic)
	}

	// Publish
	if *pubTopic != "" {
		token := client.Publish(*pubTopic, 0, false, []byte(*pubMsg))
		if !token.WaitTimeout(5 * time.Second) {
			log.Fatal("Publish timeout")
		}
		if token.Error() != nil {
			log.Fatalf("Publish error: %v", token.Error())
		}
		fmt.Printf("Published to %s: %s\n", *pubTopic, *pubMsg)
	}

	// If no sub topic, exit after publish
	if *subTopic == "" {
		time.Sleep(500 * time.Millisecond)
		client.Disconnect(250)
		return
	}

	// Wait for signal
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	client.Disconnect(250)
	fmt.Println("Disconnected")
}
