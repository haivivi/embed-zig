// TLS Test Server
//
// A multi-protocol TLS test server that generates its own CA and server certificates.
// Used for testing the pure Zig TLS client implementation.
//
// Usage:
//   go run main.go [options]
//
// Options:
//   -port PORT        Server port (default: 8443)
//   -ca-out PATH      Write CA cert to file
//   -cert-out PATH    Write server cert to file
//   -key-out PATH     Write server key to file

package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
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
	"strings"
	"sync"
	"time"
)

// TestCase represents a TLS test scenario
type TestCase struct {
	Name        string
	MinVersion  uint16
	MaxVersion  uint16
	CipherSuite uint16 // 0 means use default
	KeyType     string // "rsa" or "ecdsa"
}

var testCases = []TestCase{
	// TLS 1.3 tests
	{Name: "tls13_aes128gcm", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, KeyType: "ecdsa"},
	{Name: "tls13_aes256gcm", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, KeyType: "ecdsa"},
	{Name: "tls13_chacha20", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13, KeyType: "ecdsa"},

	// TLS 1.2 tests with ECDSA
	{Name: "tls12_ecdhe_ecdsa_aes128", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuite: tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256, KeyType: "ecdsa"},
	{Name: "tls12_ecdhe_ecdsa_aes256", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuite: tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384, KeyType: "ecdsa"},
	{Name: "tls12_ecdhe_ecdsa_chacha20", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuite: tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256, KeyType: "ecdsa"},

	// TLS 1.2 tests with RSA
	{Name: "tls12_ecdhe_rsa_aes128", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuite: tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256, KeyType: "rsa"},
	{Name: "tls12_ecdhe_rsa_aes256", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuite: tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, KeyType: "rsa"},
	{Name: "tls12_ecdhe_rsa_chacha20", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuite: tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256, KeyType: "rsa"},
}

// CertBundle holds CA and server certificates
type CertBundle struct {
	CACert     *x509.Certificate
	CACertPEM  []byte
	CAKey      interface{}
	ServerCert tls.Certificate
}

func main() {
	port := flag.Int("port", 8443, "Server port")
	caOut := flag.String("ca-out", "", "Write CA cert to file")
	_ = flag.String("cert-out", "", "Write server cert to file (not implemented)")
	_ = flag.String("key-out", "", "Write server key to file (not implemented)")
	ecdsaOnly := flag.Bool("ecdsa-only", false, "Only generate ECDSA certificates")
	rsaOnly := flag.Bool("rsa-only", false, "Only generate RSA certificates")
	flag.Parse()

	log.Println("TLS Test Server")
	log.Println("===============")

	// Generate certificates
	log.Println("Generating certificates...")

	var ecdsaBundle, rsaBundle *CertBundle
	var err error

	if !*rsaOnly {
		ecdsaBundle, err = generateCertBundle("ecdsa")
		if err != nil {
			log.Fatalf("Failed to generate ECDSA certificates: %v", err)
		}
		log.Println("  ECDSA certificates generated")
	}

	if !*ecdsaOnly {
		rsaBundle, err = generateCertBundle("rsa")
		if err != nil {
			log.Fatalf("Failed to generate RSA certificates: %v", err)
		}
		log.Println("  RSA certificates generated")
	}

	// Write certificates to files if requested
	if *caOut != "" && ecdsaBundle != nil {
		if err := os.WriteFile(*caOut, ecdsaBundle.CACertPEM, 0644); err != nil {
			log.Fatalf("Failed to write CA cert: %v", err)
		}
		log.Printf("  CA cert written to %s", *caOut)
	}

	// Start servers for each test case
	var wg sync.WaitGroup
	basePort := *port

	log.Println("\nStarting test servers:")

	for i, tc := range testCases {
		// Skip based on flags
		if *ecdsaOnly && tc.KeyType == "rsa" {
			continue
		}
		if *rsaOnly && tc.KeyType == "ecdsa" {
			continue
		}

		var bundle *CertBundle
		if tc.KeyType == "ecdsa" {
			bundle = ecdsaBundle
		} else {
			bundle = rsaBundle
		}

		if bundle == nil {
			continue
		}

		serverPort := basePort + i
		wg.Add(1)
		go func(tc TestCase, port int, bundle *CertBundle) {
			defer wg.Done()
			runTestServer(tc, port, bundle)
		}(tc, serverPort, bundle)

		log.Printf("  [%d] %s on port %d", i, tc.Name, serverPort)
	}

	// Print test info
	log.Println("\nTest server ready. Test cases:")
	for i, tc := range testCases {
		if (*ecdsaOnly && tc.KeyType == "rsa") || (*rsaOnly && tc.KeyType == "ecdsa") {
			continue
		}
		log.Printf("  curl -k https://localhost:%d/test  # %s", basePort+i, tc.Name)
	}

	log.Println("\nPress Ctrl+C to stop...")
	wg.Wait()
}

func generateCertBundle(keyType string) (*CertBundle, error) {
	// Generate CA key
	var caKey interface{}
	var err error

	if keyType == "ecdsa" {
		caKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	} else {
		caKey, err = rsa.GenerateKey(rand.Reader, 2048)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to generate CA key: %v", err)
	}

	// Generate CA certificate
	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Zig TLS Test CA"},
			CommonName:   "Zig TLS Test CA",
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            1,
	}

	var caPublicKey interface{}
	if keyType == "ecdsa" {
		caPublicKey = &caKey.(*ecdsa.PrivateKey).PublicKey
	} else {
		caPublicKey = &caKey.(*rsa.PrivateKey).PublicKey
	}

	caCertDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, caPublicKey, caKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create CA certificate: %v", err)
	}

	caCert, err := x509.ParseCertificate(caCertDER)
	if err != nil {
		return nil, fmt.Errorf("failed to parse CA certificate: %v", err)
	}

	caCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCertDER})

	// Generate server key
	var serverKey interface{}
	if keyType == "ecdsa" {
		serverKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	} else {
		serverKey, err = rsa.GenerateKey(rand.Reader, 2048)
	}
	if err != nil {
		return nil, fmt.Errorf("failed to generate server key: %v", err)
	}

	// Generate server certificate
	serverTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			Organization: []string{"Zig TLS Test Server"},
			CommonName:   "localhost",
		},
		NotBefore:   time.Now(),
		NotAfter:    time.Now().Add(24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:    []string{"localhost", "127.0.0.1"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}

	var serverPublicKey interface{}
	if keyType == "ecdsa" {
		serverPublicKey = &serverKey.(*ecdsa.PrivateKey).PublicKey
	} else {
		serverPublicKey = &serverKey.(*rsa.PrivateKey).PublicKey
	}

	serverCertDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caCert, serverPublicKey, caKey)
	if err != nil {
		return nil, fmt.Errorf("failed to create server certificate: %v", err)
	}

	serverCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverCertDER})

	var serverKeyPEM []byte
	if keyType == "ecdsa" {
		keyBytes, _ := x509.MarshalECPrivateKey(serverKey.(*ecdsa.PrivateKey))
		serverKeyPEM = pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	} else {
		serverKeyPEM = pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(serverKey.(*rsa.PrivateKey))})
	}

	serverCert, err := tls.X509KeyPair(serverCertPEM, serverKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("failed to create server TLS certificate: %v", err)
	}

	return &CertBundle{
		CACert:     caCert,
		CACertPEM:  caCertPEM,
		CAKey:      caKey,
		ServerCert: serverCert,
	}, nil
}

func runTestServer(tc TestCase, port int, bundle *CertBundle) {
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{bundle.ServerCert},
		MinVersion:   tc.MinVersion,
		MaxVersion:   tc.MaxVersion,
	}

	if tc.CipherSuite != 0 {
		tlsConfig.CipherSuites = []uint16{tc.CipherSuite}
	}

	listener, err := tls.Listen("tcp", fmt.Sprintf(":%d", port), tlsConfig)
	if err != nil {
		log.Printf("[%s] Failed to start: %v", tc.Name, err)
		return
	}
	defer listener.Close()

	for {
		conn, err := listener.Accept()
		if err != nil {
			continue
		}
		go handleConnection(conn, tc)
	}
}

func handleConnection(conn net.Conn, tc TestCase) {
	defer conn.Close()

	tlsConn, ok := conn.(*tls.Conn)
	if !ok {
		return
	}

	// Complete handshake
	if err := tlsConn.Handshake(); err != nil {
		log.Printf("[%s] Handshake failed: %v", tc.Name, err)
		return
	}

	state := tlsConn.ConnectionState()
	log.Printf("[%s] Connection: version=0x%04x cipher=0x%04x",
		tc.Name, state.Version, state.CipherSuite)

	// Read request
	buf := make([]byte, 4096)
	n, err := conn.Read(buf)
	if err != nil && err != io.EOF {
		return
	}

	request := string(buf[:n])

	// Simple HTTP response
	var response string
	if strings.HasPrefix(request, "GET /test") || strings.HasPrefix(request, "GET / ") {
		body := fmt.Sprintf(`{"test":"%s","version":"0x%04x","cipher":"0x%04x","ok":true}`,
			tc.Name, state.Version, state.CipherSuite)
		response = fmt.Sprintf("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
			len(body), body)
	} else if strings.HasPrefix(request, "PING") {
		// Simple ping/pong for basic connectivity test
		response = "PONG\n"
	} else {
		response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
	}

	conn.Write([]byte(response))
}
