// TLS Test Server
//
// A comprehensive TLS test server that covers:
// - TLS 1.2 and TLS 1.3
// - Multiple cipher suites (AES-GCM, ChaCha20-Poly1305)
// - Multiple key types (RSA, ECDSA P-256, ECDSA P-384)
// - Multiple curves for key exchange (X25519, P-256, P-384)
// - Extensions: SNI, ALPN
// - Large data transfer tests
//
// Usage:
//   go run main.go [options]

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
	Name         string
	MinVersion   uint16
	MaxVersion   uint16
	CipherSuites []uint16 // Empty means use defaults
	CurvePrefs   []tls.CurveID
	KeyType      string // "rsa", "ecdsa-p256", "ecdsa-p384"
	ALPN         []string
	RequireSNI   bool
}

var testCases = []TestCase{
	// ==========================================
	// TLS 1.3 Tests
	// ==========================================

	// TLS 1.3 with different cipher suites
	{Name: "tls13_aes128gcm", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		CipherSuites: []uint16{tls.TLS_AES_128_GCM_SHA256}, KeyType: "ecdsa-p256"},
	{Name: "tls13_aes256gcm", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		CipherSuites: []uint16{tls.TLS_AES_256_GCM_SHA384}, KeyType: "ecdsa-p256"},
	{Name: "tls13_chacha20", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		CipherSuites: []uint16{tls.TLS_CHACHA20_POLY1305_SHA256}, KeyType: "ecdsa-p256"},

	// TLS 1.3 with different curves
	{Name: "tls13_x25519", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		CurvePrefs: []tls.CurveID{tls.X25519}, KeyType: "ecdsa-p256"},
	{Name: "tls13_p256", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		CurvePrefs: []tls.CurveID{tls.CurveP256}, KeyType: "ecdsa-p256"},
	{Name: "tls13_p384", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		CurvePrefs: []tls.CurveID{tls.CurveP384}, KeyType: "ecdsa-p384"},

	// ==========================================
	// TLS 1.2 ECDSA Tests
	// ==========================================

	// TLS 1.2 ECDSA P-256
	{Name: "tls12_ecdsa_p256_aes128", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256}, KeyType: "ecdsa-p256"},
	{Name: "tls12_ecdsa_p256_aes256", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384}, KeyType: "ecdsa-p256"},
	{Name: "tls12_ecdsa_p256_chacha20", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256}, KeyType: "ecdsa-p256"},

	// TLS 1.2 ECDSA P-384
	{Name: "tls12_ecdsa_p384_aes256", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384}, KeyType: "ecdsa-p384"},

	// ==========================================
	// TLS 1.2 RSA Tests
	// ==========================================

	{Name: "tls12_rsa_aes128", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256}, KeyType: "rsa"},
	{Name: "tls12_rsa_aes256", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384}, KeyType: "rsa"},
	{Name: "tls12_rsa_chacha20", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CipherSuites: []uint16{tls.TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256}, KeyType: "rsa"},

	// ==========================================
	// TLS 1.2 Curve Tests
	// ==========================================

	{Name: "tls12_curve_x25519", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CurvePrefs: []tls.CurveID{tls.X25519}, KeyType: "ecdsa-p256"},
	{Name: "tls12_curve_p256", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CurvePrefs: []tls.CurveID{tls.CurveP256}, KeyType: "ecdsa-p256"},
	{Name: "tls12_curve_p384", MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12,
		CurvePrefs: []tls.CurveID{tls.CurveP384}, KeyType: "ecdsa-p384"},

	// ==========================================
	// Extension Tests
	// ==========================================

	// SNI test (requires correct hostname)
	{Name: "ext_sni_required", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		KeyType: "ecdsa-p256", RequireSNI: true},

	// ALPN tests
	{Name: "ext_alpn_h2", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		KeyType: "ecdsa-p256", ALPN: []string{"h2", "http/1.1"}},
	{Name: "ext_alpn_http11", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		KeyType: "ecdsa-p256", ALPN: []string{"http/1.1"}},

	// ==========================================
	// Data Transfer Tests
	// ==========================================

	// Large data test (for testing record layer)
	{Name: "data_large_transfer", MinVersion: tls.VersionTLS13, MaxVersion: tls.VersionTLS13,
		KeyType: "ecdsa-p256"},
}

// CertBundle holds CA and server certificates for a specific key type
type CertBundle struct {
	KeyType    string
	CACert     *x509.Certificate
	CACertPEM  []byte
	CAKey      interface{}
	ServerCert tls.Certificate
}

var certBundles map[string]*CertBundle

func main() {
	port := flag.Int("port", 8443, "Base server port")
	caOut := flag.String("ca-out", "", "Write CA certs to directory")
	listTests := flag.Bool("list", false, "List all test cases")
	flag.Parse()

	// List tests and exit
	if *listTests {
		fmt.Println("Available test cases:")
		for i, tc := range testCases {
			fmt.Printf("  [%2d] %-30s port=%d version=%s key=%s\n",
				i, tc.Name, *port+i, versionName(tc.MaxVersion), tc.KeyType)
		}
		return
	}

	log.Println("TLS Test Server - Comprehensive Test Suite")
	log.Println("==========================================")

	// Generate certificates for all key types
	log.Println("\nGenerating certificates...")
	certBundles = make(map[string]*CertBundle)

	keyTypes := []string{"rsa", "ecdsa-p256", "ecdsa-p384"}
	for _, keyType := range keyTypes {
		bundle, err := generateCertBundle(keyType)
		if err != nil {
			log.Fatalf("Failed to generate %s certificates: %v", keyType, err)
		}
		certBundles[keyType] = bundle
		log.Printf("  ✓ %s certificates generated", keyType)
	}

	// Write CA certs if requested
	if *caOut != "" {
		os.MkdirAll(*caOut, 0755)
		for keyType, bundle := range certBundles {
			path := fmt.Sprintf("%s/ca_%s.pem", *caOut, keyType)
			if err := os.WriteFile(path, bundle.CACertPEM, 0644); err != nil {
				log.Printf("  Warning: failed to write %s: %v", path, err)
			} else {
				log.Printf("  CA cert written to %s", path)
			}
		}
	}

	// Start servers
	var wg sync.WaitGroup
	basePort := *port

	log.Println("\nStarting test servers:")
	log.Println("─────────────────────────────────────────────────────────────")

	// Group by category
	categories := map[string][]int{
		"TLS 1.3 Ciphers":    {},
		"TLS 1.3 Curves":     {},
		"TLS 1.2 ECDSA":      {},
		"TLS 1.2 RSA":        {},
		"TLS 1.2 Curves":     {},
		"Extensions":         {},
		"Data Transfer":      {},
	}

	for i, tc := range testCases {
		switch {
		case strings.HasPrefix(tc.Name, "tls13_aes") || strings.HasPrefix(tc.Name, "tls13_chacha"):
			categories["TLS 1.3 Ciphers"] = append(categories["TLS 1.3 Ciphers"], i)
		case strings.HasPrefix(tc.Name, "tls13_x25519") || strings.HasPrefix(tc.Name, "tls13_p"):
			categories["TLS 1.3 Curves"] = append(categories["TLS 1.3 Curves"], i)
		case strings.HasPrefix(tc.Name, "tls12_ecdsa"):
			categories["TLS 1.2 ECDSA"] = append(categories["TLS 1.2 ECDSA"], i)
		case strings.HasPrefix(tc.Name, "tls12_rsa"):
			categories["TLS 1.2 RSA"] = append(categories["TLS 1.2 RSA"], i)
		case strings.HasPrefix(tc.Name, "tls12_curve"):
			categories["TLS 1.2 Curves"] = append(categories["TLS 1.2 Curves"], i)
		case strings.HasPrefix(tc.Name, "ext_"):
			categories["Extensions"] = append(categories["Extensions"], i)
		case strings.HasPrefix(tc.Name, "data_"):
			categories["Data Transfer"] = append(categories["Data Transfer"], i)
		}
	}

	// Print categorized test cases
	catOrder := []string{"TLS 1.3 Ciphers", "TLS 1.3 Curves", "TLS 1.2 ECDSA", "TLS 1.2 RSA", "TLS 1.2 Curves", "Extensions", "Data Transfer"}
	for _, cat := range catOrder {
		indices := categories[cat]
		if len(indices) == 0 {
			continue
		}
		log.Printf("\n  %s:", cat)
		for _, i := range indices {
			tc := testCases[i]
			log.Printf("    [%2d] %-30s port=%d", i, tc.Name, basePort+i)
		}
	}

	// Start all servers
	for i, tc := range testCases {
		bundle := certBundles[tc.KeyType]
		if bundle == nil {
			log.Printf("Warning: no cert bundle for %s", tc.KeyType)
			continue
		}

		serverPort := basePort + i
		wg.Add(1)
		go func(tc TestCase, port int, bundle *CertBundle) {
			defer wg.Done()
			runTestServer(tc, port, bundle)
		}(tc, serverPort, bundle)
	}

	// Print test commands
	log.Println("\n─────────────────────────────────────────────────────────────")
	log.Println("Test commands (curl):")
	log.Printf("  curl -k https://localhost:%d/test", basePort)
	log.Println("\nPress Ctrl+C to stop...")
	wg.Wait()
}

func versionName(v uint16) string {
	switch v {
	case tls.VersionTLS12:
		return "TLS1.2"
	case tls.VersionTLS13:
		return "TLS1.3"
	default:
		return fmt.Sprintf("0x%04x", v)
	}
}

func generateCertBundle(keyType string) (*CertBundle, error) {
	var curve elliptic.Curve
	var caKey, serverKey interface{}
	var err error

	switch keyType {
	case "rsa":
		caKey, err = rsa.GenerateKey(rand.Reader, 2048)
		if err != nil {
			return nil, err
		}
		serverKey, err = rsa.GenerateKey(rand.Reader, 2048)
	case "ecdsa-p256":
		curve = elliptic.P256()
		caKey, err = ecdsa.GenerateKey(curve, rand.Reader)
		if err != nil {
			return nil, err
		}
		serverKey, err = ecdsa.GenerateKey(curve, rand.Reader)
	case "ecdsa-p384":
		curve = elliptic.P384()
		caKey, err = ecdsa.GenerateKey(curve, rand.Reader)
		if err != nil {
			return nil, err
		}
		serverKey, err = ecdsa.GenerateKey(curve, rand.Reader)
	default:
		return nil, fmt.Errorf("unknown key type: %s", keyType)
	}
	if err != nil {
		return nil, err
	}

	// CA certificate
	caTemplate := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			Organization: []string{"Zig TLS Test CA"},
			CommonName:   fmt.Sprintf("Zig TLS Test CA (%s)", keyType),
		},
		NotBefore:             time.Now(),
		NotAfter:              time.Now().Add(24 * time.Hour),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            1,
	}

	caPublicKey := publicKey(caKey)
	caCertDER, err := x509.CreateCertificate(rand.Reader, caTemplate, caTemplate, caPublicKey, caKey)
	if err != nil {
		return nil, err
	}

	caCert, _ := x509.ParseCertificate(caCertDER)
	caCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caCertDER})

	// Server certificate
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
		DNSNames:    []string{"localhost", "test.local"},
		IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}

	serverCertDER, err := x509.CreateCertificate(rand.Reader, serverTemplate, caCert, publicKey(serverKey), caKey)
	if err != nil {
		return nil, err
	}

	serverCertPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: serverCertDER})
	serverKeyPEM := pemEncodeKey(serverKey)

	serverCert, err := tls.X509KeyPair(serverCertPEM, serverKeyPEM)
	if err != nil {
		return nil, err
	}

	return &CertBundle{
		KeyType:    keyType,
		CACert:     caCert,
		CACertPEM:  caCertPEM,
		CAKey:      caKey,
		ServerCert: serverCert,
	}, nil
}

func publicKey(key interface{}) interface{} {
	switch k := key.(type) {
	case *rsa.PrivateKey:
		return &k.PublicKey
	case *ecdsa.PrivateKey:
		return &k.PublicKey
	default:
		return nil
	}
}

func pemEncodeKey(key interface{}) []byte {
	switch k := key.(type) {
	case *rsa.PrivateKey:
		return pem.EncodeToMemory(&pem.Block{
			Type:  "RSA PRIVATE KEY",
			Bytes: x509.MarshalPKCS1PrivateKey(k),
		})
	case *ecdsa.PrivateKey:
		b, _ := x509.MarshalECPrivateKey(k)
		return pem.EncodeToMemory(&pem.Block{
			Type:  "EC PRIVATE KEY",
			Bytes: b,
		})
	default:
		return nil
	}
}

func runTestServer(tc TestCase, port int, bundle *CertBundle) {
	// Create key log file for debugging
	keyLogFile, _ := os.OpenFile("/tmp/tls_keys.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)

	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{bundle.ServerCert},
		MinVersion:   tc.MinVersion,
		MaxVersion:   tc.MaxVersion,
		KeyLogWriter: keyLogFile,
	}

	if len(tc.CipherSuites) > 0 {
		tlsConfig.CipherSuites = tc.CipherSuites
	}

	if len(tc.CurvePrefs) > 0 {
		tlsConfig.CurvePreferences = tc.CurvePrefs
	}

	if len(tc.ALPN) > 0 {
		tlsConfig.NextProtos = tc.ALPN
	}

	// SNI verification callback
	if tc.RequireSNI {
		tlsConfig.GetConfigForClient = func(hello *tls.ClientHelloInfo) (*tls.Config, error) {
			if hello.ServerName == "" {
				return nil, fmt.Errorf("SNI required but not provided")
			}
			if hello.ServerName != "localhost" && hello.ServerName != "test.local" {
				return nil, fmt.Errorf("unknown server name: %s", hello.ServerName)
			}
			return nil, nil // Use default config
		}
	}

	listener, err := tls.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port), tlsConfig)
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

	// Set deadline
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	// Complete handshake
	if err := tlsConn.Handshake(); err != nil {
		log.Printf("[%s] Handshake failed: %v", tc.Name, err)
		return
	}

	state := tlsConn.ConnectionState()
	log.Printf("[%s] Connected: version=0x%04x cipher=0x%04x alpn=%s sni=%s",
		tc.Name, state.Version, state.CipherSuite,
		state.NegotiatedProtocol, state.ServerName)

	// Read request
	buf := make([]byte, 65536)
	n, err := conn.Read(buf)
	if err != nil && err != io.EOF {
		return
	}

	request := string(buf[:n])

	// Handle different test endpoints
	var response string

	switch {
	case strings.HasPrefix(request, "GET /test"):
		// Standard test endpoint
		body := fmt.Sprintf(`{
  "test": "%s",
  "version": "0x%04x",
  "version_name": "%s",
  "cipher": "0x%04x",
  "cipher_name": "%s",
  "alpn": "%s",
  "sni": "%s",
  "key_type": "%s",
  "ok": true
}`,
			tc.Name,
			state.Version, versionName(state.Version),
			state.CipherSuite, tls.CipherSuiteName(state.CipherSuite),
			state.NegotiatedProtocol,
			state.ServerName,
			tc.KeyType)
		response = httpResponse(200, "application/json", body)

	case strings.HasPrefix(request, "GET /large"):
		// Large data transfer test (1MB)
		data := strings.Repeat("X", 1024*1024)
		response = httpResponse(200, "application/octet-stream", data)

	case strings.HasPrefix(request, "GET /echo"):
		// Echo test
		response = httpResponse(200, "text/plain", request)

	case strings.HasPrefix(request, "PING"):
		// Simple ping/pong
		response = "PONG\n"

	default:
		response = httpResponse(404, "text/plain", "Not Found")
	}

	conn.Write([]byte(response))
}

func httpResponse(status int, contentType, body string) string {
	statusText := "OK"
	switch status {
	case 404:
		statusText = "Not Found"
	case 500:
		statusText = "Internal Server Error"
	}

	return fmt.Sprintf("HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s",
		status, statusText, contentType, len(body), body)
}
