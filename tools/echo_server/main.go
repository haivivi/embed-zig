// Echo Server for TCP/TLS Duplex Testing
//
// Tests TCP and TLS echo functionality:
// - TCP echo on port 8080: receives data and echoes back immediately
// - TLS echo on port 8443: same but with TLS encryption
//
// Usage:
//   go run main.go [-tcp-port 8080] [-tls-port 8443]

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"os"
	"time"
)

func main() {
	tcpPort := flag.Int("tcp-port", 8080, "TCP echo server port")
	tlsPort := flag.Int("tls-port", 8443, "TLS echo server port")
	caOut := flag.String("ca-out", "", "Write CA cert to file (for client verification)")
	flag.Parse()

	log.Println("========================================")
	log.Println("  Echo Server - TCP/TLS Duplex Test")
	log.Println("========================================")

	// Generate TLS certificates
	log.Println("\nGenerating certificates...")
	cert, caCertPEM, err := generateCert()
	if err != nil {
		log.Fatalf("Failed to generate certificates: %v", err)
	}
	log.Println("  Certificates generated")

	// Write CA cert if requested
	if *caOut != "" {
		if err := os.WriteFile(*caOut, caCertPEM, 0644); err != nil {
			log.Printf("  Warning: failed to write CA cert: %v", err)
		} else {
			log.Printf("  CA cert written to: %s", *caOut)
		}
	}

	// Start TCP echo server
	go runTCPServer(*tcpPort)

	// Start TLS echo server
	go runTLSServer(*tlsPort, cert)

	// Print local IP addresses
	log.Println("\n----------------------------------------")
	addrs, _ := net.InterfaceAddrs()
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
			log.Printf("  Local IP: %s", ipnet.IP.String())
		}
	}
	log.Printf("  TCP Echo: 0.0.0.0:%d", *tcpPort)
	log.Printf("  TLS Echo: 0.0.0.0:%d", *tlsPort)
	log.Println("----------------------------------------")
	log.Println("\nProtocol: Send any data, receive same data back")
	log.Println("Press Ctrl+C to stop...")

	// Block forever
	select {}
}

func runTCPServer(port int) {
	addr := fmt.Sprintf("0.0.0.0:%d", port)
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("[TCP] Failed to listen on %s: %v", addr, err)
	}
	defer listener.Close()

	log.Printf("[TCP] Listening on %s", addr)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("[TCP] Accept error: %v", err)
			continue
		}
		go handleConnection(conn, "TCP")
	}
}

func runTLSServer(port int, cert tls.Certificate) {
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	addr := fmt.Sprintf("0.0.0.0:%d", port)
	listener, err := tls.Listen("tcp", addr, tlsConfig)
	if err != nil {
		log.Fatalf("[TLS] Failed to listen on %s: %v", addr, err)
	}
	defer listener.Close()

	log.Printf("[TLS] Listening on %s", addr)

	for {
		conn, err := listener.Accept()
		if err != nil {
			log.Printf("[TLS] Accept error: %v", err)
			continue
		}
		go handleConnection(conn, "TLS")
	}
}

func handleConnection(conn net.Conn, protocol string) {
	defer conn.Close()

	remoteAddr := conn.RemoteAddr().String()
	log.Printf("[%s] Connected: %s", protocol, remoteAddr)

	// Set read deadline to detect client disconnect
	conn.SetDeadline(time.Now().Add(60 * time.Second))

	buf := make([]byte, 4096)
	totalBytes := 0

	for {
		// Reset deadline for each read
		conn.SetDeadline(time.Now().Add(60 * time.Second))

		n, err := conn.Read(buf)
		if err != nil {
			if err == io.EOF {
				log.Printf("[%s] %s: Connection closed by client (total: %d bytes)", protocol, remoteAddr, totalBytes)
			} else if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				log.Printf("[%s] %s: Read timeout (total: %d bytes)", protocol, remoteAddr, totalBytes)
			} else {
				log.Printf("[%s] %s: Read error: %v", protocol, remoteAddr, err)
			}
			return
		}

		// Echo back immediately
		written, err := conn.Write(buf[:n])
		if err != nil {
			log.Printf("[%s] %s: Write error: %v", protocol, remoteAddr, err)
			return
		}

		totalBytes += written
		log.Printf("[%s] %s: Echo %d bytes (total: %d)", protocol, remoteAddr, written, totalBytes)
	}
}

func generateCert() (tls.Certificate, []byte, error) {
	// Generate CA key
	caKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	// CA certificate template
	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Echo Test CA"},
			CommonName:   "Echo Test CA",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            1,
	}

	// Create CA certificate
	caCertDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	caCert, _ := x509.ParseCertificate(caCertDER)
	caCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCertDER})

	// Generate server key
	serverKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	// Server certificate template
	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			Organization: []string{"Echo Test Server"},
			CommonName:   "localhost",
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(365 * 24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost", "echo.local"},
		IPAddresses: []net.IP{
			net.ParseIP("127.0.0.1"),
			net.ParseIP("::1"),
			net.ParseIP("0.0.0.0"),
		},
	}

	// Create server certificate signed by CA
	serverCertDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caCert, &serverKey.PublicKey, caKey)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	serverCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverCertDER})

	serverKeyBytes, _ := x509.MarshalECPrivateKey(serverKey)
	serverKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: serverKeyBytes})

	cert, err := tls.X509KeyPair(serverCertPEM, serverKeyPEM)
	if err != nil {
		return tls.Certificate{}, nil, err
	}

	return cert, caCertPEM, nil
}
