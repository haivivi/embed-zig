# TLS Integration Test Makefile
#
# Usage:
#   make server     - Start the Go test server
#   make test       - Run Zig client tests (requires server running)
#   make test-all   - Start server, run tests, stop server
#   make clean      - Clean build artifacts

.PHONY: server test test-all clean

# Go server
server:
	cd server && go run main.go

# Build and run Zig tests
test:
	cd .. && zig build test --summary all

# Full integration test (starts server, runs tests, stops server)
test-all:
	@echo "=== TLS Integration Test ==="
	@echo ""
	@echo "Starting TLS test server..."
	@cd server && go run main.go &
	@sleep 2
	@echo ""
	@echo "Running Zig client tests..."
	@cd .. && zig test test/tls_test.zig --dep tls --dep trait --dep crypto \
		-Mtls=src/tls.zig \
		-Mtrait=../trait/src/trait.zig \
		-Mcrypto=../crypto/src/crypto.zig \
		2>&1 || true
	@echo ""
	@echo "Stopping server..."
	@pkill -f "go run main.go" || true
	@echo "Done."

# Clean
clean:
	rm -rf server/*.test
	cd .. && rm -rf .zig-cache zig-out
