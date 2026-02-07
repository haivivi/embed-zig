package main

import (
	"testing"
)

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
