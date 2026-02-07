module github.com/haivivi/embed-zig/tools/mqtt_client

go 1.25

require github.com/haivivi/giztoy/go v0.0.0

require github.com/gorilla/websocket v1.5.3 // indirect

// Point to a local giztoy checkout. Adjust the path as needed.
// e.g., replace github.com/haivivi/giztoy/go => /path/to/giztoy/go
replace github.com/haivivi/giztoy/go => /tmp/giztoy-mqtt0/go
