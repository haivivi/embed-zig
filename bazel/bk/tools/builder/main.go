package main

import (
	"bufio"
	"embed-zig/bazel/bk/tools/common"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const prefix = "[bk_build]"

type Config struct {
	ProjectName string
	ApZig       string
	CpZig       string
	BkZig       string
	CHelpers    string
	BinOut      string
	ApBinOut    string
	PartOut     string
	Modules     string
	AppZig      string
	EnvFile     string
	Requires    string
	ForceLink   string
	BaseProject string
	KconfigAP   string
	KconfigCP   string
	PartCSV     string
	APStack     int
	RunInPSRAM  int
	PrelinkLibs string
	StaticLibs  string
	ExecRoot    string
	ZigBin      string
	ArminoPath  string
}

func main() {
	cfg := loadConfig()

	arminoPath, err := common.SetupArminoEnv(prefix)
	if err != nil {
		fatal(err)
	}
	cfg.ArminoPath = arminoPath

	if err := build(&cfg); err != nil {
		fatal(err)
	}

	fmt.Printf("%s Done!\n", prefix)
}

func loadConfig() Config {
	apStack, _ := strconv.Atoi(getEnvDefault("BK_AP_STACK_SIZE", "16384"))
	runPSRAM, _ := strconv.Atoi(getEnvDefault("BK_RUN_IN_PSRAM", "0"))

	return Config{
		ProjectName: os.Getenv("BK_PROJECT_NAME"),
		ApZig:       os.Getenv("BK_AP_ZIG"),
		CpZig:       os.Getenv("BK_CP_ZIG"),
		BkZig:       os.Getenv("BK_BK_ZIG"),
		CHelpers:    os.Getenv("BK_C_HELPERS"),
		BinOut:      os.Getenv("BK_BIN_OUT"),
		ApBinOut:    os.Getenv("BK_AP_BIN_OUT"),
		PartOut:     os.Getenv("BK_PARTITIONS_OUT"),
		Modules:     os.Getenv("BK_MODULES"),
		AppZig:      os.Getenv("BK_APP_ZIG"),
		EnvFile:     os.Getenv("BK_ENV_FILE"),
		Requires:    os.Getenv("BK_AP_REQUIRES"),
		ForceLink:   os.Getenv("BK_FORCE_LINK"),
		BaseProject: os.Getenv("BK_BASE_PROJECT"),
		KconfigAP:   os.Getenv("BK_KCONFIG_AP"),
		KconfigCP:   os.Getenv("BK_KCONFIG_CP"),
		PartCSV:     os.Getenv("BK_PARTITION_CSV"),
		APStack:     apStack,
		RunInPSRAM:  runPSRAM,
		PrelinkLibs: os.Getenv("BK_PRELINK_LIBS"),
		StaticLibs:  os.Getenv("BK_STATIC_LIBS"),
		ExecRoot:    os.Getenv("E"),
		ZigBin:      os.Getenv("ZIG_BIN"),
	}
}

func build(cfg *Config) error {
	workDir, err := os.MkdirTemp("", "bk_build_*")
	if err != nil {
		return fmt.Errorf("create temp dir: %w", err)
	}
	defer os.RemoveAll(workDir)

	fmt.Printf("%s Project: %s\n", prefix, cfg.ProjectName)
	fmt.Printf("%s AP: %s\n", prefix, cfg.ApZig)
	fmt.Printf("%s CP: %s\n", prefix, cfg.CpZig)

	// libaec.a hide/restore for v3 prelink
	var libaecV1, libaecV1Bak string
	if strings.Contains(cfg.PrelinkLibs, "libaec_v3") {
		libaecV1 = filepath.Join(cfg.ArminoPath, "ap/components/bk_libs/bk7258_ap/libs/libaec.a")
		if common.FileExists(libaecV1) {
			libaecV1Bak = libaecV1 + ".bak_zig"
			if err := os.Rename(libaecV1, libaecV1Bak); err != nil {
				return fmt.Errorf("hide libaec.a: %w", err)
			}
			fmt.Printf("%s Temporarily hid libaec.a (v1) to avoid conflict with v3\n", prefix)
			defer func() {
				if common.FileExists(libaecV1Bak) {
					os.Rename(libaecV1Bak, libaecV1)
					fmt.Printf("%s Restored libaec.a (v1) in cleanup\n", prefix)
				}
			}()
		}
	}

	// Step 1: Compile AP and CP Zig libraries
	apDir := filepath.Join(workDir, "zig_ap")
	cpDir := filepath.Join(workDir, "zig_cp")

	if err := compileZigLib(cfg, "bk_zig_ap", cfg.ApZig, cfg.BkZig, apDir, workDir); err != nil {
		return fmt.Errorf("compile AP: %w", err)
	}
	apLib := findLib(filepath.Join(apDir, "zig-out"))

	if err := compileZigLib(cfg, "bk_zig_cp", cfg.CpZig, cfg.BkZig, cpDir, workDir); err != nil {
		return fmt.Errorf("compile CP: %w", err)
	}
	cpLib := findLib(filepath.Join(cpDir, "zig-out"))

	fmt.Printf("%s AP lib: %s\n", prefix, apLib)
	fmt.Printf("%s CP lib: %s\n", prefix, cpLib)

	if apLib == "" || cpLib == "" {
		return fmt.Errorf("Zig compilation failed — no .a produced")
	}

	// Step 2: Generate Armino project
	if err := generateArminoProject(cfg, workDir, apLib, cpLib); err != nil {
		return err
	}

	// Step 3: Build with Armino
	return runArminoBuild(cfg, workDir)
}

// compileZigLib compiles a Zig source into a static ARM library.
func compileZigLib(cfg *Config, name, appZig, bkZig, outDir, workDir string) error {
	os.MkdirAll(outDir, 0755)
	E := cfg.ExecRoot

	rootZig := filepath.Join(E, appZig)

	// AP: generate main.zig + env.zig
	if name == "bk_zig_ap" {
		if err := generateEnvZig(cfg, outDir); err != nil {
			return err
		}
		if err := generateMainZig(outDir); err != nil {
			return err
		}
		rootZig = filepath.Join(outDir, "main.zig")
		fmt.Printf("%s Generated main.zig + env.zig\n", prefix)
	}

	// Generate build.zig
	if err := generateBuildZig(cfg, name, rootZig, outDir); err != nil {
		return err
	}

	// Generate build.zig.zon
	zonContent := fmt.Sprintf(".{\n    .name = .%s,\n    .version = \"0.1.0\",\n    .paths = .{ \"build.zig\", \"build.zig.zon\" },\n}\n", name)
	if err := os.WriteFile(filepath.Join(outDir, "build.zig.zon"), []byte(zonContent), 0644); err != nil {
		return err
	}

	// Get fingerprint
	zigBin := cfg.ZigBin
	cacheDir := filepath.Join(workDir, ".zig-cache-"+name)
	globalDir := filepath.Join(workDir, ".zig-global-"+name)

	cmd := exec.Command(zigBin, "build", "--fetch", "--cache-dir", cacheDir, "--global-cache-dir", globalDir)
	cmd.Dir = outDir
	fpOutput, _ := cmd.CombinedOutput()
	fpStr := string(fpOutput)
	if idx := strings.Index(fpStr, "suggested value: 0x"); idx >= 0 {
		rest := fpStr[idx+len("suggested value: "):]
		end := strings.IndexAny(rest, " \n\r,")
		if end < 0 {
			end = len(rest)
		}
		fp := rest[:end]
		// Insert fingerprint into build.zig.zon
		zonData, _ := os.ReadFile(filepath.Join(outDir, "build.zig.zon"))
		updated := strings.Replace(string(zonData),
			".version = \"0.1.0\",",
			".version = \"0.1.0\",\n    .fingerprint = "+fp+",", 1)
		os.WriteFile(filepath.Join(outDir, "build.zig.zon"), []byte(updated), 0644)
	}

	// Build
	fmt.Printf("%s Compiling %s Zig → ARM static lib...\n", prefix, name)
	if err := common.RunCommandInDir(outDir, zigBin, "build", "--cache-dir", cacheDir, "--global-cache-dir", globalDir); err != nil {
		return fmt.Errorf("zig build %s: %w", name, err)
	}

	lib := findLib(filepath.Join(outDir, "zig-out"))
	if lib == "" {
		return fmt.Errorf("no .a produced for %s", name)
	}

	fmt.Printf("%s %s lib: %s (%d bytes)\n", prefix, name, lib, common.FileSize(lib))
	return nil
}

// generateEnvZig creates env.zig from the environment file.
func generateEnvZig(cfg *Config, outDir string) error {
	var b strings.Builder
	b.WriteString("pub const Env = struct {\n")

	envFile := cfg.EnvFile
	if envFile != "" {
		fullPath := filepath.Join(cfg.ExecRoot, envFile)
		if common.FileExists(fullPath) {
			f, err := os.Open(fullPath)
			if err != nil {
				return err
			}
			defer f.Close()

			scanner := bufio.NewScanner(f)
			for scanner.Scan() {
				line := scanner.Text()
				line = strings.TrimSpace(line)
				if line == "" || strings.HasPrefix(line, "#") {
					continue
				}
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				key := strings.TrimSpace(strings.Trim(parts[0], "\""))
				value := strings.TrimSpace(strings.Trim(parts[1], "\""))
				if key == "" {
					continue
				}
				field := strings.ToLower(key)
				// Escape backslashes and double quotes for Zig string literals
				value = strings.ReplaceAll(value, "\\", "\\\\")
				value = strings.ReplaceAll(value, "\"", "\\\"")
				b.WriteString(fmt.Sprintf("    %s: []const u8 = \"%s\",\n", field, value))
			}
		}
	}

	b.WriteString("};\n")
	b.WriteString("pub const env = Env{};\n")

	envZig := filepath.Join(outDir, "env.zig")
	if err := os.WriteFile(envZig, []byte(b.String()), 0644); err != nil {
		return err
	}

	// Log env.zig
	fmt.Printf("%s env.zig:\n", prefix)
	for _, line := range strings.Split(b.String(), "\n") {
		if line != "" {
			fmt.Printf("%s   %s\n", prefix, line)
		}
	}
	return nil
}

// generateMainZig creates the main.zig bridge file.
func generateMainZig(outDir string) error {
	content := `const app = @import("app");
const env_module = @import("env");
const impl = @import("bk");
pub const std_options = @import("std").Options{ .logFn = impl.impl.stdLogFn, .page_size_min = 4096, .page_size_max = 4096 };
export fn zig_main() callconv(.c) void {
    app.run(env_module.env);
}
`
	return os.WriteFile(filepath.Join(outDir, "main.zig"), []byte(content), 0644)
}

// generateBuildZig creates the build.zig that compiles all modules into a static library.
func generateBuildZig(cfg *Config, name, rootZig, outDir string) error {
	E := cfg.ExecRoot
	var b strings.Builder

	b.WriteString("const std = @import(\"std\");\n")
	b.WriteString("pub fn build(b: *std.Build) void {\n")
	b.WriteString("    const target = b.resolveTargetQuery(.{\n")
	b.WriteString("        .cpu_arch = .thumb,\n")
	b.WriteString("        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_m33 },\n")
	b.WriteString("        .os_tag = .freestanding,\n")
	b.WriteString("        .abi = .eabihf,\n")
	b.WriteString("    });\n")
	b.WriteString("    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;\n\n")

	// Parse modules: "name:root_path:inc_dirs"
	type modInfo struct {
		name    string
		path    string
		incDirs []string
	}
	var mods []modInfo
	if cfg.Modules != "" {
		for _, entry := range strings.Fields(cfg.Modules) {
			parts := strings.SplitN(entry, ":", 3)
			m := modInfo{name: parts[0]}
			if len(parts) > 1 {
				m.path = parts[1]
			}
			if len(parts) > 2 && parts[2] != "" {
				m.incDirs = strings.Split(parts[2], ",")
			}
			mods = append(mods, m)
		}
	}

	// Declare each module
	for i, m := range mods {
		b.WriteString(fmt.Sprintf("    const mod_%d = b.createModule(.{\n", i))
		b.WriteString(fmt.Sprintf("        .root_source_file = .{ .cwd_relative = \"%s/%s\" },\n", E, m.path))
		b.WriteString("        .target = target,\n")
		b.WriteString("        .optimize = optimize,\n")
		b.WriteString("    });\n")
		for _, inc := range m.incDirs {
			b.WriteString(fmt.Sprintf("    mod_%d.addIncludePath(.{ .cwd_relative = \"%s/%s\" });\n", i, E, inc))
		}
	}

	// AP: build_options, app, env modules
	if name == "bk_zig_ap" {
		if err := generateBuildOptions(outDir); err != nil {
			return err
		}
		b.WriteString(fmt.Sprintf("    const build_options_mod = b.createModule(.{\n"))
		b.WriteString(fmt.Sprintf("        .root_source_file = .{ .cwd_relative = \"%s/build_options.zig\" },\n", outDir))
		b.WriteString("        .target = target,\n")
		b.WriteString("        .optimize = optimize,\n")
		b.WriteString("    });\n")
		b.WriteString(fmt.Sprintf("    const app_mod = b.createModule(.{\n"))
		b.WriteString(fmt.Sprintf("        .root_source_file = .{ .cwd_relative = \"%s/%s\" },\n", E, cfg.AppZig))
		b.WriteString("        .target = target,\n")
		b.WriteString("        .optimize = optimize,\n")
		b.WriteString("    });\n")
		b.WriteString("    app_mod.addImport(\"build_options\", build_options_mod);\n")
		b.WriteString(fmt.Sprintf("    const env_mod = b.createModule(.{\n"))
		b.WriteString(fmt.Sprintf("        .root_source_file = .{ .cwd_relative = \"%s/env.zig\" },\n", outDir))
		b.WriteString("        .target = target,\n")
		b.WriteString("        .optimize = optimize,\n")
		b.WriteString("    });\n")
	}
	b.WriteString("\n")

	// Wire inter-module deps (each module imports all others)
	for i, m := range mods {
		for j, inner := range mods {
			if m.name != inner.name {
				b.WriteString(fmt.Sprintf("    mod_%d.addImport(\"%s\", mod_%d);\n", i, inner.name, j))
			}
		}
	}

	// App module imports all deps
	if name == "bk_zig_ap" {
		for i, m := range mods {
			b.WriteString(fmt.Sprintf("    app_mod.addImport(\"%s\", mod_%d);\n", m.name, i))
		}
	}
	b.WriteString("\n")

	// Root module
	b.WriteString("    const root_mod = b.createModule(.{\n")
	b.WriteString(fmt.Sprintf("        .root_source_file = .{ .cwd_relative = \"%s\" },\n", rootZig))
	b.WriteString("        .target = target,\n")
	b.WriteString("        .optimize = optimize,\n")
	b.WriteString("    });\n")

	// Root imports
	for i, m := range mods {
		b.WriteString(fmt.Sprintf("    root_mod.addImport(\"%s\", mod_%d);\n", m.name, i))
	}
	if name == "bk_zig_ap" {
		b.WriteString("    root_mod.addImport(\"app\", app_mod);\n")
		b.WriteString("    root_mod.addImport(\"env\", env_mod);\n")
	}
	b.WriteString("\n")

	b.WriteString(fmt.Sprintf("    const lib = b.addLibrary(.{\n"))
	b.WriteString(fmt.Sprintf("        .name = \"%s\",\n", name))
	b.WriteString("        .linkage = .static,\n")
	b.WriteString("        .root_module = root_mod,\n")
	b.WriteString("    });\n")
	b.WriteString("    b.installArtifact(lib);\n")
	b.WriteString("}\n")

	return os.WriteFile(filepath.Join(outDir, "build.zig"), []byte(b.String()), 0644)
}

// generateBuildOptions creates build_options.zig.
func generateBuildOptions(outDir string) error {
	content := `pub const Board = enum {
    bk7258,
    // ESP boards (needed for platform.zig switch exhaustiveness)
    esp32s3_devkit,
    korvo2_v3,
    lichuang_szp,
    lichuang_gocool,
    sim_raylib,
};
pub const board: Board = .bk7258;
`
	return os.WriteFile(filepath.Join(outDir, "build_options.zig"), []byte(content), 0644)
}

// generateArminoProject creates the Armino project skeleton.
func generateArminoProject(cfg *Config, workDir, apLib, cpLib string) error {
	projectDir := filepath.Join(workDir, "projects", cfg.ProjectName)
	os.MkdirAll(filepath.Join(projectDir, "ap"), 0755)
	os.MkdirAll(filepath.Join(projectDir, "cp"), 0755)
	os.MkdirAll(filepath.Join(projectDir, "partitions", "bk7258"), 0755)

	base := filepath.Join(cfg.ArminoPath, "projects", cfg.BaseProject)
	if !common.FileExists(base) {
		return fmt.Errorf("base project '%s' not found at %s", cfg.BaseProject, base)
	}
	fmt.Printf("%s Base project: %s\n", prefix, cfg.BaseProject)

	// Partition table
	if cfg.PartCSV != "" {
		fullPartCSV := filepath.Join(cfg.ExecRoot, cfg.PartCSV)
		if common.FileExists(fullPartCSV) {
			if err := common.CopyFile(fullPartCSV, filepath.Join(projectDir, "partitions/bk7258/auto_partitions.csv")); err != nil {
				return fmt.Errorf("copy partition table: %w", err)
			}
			fmt.Printf("%s Custom partition table from Bazel\n", prefix)
		} else {
			if err := common.CopyFile(filepath.Join(base, "partitions/bk7258/auto_partitions.csv"), filepath.Join(projectDir, "partitions/bk7258/auto_partitions.csv")); err != nil {
				return fmt.Errorf("copy partition table: %w", err)
			}
		}
	} else {
		if err := common.CopyFile(filepath.Join(base, "partitions/bk7258/auto_partitions.csv"), filepath.Join(projectDir, "partitions/bk7258/auto_partitions.csv")); err != nil {
			return fmt.Errorf("copy partition table: %w", err)
		}
	}
	if err := common.CopyFile(filepath.Join(base, "partitions/bk7258/ram_regions.csv"), filepath.Join(projectDir, "partitions/bk7258/ram_regions.csv")); err != nil {
		return fmt.Errorf("copy ram_regions: %w", err)
	}

	// Configs
	os.MkdirAll(filepath.Join(projectDir, "ap/config/bk7258_ap"), 0755)
	os.MkdirAll(filepath.Join(projectDir, "cp/config/bk7258"), 0755)
	if err := common.CopyFile(filepath.Join(base, "ap/config/bk7258_ap/config"), filepath.Join(projectDir, "ap/config/bk7258_ap/config")); err != nil {
		return fmt.Errorf("copy AP config: %w", err)
	}
	if err := common.CopyFile(filepath.Join(base, "cp/config/bk7258/config"), filepath.Join(projectDir, "cp/config/bk7258/config")); err != nil {
		return fmt.Errorf("copy CP config: %w", err)
	}
	common.CopyFileIfExists(filepath.Join(base, "ap/config/bk7258_ap/usr_gpio_cfg.h"), filepath.Join(projectDir, "ap/config/bk7258_ap/usr_gpio_cfg.h"))
	common.CopyFileIfExists(filepath.Join(base, "cp/config/bk7258/usr_gpio_cfg.h"), filepath.Join(projectDir, "cp/config/bk7258/usr_gpio_cfg.h"))

	// Append Kconfig overrides
	if cfg.KconfigAP != "" {
		fullPath := filepath.Join(cfg.ExecRoot, cfg.KconfigAP)
		if common.FileExists(fullPath) {
			appendFile(filepath.Join(projectDir, "ap/config/bk7258_ap/config"), fullPath)
			fmt.Printf("%s AP Kconfig appended from %s\n", prefix, cfg.KconfigAP)
		}
	}

	// Enable mbedTLS features if FULL_MBEDTLS is set
	apConfig := filepath.Join(projectDir, "ap/config/bk7258_ap/config")
	if fileContains(apConfig, "CONFIG_FULL_MBEDTLS=y") {
		mbedCfg := filepath.Join(cfg.ArminoPath, "ap/components/psa_mbedtls/mbedtls_port/configs/mbedtls_psa_crypto_config.h")
		if common.FileExists(mbedCfg) {
			enableMbedTLSFeature(mbedCfg, "// #define MBEDTLS_ECP_DP_CURVE25519_ENABLED", "#define MBEDTLS_ECP_DP_CURVE25519_ENABLED", "MBEDTLS_ECP_DP_CURVE25519_ENABLED")
			enableMbedTLSFeature(mbedCfg, "// #define MBEDTLS_CHACHA20_C", "#define MBEDTLS_CHACHA20_C", "MBEDTLS_CHACHA20_C")
			enableMbedTLSFeature(mbedCfg, "// #define MBEDTLS_CHACHAPOLY_C", "#define MBEDTLS_CHACHAPOLY_C", "MBEDTLS_CHACHAPOLY_C")
			enableMbedTLSFeature(mbedCfg, "// #define MBEDTLS_POLY1305_C", "#define MBEDTLS_POLY1305_C", "MBEDTLS_POLY1305_C")
		}
	}

	if cfg.KconfigCP != "" {
		fullPath := filepath.Join(cfg.ExecRoot, cfg.KconfigCP)
		if common.FileExists(fullPath) {
			appendFile(filepath.Join(projectDir, "cp/config/bk7258/config"), fullPath)
			fmt.Printf("%s CP Kconfig appended from %s\n", prefix, cfg.KconfigCP)
		}
	}

	// Makefile
	os.WriteFile(filepath.Join(projectDir, "Makefile"), []byte(`SDK_DIR ?= $(abspath ../..)
PROJECT_MAKE_FILE := $(SDK_DIR)/tools/build_tools/build_files/project_main.mk
ifeq ($(wildcard $(PROJECT_MAKE_FILE)),)
    $(error "$(PROJECT_MAKE_FILE) not exist")
endif
include $(PROJECT_MAKE_FILE)
`), 0644)

	// CMakeLists.txt
	os.WriteFile(filepath.Join(projectDir, "CMakeLists.txt"), []byte(`cmake_minimum_required(VERSION 3.5)
include($ENV{ARMINO_TOOLS_PATH}/build_tools/cmake/project.cmake)
project(app)
`), 0644)

	// CP component
	if err := common.CopyFile(cpLib, filepath.Join(projectDir, "cp/libbk_zig_cp.a")); err != nil {
		return fmt.Errorf("copy CP lib: %w", err)
	}
	if err := common.CopyFile(filepath.Join(cfg.ExecRoot, "lib/platform/bk/armino/src/bk_zig_helper.c"), filepath.Join(projectDir, "cp/bk_zig_helper.c")); err != nil {
		return fmt.Errorf("copy CP helper: %w", err)
	}
	os.WriteFile(filepath.Join(projectDir, "cp/cp_main.c"), []byte(cpMainC()), 0644)
	os.WriteFile(filepath.Join(projectDir, "cp/CMakeLists.txt"), []byte(cpCMake()), 0644)

	// AP component
	if err := generateAPComponent(cfg, projectDir, apLib); err != nil {
		return err
	}

	os.WriteFile(filepath.Join(projectDir, "pj_config.mk"), []byte(""), 0644)
	return nil
}

func generateAPComponent(cfg *Config, projectDir, apLib string) error {
	// Copy C helpers
	var cHelperSrcs []string
	if cfg.CHelpers != "" {
		for _, helper := range strings.Fields(cfg.CHelpers) {
			bn := filepath.Base(helper)
			if err := common.CopyFile(filepath.Join(cfg.ExecRoot, helper), filepath.Join(projectDir, "ap", bn)); err != nil {
				return fmt.Errorf("copy C helper %s: %w", bn, err)
			}
			cHelperSrcs = append(cHelperSrcs, bn)
		}
	}

	// Copy AP lib
	if err := common.CopyFile(apLib, filepath.Join(projectDir, "ap/libbk_zig_ap.a")); err != nil {
		return fmt.Errorf("copy AP lib: %w", err)
	}

	// Copy static libs
	var staticLibCMake string
	if cfg.StaticLibs != "" {
		for _, slib := range strings.Fields(cfg.StaticLibs) {
			bn := filepath.Base(slib)
			srcPath := filepath.Join(cfg.ExecRoot, slib)
			if err := common.CopyFile(srcPath, filepath.Join(projectDir, "ap", bn)); err != nil {
				return fmt.Errorf("copy static lib %s: %w", bn, err)
			}
			staticLibCMake += " ${CMAKE_CURRENT_SOURCE_DIR}/" + bn
			fmt.Printf("%s Static lib: %s (%d bytes)\n", prefix, bn, common.FileSize(srcPath))
		}
	}

	// Determine stack config
	apStack := cfg.APStack
	if apStack == 0 {
		apStack = 16384
	}
	runPSRAM := cfg.RunInPSRAM

	var actualStack int
	var stackMode string
	if runPSRAM > 0 {
		actualStack = runPSRAM
		stackMode = "PSRAM"
	} else {
		actualStack = apStack
		stackMode = "SRAM"
	}

	// Generate ap_main.c
	os.WriteFile(filepath.Join(projectDir, "ap/ap_main.c"), []byte(apMainC(actualStack, stackMode, runPSRAM, apStack)), 0644)
	fmt.Printf("%s AP task stack: %d bytes (%s)\n", prefix, actualStack, stackMode)

	// Prelink libs
	var prelinkCMake string
	if cfg.PrelinkLibs != "" {
		var paths []string
		for _, lib := range strings.Fields(cfg.PrelinkLibs) {
			paths = append(paths, "$ENV{ARMINO_PATH}/"+lib)
		}
		prelinkCMake = fmt.Sprintf("target_link_libraries(${COMPONENT_LIB} INTERFACE %s)", strings.Join(paths, " "))
		fmt.Printf("%s Prelink libs: %s\n", prefix, cfg.PrelinkLibs)
	}

	// AP CMakeLists
	allSrcs := "ap_main.c " + strings.Join(cHelperSrcs, " ")
	cmakeContent := fmt.Sprintf(`set(incs .)
set(srcs %s)
set(priv_req driver lwip_intf_v2_1 %s)
armino_component_register(SRCS "${srcs}" INCLUDE_DIRS "${incs}" PRIV_REQUIRES "${priv_req}")
%s
target_link_libraries(${COMPONENT_LIB} INTERFACE -Wl,--whole-archive ${CMAKE_CURRENT_SOURCE_DIR}/libbk_zig_ap.a -Wl,--no-whole-archive %s)
target_link_options(${COMPONENT_LIB} INTERFACE %s)
`, allSrcs, cfg.Requires, prelinkCMake, staticLibCMake, cfg.ForceLink)

	os.WriteFile(filepath.Join(projectDir, "ap/CMakeLists.txt"), []byte(cmakeContent), 0644)
	return nil
}

func runArminoBuild(cfg *Config, workDir string) error {
	projectDir := filepath.Join(workDir, "projects", cfg.ProjectName)

	// Debug: check AP config
	apConfig := filepath.Join(projectDir, "ap/config/bk7258_ap/config")
	fmt.Printf("%s AP config FULL_MBEDTLS check:\n", prefix)
	if fileContains(apConfig, "FULL_MBEDTLS") {
		fmt.Printf("%s   FOUND\n", prefix)
	} else {
		fmt.Printf("%s   NOT FOUND\n", prefix)
	}

	// Build
	fmt.Printf("%s Running Armino make...\n", prefix)
	buildDir := filepath.Join(workDir, "build")
	rmDir := filepath.Join(cfg.ArminoPath, "build", "bk7258", cfg.ProjectName)
	os.RemoveAll(rmDir)

	cmd := exec.Command("make", "bk7258",
		"PROJECT="+cfg.ProjectName,
		"PROJECT_DIR="+projectDir,
		"BUILD_DIR="+buildDir)
	cmd.Dir = cfg.ArminoPath
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("armino make failed: %w", err)
	}

	// Find outputs
	packageDir := filepath.Join(buildDir, "bk7258", cfg.ProjectName, "package")
	allApp := filepath.Join(packageDir, "all-app.bin")
	if !common.FileExists(allApp) {
		return fmt.Errorf("all-app.bin not found")
	}

	// Log package
	fmt.Printf("%s Package contents:\n", prefix)
	entries, _ := os.ReadDir(packageDir)
	for _, e := range entries {
		fmt.Printf("%s   %s (%d bytes)\n", prefix, e.Name(), common.FileSize(filepath.Join(packageDir, e.Name())))
	}

	// Find AP and CP binaries
	buildBase := filepath.Join(buildDir, "bk7258", cfg.ProjectName)
	apBin := common.FindFileWithPath(buildBase, "app.bin", "bk7258_ap")
	cpBin := common.FindFileWithPathExclude(buildBase, "app.bin", "bk7258", "bk7258_ap")

	if apBin != "" {
		fmt.Printf("%s AP binary: %s (%d bytes)\n", prefix, apBin, common.FileSize(apBin))
	}
	if cpBin != "" {
		fmt.Printf("%s CP binary: %s (%d bytes)\n", prefix, cpBin, common.FileSize(cpBin))
	}

	// Copy outputs
	if err := common.CopyFile(allApp, cfg.BinOut); err != nil {
		return fmt.Errorf("copy all-app.bin: %w", err)
	}

	if apBin != "" && common.FileExists(apBin) {
		if err := common.CopyFile(apBin, cfg.ApBinOut); err != nil {
			return fmt.Errorf("copy AP bin: %w", err)
		}
		fmt.Printf("%s AP-only: %s (%d bytes)\n", prefix, cfg.ApBinOut, common.FileSize(cfg.ApBinOut))
	} else {
		if err := common.CopyFile(allApp, cfg.ApBinOut); err != nil {
			return fmt.Errorf("copy AP fallback bin: %w", err)
		}
	}

	// Copy partitions
	partCSV := filepath.Join(filepath.Join(buildDir, "bk7258", cfg.ProjectName, "partitions"), "partitions.csv")
	if common.FileExists(partCSV) {
		if err := common.CopyFile(partCSV, cfg.PartOut); err != nil {
			return fmt.Errorf("copy partitions: %w", err)
		}
	} else {
		os.WriteFile(cfg.PartOut, []byte("Name,Offset\n"), 0644)
	}

	fmt.Printf("%s Output: %s (%d bytes)\n", prefix, cfg.BinOut, common.FileSize(cfg.BinOut))
	return nil
}

// --- Template functions ---

func cpMainC() string {
	return `#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>
#include <modules/pm.h>
#include <driver/pwr_clk.h>
extern void rtos_set_user_app_entry(beken_thread_function_t entry);
extern void zig_cp_main(void);
static void zig_cp_task(void *arg) { zig_cp_main(); }
void user_app_main(void) {
    bk_pm_module_vote_boot_cp1_ctrl(PM_BOOT_CP1_MODULE_NAME_APP, PM_POWER_MODULE_STATE_ON);
    beken_thread_t t;
    rtos_create_thread(&t, 4, "zig_cp", (beken_thread_function_t)zig_cp_task, 8192, 0);
}
int main(void) {
    rtos_set_user_app_entry((beken_thread_function_t)user_app_main);
    bk_init();
    return 0;
}
`
}

func cpCMake() string {
	return `set(incs .)
set(srcs cp_main.c bk_zig_helper.c)
armino_component_register(SRCS "${srcs}" INCLUDE_DIRS "${incs}")
target_link_libraries(${COMPONENT_LIB} INTERFACE ${CMAKE_CURRENT_SOURCE_DIR}/libbk_zig_cp.a)
`
}

func apMainC(actualStack int, stackMode string, runPSRAM, apStack int) string {
	var b strings.Builder
	b.WriteString(fmt.Sprintf(`/* AP task: stack=%d bytes (%s) */
#include "bk_private/bk_init.h"
#include <components/system.h>
#include <os/os.h>
#include <os/mem.h>
#include <components/log.h>
#define TAG "bk_app"
extern void zig_main(void);
static void zig_task(void *arg) { (void)arg; zig_main(); }
int main(void) {
    bk_init();
    beken_thread_t t;
    int ret;
`, actualStack, stackMode))

	if runPSRAM > 0 {
		b.WriteString(fmt.Sprintf(`    BK_LOGI(TAG, "Starting zig_ap task (PSRAM, %%d bytes)\r\n", %d);
    ret = rtos_create_psram_thread(&t, 4, "zig_ap",
        (beken_thread_function_t)zig_task, %d, 0);
    if (ret != 0) {
        BK_LOGE(TAG, "PSRAM thread fail (%%d), falling back to SRAM\r\n", ret);
        ret = rtos_create_thread(&t, 4, "zig_ap",
            (beken_thread_function_t)zig_task, 32768, 0);
    }
`, runPSRAM, runPSRAM))
	} else {
		b.WriteString(fmt.Sprintf(`    BK_LOGI(TAG, "Starting zig_ap task (SRAM, %%d bytes)\r\n", %d);
    ret = rtos_create_thread(&t, 4, "zig_ap",
        (beken_thread_function_t)zig_task, %d, 0);
`, apStack, apStack))
	}

	b.WriteString(`    if (ret != 0) {
        BK_LOGE(TAG, "Thread create FAILED: %d\r\n", ret);
    }
    return 0;
}
`)
	return b.String()
}

// --- Helpers ---

func findLib(dir string) string {
	var result string
	filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() && strings.HasSuffix(info.Name(), ".a") && result == "" {
			result = path
		}
		return nil
	})
	return result
}

func fileContains(path, substr string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.Contains(string(data), substr)
}

func appendFile(dst, src string) error {
	srcData, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(dst, os.O_APPEND|os.O_WRONLY|os.O_CREATE, 0644)
	if err != nil {
		return err
	}
	defer f.Close()
	f.WriteString("\n")
	_, err = f.Write(srcData)
	return err
}

func enableMbedTLSFeature(cfgFile, commented, uncommented, label string) {
	if err := common.ReplaceInFile(cfgFile, commented, uncommented); err == nil {
		fmt.Printf("%s Enabled %s\n", prefix, label)
	}
}

func getEnvDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "%s Error: %v\n", prefix, err)
	os.Exit(1)
}
