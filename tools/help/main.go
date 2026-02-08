// Package main implements a project overview tool for Bazel workspaces.
//
// It runs `bazel query` to discover all targets in the workspace and
// displays them categorized by type: apps, tests, e2e, tools, libraries.
//
// Usage:
//
//	bazel run //tools/help              # Full overview
//	bazel run //tools/help -- apps      # Only apps
//	bazel run //tools/help -- tests     # Only tests
//	bazel run //tools/help -- e2e       # Only e2e tests
//	bazel run //tools/help -- tools     # Only tools
//	bazel run //tools/help -- libs      # Only libraries
//	bazel run //tools/help -- all       # All categories with full detail
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// category groups targets of the same kind.
type category struct {
	icon    string
	title   string
	hint    string // e.g. "bazel run" or "bazel test"
	targets []string
}

func main() {
	sub := ""
	if len(os.Args) > 1 {
		sub = os.Args[1]
	}

	valid := map[string]bool{
		"":      true,
		"apps":  true,
		"tests": true,
		"e2e":   true,
		"tools": true,
		"libs":  true,
		"all":   true,
	}
	if !valid[sub] {
		fmt.Fprintf(os.Stderr, "Unknown subcommand: %s\n", sub)
		fmt.Fprintf(os.Stderr, "Usage: bazel run //tools/help -- [apps|tests|e2e|tools|libs|all]\n")
		os.Exit(1)
	}

	// Detect workspace name from MODULE.bazel or WORKSPACE.
	wsName := detectWorkspaceName()

	// Collect all categories.
	cats := collectAll()

	// Print header.
	fmt.Println()
	fmt.Println(wsName)
	fmt.Println(strings.Repeat("=", len(wsName)))
	fmt.Println()

	switch sub {
	case "", "all":
		for _, c := range cats {
			printCategory(c, sub == "all")
		}
	case "apps":
		printCategory(cats[0], true)
	case "tests":
		printCategory(cats[1], true)
	case "e2e":
		printCategory(cats[2], true)
	case "tools":
		printCategory(cats[3], true)
	case "libs":
		printCategory(cats[4], true)
	}
}

// collectAll runs bazel queries and returns categorized results.
func collectAll() []*category {
	// Run all queries. Each query returns a list of labels.
	// We handle errors gracefully — empty result on failure.

	// Standard binaries (go_binary, cc_binary, etc.)
	stdBinaries := queryTargets(`kind(".*_binary", //...)`)
	// Platform-specific runnable targets (esp_flash, esp_zig_app, etc.)
	espFlash := queryTargets(`kind("esp_flash", //...)`)

	// Merge all runnable targets.
	allBinaries := mergeUnique(stdBinaries, espFlash)

	allTests := queryTargets(`kind(".*_test", //...)`)
	e2eTargets := queryTargets(`attr(tags, "e2e", //...)`)
	integrationTargets := queryTargets(`attr(tags, "integration", //...)`)
	manualTargets := queryTargets(`attr(tags, "manual", //...)`)
	allLibraries := queryTargets(`kind(".*_library", //...)`)

	// Build sets for exclusion.
	testSet := toSet(allTests)
	e2eSet := toSet(e2eTargets)
	integrationSet := toSet(integrationTargets)
	manualSet := toSet(manualTargets)

	// Tools: binaries under //tools/... or //devops/...
	toolSet := make(map[string]bool)
	for _, t := range allBinaries {
		if isToolTarget(t) {
			toolSet[t] = true
		}
	}

	// Apps: binaries that are not tests, not tools, not manual, not internal.
	var apps []string
	for _, t := range allBinaries {
		if !testSet[t] && !toolSet[t] && !manualSet[t] && !isInternalTarget(t) {
			apps = append(apps, t)
		}
	}

	// Tests: tests that are not e2e, not integration, not manual.
	var tests []string
	for _, t := range allTests {
		if !e2eSet[t] && !integrationSet[t] && !manualSet[t] {
			tests = append(tests, t)
		}
	}

	// E2E + Integration combined.
	var e2e []string
	seen := make(map[string]bool)
	for _, t := range e2eTargets {
		if !seen[t] {
			e2e = append(e2e, t)
			seen[t] = true
		}
	}
	for _, t := range integrationTargets {
		if !seen[t] {
			e2e = append(e2e, t)
			seen[t] = true
		}
	}

	// Tools list.
	var tools []string
	for t := range toolSet {
		tools = append(tools, t)
	}
	sort.Strings(tools)

	// Libraries: filter out build intermediates and internal targets.
	var libs []string
	for _, t := range allLibraries {
		if !isInternalLibrary(t) {
			libs = append(libs, t)
		}
	}

	sort.Strings(apps)
	sort.Strings(tests)
	sort.Strings(e2e)
	sort.Strings(libs)

	return []*category{
		{icon: "📦", title: "Apps", hint: "bazel run", targets: apps},
		{icon: "🧪", title: "Tests", hint: "bazel test", targets: tests},
		{icon: "🔌", title: "E2E Tests", hint: "bazel test --test_tag_filters=e2e", targets: e2e},
		{icon: "🔧", title: "Tools", hint: "bazel run", targets: tools},
		{icon: "📋", title: "Libraries", hint: "", targets: libs},
	}
}

// printCategory formats and prints a single category.
func printCategory(c *category, detailed bool) {
	if len(c.targets) == 0 {
		return
	}

	header := fmt.Sprintf("%s %s", c.icon, c.title)
	if c.hint != "" {
		header += fmt.Sprintf(" (%s)", c.hint)
	}

	if c.title == "Libraries" && !detailed {
		fmt.Printf("%s (%d packages)\n", header, len(c.targets))
		// Show compact list, wrapping at 80 chars.
		line := "  "
		for _, t := range c.targets {
			label := shortenLabel(t)
			entry := label + "    "
			if len(line)+len(entry) > 80 && line != "  " {
				fmt.Println(strings.TrimRight(line, " "))
				line = "  "
			}
			line += entry
		}
		if strings.TrimSpace(line) != "" {
			fmt.Println(strings.TrimRight(line, " "))
		}
		fmt.Println()
		return
	}

	fmt.Println(header)
	maxLen := 0
	for _, t := range c.targets {
		if len(t) > maxLen {
			maxLen = len(t)
		}
	}
	for _, t := range c.targets {
		fmt.Printf("  %-*s\n", maxLen, t)
	}
	fmt.Println()
}

// queryOutputBase returns a separate output_base path so nested bazel query
// doesn't conflict with the parent `bazel run` server lock.
func queryOutputBase() string {
	wsDir := os.Getenv("BUILD_WORKSPACE_DIRECTORY")
	if wsDir == "" {
		wsDir, _ = os.Getwd()
	}
	// Deterministic but unique per workspace.
	h := sha256.Sum256([]byte(wsDir))
	name := "help-query-" + hex.EncodeToString(h[:8])
	return filepath.Join(os.TempDir(), name)
}

// queryTargets runs a bazel query and returns the list of target labels.
// Uses a separate --output_base to avoid lock conflict with `bazel run`.
func queryTargets(query string) []string {
	wsDir := os.Getenv("BUILD_WORKSPACE_DIRECTORY")

	args := []string{
		"--output_base=" + queryOutputBase(),
		"query",
		query,
		"--output=label",
		"--keep_going",
		"--noshow_progress",
	}
	cmd := exec.Command("bazel", args...)
	if wsDir != "" {
		cmd.Dir = wsDir
	}
	cmd.Stderr = nil // suppress stderr
	out, err := cmd.Output()
	if err != nil {
		// Query might partially fail (e.g., no matches). Return what we got.
		if len(out) == 0 {
			return nil
		}
	}
	return parseLabels(string(out))
}

// parseLabels splits bazel query output into label strings.
func parseLabels(output string) []string {
	var labels []string
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if line != "" && strings.HasPrefix(line, "//") {
			labels = append(labels, line)
		}
	}
	return labels
}

// isToolTarget returns true if the target is under //tools/ or //devops/.
func isToolTarget(label string) bool {
	return strings.HasPrefix(label, "//tools/") ||
		strings.HasPrefix(label, "//devops/")
}

// isInternalTarget returns true for targets that are build infrastructure,
// not user-facing apps. E.g., build rule tests, test helpers.
func isInternalTarget(label string) bool {
	// Build rule tests (e.g., //bazel/zig/tests/app:app).
	if strings.HasPrefix(label, "//bazel/") {
		return true
	}
	// Test infrastructure (e.g., //lib/pkg/tls/test:tls_test_server).
	if strings.Contains(label, "/test:") || strings.Contains(label, "/tests:") {
		return true
	}
	return false
}

// isInternalLibrary returns true for build intermediates and internal libs.
func isInternalLibrary(label string) bool {
	name := targetName(label)
	// Go intermediate libraries (e.g., :help_lib, :bazel-affected_lib).
	if strings.HasSuffix(name, "_lib") {
		return true
	}
	// Zig static archives (e.g., :hal_a, :math_utils_a).
	if strings.HasSuffix(name, "_a") {
		return true
	}
	// Build rule test packages (e.g., //bazel/zig/tests/base).
	if strings.HasPrefix(label, "//bazel/") {
		return true
	}
	return false
}

// targetName extracts the target name from a label.
// e.g., "//lib/pkg/tls:tls" -> "tls", "//lib/pkg/tls" -> "tls"
func targetName(label string) string {
	if i := strings.LastIndex(label, ":"); i >= 0 {
		return label[i+1:]
	}
	return filepath.Base(label)
}

// mergeUnique merges multiple slices, deduplicating.
func mergeUnique(slices ...[]string) []string {
	seen := make(map[string]bool)
	var result []string
	for _, s := range slices {
		for _, item := range s {
			if !seen[item] {
				seen[item] = true
				result = append(result, item)
			}
		}
	}
	return result
}

// toSet converts a slice to a set.
func toSet(items []string) map[string]bool {
	m := make(map[string]bool, len(items))
	for _, item := range items {
		m[item] = true
	}
	return m
}

// shortenLabel trims the label for compact display.
// e.g. "//lib/pkg/tls:tls" -> "//lib/pkg/tls"
func shortenLabel(label string) string {
	if i := strings.LastIndex(label, ":"); i >= 0 {
		pkg := label[:i]
		name := label[i+1:]
		// If name equals the last component of pkg path, omit it.
		base := filepath.Base(pkg)
		if name == base {
			return pkg
		}
	}
	return label
}

// detectWorkspaceName reads MODULE.bazel or falls back to directory name.
func detectWorkspaceName() string {
	// Try BUILD_WORKSPACE_DIRECTORY (set by `bazel run`).
	wsDir := os.Getenv("BUILD_WORKSPACE_DIRECTORY")

	// Try MODULE.bazel.
	moduleFile := "MODULE.bazel"
	if wsDir != "" {
		moduleFile = filepath.Join(wsDir, "MODULE.bazel")
	}
	data, err := os.ReadFile(moduleFile)
	if err == nil {
		name := parseModuleName(string(data))
		if name != "" {
			return name
		}
	}

	// Fallback: directory name.
	if wsDir != "" {
		return filepath.Base(wsDir)
	}
	dir, err := os.Getwd()
	if err == nil {
		return filepath.Base(dir)
	}
	return "project"
}

// parseModuleName extracts the module name from MODULE.bazel content.
// Looks for: module(name = "xxx", ...)
func parseModuleName(content string) string {
	// Simple parser: find `name = "..."` inside module().
	idx := strings.Index(content, "module(")
	if idx < 0 {
		return ""
	}
	rest := content[idx:]
	// Find closing paren.
	end := strings.Index(rest, ")")
	if end < 0 {
		return ""
	}
	block := rest[:end]

	// Find name = "..."
	nameIdx := strings.Index(block, "name")
	if nameIdx < 0 {
		return ""
	}
	after := block[nameIdx:]
	q1 := strings.Index(after, "\"")
	if q1 < 0 {
		return ""
	}
	after = after[q1+1:]
	q2 := strings.Index(after, "\"")
	if q2 < 0 {
		return ""
	}
	return after[:q2]
}
