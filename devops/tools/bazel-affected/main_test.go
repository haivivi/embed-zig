package main

import (
	"testing"
)

func TestExtractPackage(t *testing.T) {
	tests := []struct {
		target   string
		expected string
	}{
		{"//lib/hal:hal", "//lib/hal"},
		{"//examples/apps/adc_button/esp:app", "//examples/apps/adc_button/esp"},
		{"//lib/pkg/tls:tls", "//lib/pkg/tls"},
		{"//:gazelle", "//"},
		{"//foo/bar", "//foo/bar"},
	}

	for _, tt := range tests {
		t.Run(tt.target, func(t *testing.T) {
			result := extractPackage(tt.target)
			if result != tt.expected {
				t.Errorf("extractPackage(%q) = %q, want %q", tt.target, result, tt.expected)
			}
		})
	}
}

func TestFlagDefaults(t *testing.T) {
	if *base != "" {
		t.Errorf("base flag should default to empty string, got %q", *base)
	}
	if *check != "" {
		t.Errorf("check flag should default to empty string, got %q", *check)
	}
	if *output != "" {
		t.Errorf("output flag should default to empty string, got %q", *output)
	}
	if *oneline != false {
		t.Error("oneline flag should default to false")
	}
	if *verbose != false {
		t.Error("verbose flag should default to false")
	}
}
