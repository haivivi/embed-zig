"""Module extensions for embed-zig.

Provides:
- Audio libraries (opus, ogg)
- Zig toolchain with Xtensa support
"""

# =============================================================================
# Audio Libraries
# =============================================================================

_OPUS_VERSION = "1.5.2"
_OGG_VERSION = "1.3.6"

def _opus_repo_impl(ctx):
    """Download and setup opus source."""
    ctx.download_and_extract(
        url = "https://downloads.xiph.org/releases/opus/opus-{}.tar.gz".format(_OPUS_VERSION),
        strip_prefix = "opus-{}".format(_OPUS_VERSION),
    )
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

# Public headers (include/opus.h etc.)
filegroup(
    name = "headers",
    srcs = glob(["include/*.h", "src/*.h", "celt/*.h", "silk/*.h"]),
)

# Core C sources (shared by fixed and float builds)
filegroup(
    name = "core_srcs",
    srcs = glob([
        "src/*.c",
        "celt/*.c",
        "silk/*.c",
    ], exclude = [
        "src/opus_demo.c",
        "src/opus_compare.c",
        "src/repacketizer_demo.c",
        "celt/opus_custom_demo.c",
        "celt/arm/*.c",
        "celt/x86/*.c",
        "silk/arm/*.c",
        "silk/x86/*.c",
    ]),
)

# SILK fixed-point sources (for embedded / Xtensa)
filegroup(
    name = "fixed_srcs",
    srcs = glob(["silk/fixed/*.c", "silk/fixed/*.h"], exclude = [
        "silk/fixed/arm/*.c",
        "silk/fixed/x86/*.c",
    ]),
)

# SILK float sources (for desktop / server)
filegroup(
    name = "float_srcs",
    srcs = glob(["silk/float/*.c", "silk/float/*.h"], exclude = [
        "silk/float/x86/*.c",
    ]),
)
""")

_opus_repo = repository_rule(
    implementation = _opus_repo_impl,
)

def _ogg_repo_impl(ctx):
    """Download and setup libogg source."""
    ctx.download_and_extract(
        url = "https://downloads.xiph.org/releases/ogg/libogg-{}.tar.gz".format(_OGG_VERSION),
        strip_prefix = "libogg-{}".format(_OGG_VERSION),
    )
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "ogg_srcs",
    srcs = [
        "src/bitwise.c",
        "src/framing.c",
    ],
)

filegroup(
    name = "ogg_internal_headers",
    srcs = glob(["src/*.h"]),
)

filegroup(
    name = "ogg_headers",
    srcs = glob(["include/ogg/*.h"]),
)

exports_files(glob(["include/ogg/*.h"]))
exports_files(glob(["src/*.c"]))
exports_files(glob(["src/*.h"]))
""")

_ogg_repo = repository_rule(
    implementation = _ogg_repo_impl,
)

def _audio_libs_impl(ctx):
    """Module extension for audio libraries."""
    _opus_repo(name = "opus")
    _ogg_repo(name = "ogg")

audio_libs = module_extension(
    implementation = _audio_libs_impl,
)

# =============================================================================
# LVGL UI Library
# =============================================================================

_LVGL_VERSION = "9.2.2"

def _lvgl_repo_impl(ctx):
    """Download and setup LVGL source.

    Uses curl fallback for large archive (68MB) — Bazel's built-in Java
    HTTP client hits Premature EOF on large GitHub tarballs.
    """
    url = "https://github.com/lvgl/lvgl/archive/refs/tags/v{}.tar.gz".format(_LVGL_VERSION)
    sha256 = "129b4e00e06639fa79d7e8a6cab3c1ecce2445b1a246652ccd34f22e7b17ad6f"
    archive = "lvgl.tar.gz"

    # Try Bazel native download first, fall back to curl for large files
    dl = ctx.download(
        url = url,
        output = archive,
        sha256 = sha256,
    )
    if not dl.success:
        ctx.execute(["curl", "-sL", "-o", archive, url], timeout = 300)
    ctx.extract(archive, stripPrefix = "lvgl-{}".format(_LVGL_VERSION))
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

# All C source files (excluding platform-specific drivers and GPU backends)
filegroup(
    name = "srcs",
    srcs = glob(["src/**/*.c"], exclude = [
        "src/drivers/**",
        "src/draw/nxp/**",
        "src/draw/renesas/**",
        "src/draw/sdl/**",
        "src/draw/vg_lite/**",
    ]),
)

# All headers (for include path auto-detection).
# Exclude thorvg/rapidjson/msinttypes — its stdint.h shadows system <stdint.h>.
filegroup(
    name = "headers",
    srcs = glob(["src/**/*.h", "*.h"], exclude = [
        "src/libs/thorvg/rapidjson/msinttypes/**",
    ]),
)
""")

_lvgl_repo = repository_rule(
    implementation = _lvgl_repo_impl,
)

def _lvgl_libs_impl(ctx):
    """Module extension for LVGL library."""
    _lvgl_repo(name = "lvgl")

lvgl_libs = module_extension(
    implementation = _lvgl_libs_impl,
)

# =============================================================================
# FFmpeg WASM (for WebSim screen recording → mp4)
# =============================================================================

def _ffmpeg_wasm_repo_impl(ctx):
    """Download FFmpeg WASM files for local bundling (UMD build)."""
    # @ffmpeg/ffmpeg UMD bundle (self-contained, no ESM import chain)
    ctx.download(
        url = "https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@0.12.10/dist/umd/ffmpeg.js",
        output = "ffmpeg.js",
    )
    # Worker chunk loaded by the UMD bundle
    ctx.download(
        url = "https://cdn.jsdelivr.net/npm/@ffmpeg/ffmpeg@0.12.10/dist/umd/814.ffmpeg.js",
        output = "814.ffmpeg.js",
    )
    # @ffmpeg/core (WASM engine)
    ctx.download(
        url = "https://cdn.jsdelivr.net/npm/@ffmpeg/core@0.12.6/dist/umd/ffmpeg-core.js",
        output = "ffmpeg-core.js",
    )
    ctx.download(
        url = "https://cdn.jsdelivr.net/npm/@ffmpeg/core@0.12.6/dist/umd/ffmpeg-core.wasm",
        output = "ffmpeg-core.wasm",
    )
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "ffmpeg_files",
    srcs = [
        "ffmpeg.js",
        "814.ffmpeg.js",
        "ffmpeg-core.js",
        "ffmpeg-core.wasm",
    ],
)
""")

_ffmpeg_wasm_repo = repository_rule(
    implementation = _ffmpeg_wasm_repo_impl,
)

def _ffmpeg_wasm_ext_impl(ctx):
    _ffmpeg_wasm_repo(name = "ffmpeg_wasm")

ffmpeg_wasm = module_extension(
    implementation = _ffmpeg_wasm_ext_impl,
)

# =============================================================================
# html2canvas (for WebSim DOM-to-canvas screen recording)
# =============================================================================

def _html2canvas_repo_impl(ctx):
    """Download html2canvas UMD bundle."""
    ctx.download(
        url = "https://unpkg.com/html2canvas@1.4.1/dist/html2canvas.min.js",
        output = "html2canvas.min.js",
    )
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "html2canvas",
    srcs = ["html2canvas.min.js"],
)
""")

_html2canvas_repo = repository_rule(
    implementation = _html2canvas_repo_impl,
)

def _html2canvas_ext_impl(ctx):
    _html2canvas_repo(name = "html2canvas")

html2canvas = module_extension(
    implementation = _html2canvas_ext_impl,
)

# =============================================================================
# Zig Toolchain (with Xtensa support)
# =============================================================================

_ZIG_VERSION = "espressif-0.15.2"

# SHA256 checksums for Zig compiler with Xtensa support
_ZIG_SHA256 = {
    "aarch64-linux-gnu": "26c0b1393b793d8b82971b3afaff90bd20d4ce361bbd99c51c6b9bbf3de088ed",
    "aarch64-macos-none": "63fcf40aebe05d4e0064bfae3a91e3b17f222a816f9c532ad7319fce0a7ca345",
    "x86_64-linux-gnu": "cbe4e592622daaf26db72a788a6b4eb7ed57e91967660031fb8fb0bb05ce02ea",
    "x86_64-macos-none": "6980c2b0bc21f372dd70e7d1838c2348d6b2716d8af0c150940314d7f55f9007",
}

def _zig_toolchain_impl(ctx):
    """Download pre-built Zig compiler with Xtensa support."""
    os = ctx.os.name
    arch = ctx.os.arch

    # Map OS names
    if os == "mac os x" or os.startswith("darwin"):
        os_name = "macos"
        os_abi = "none"
    elif os.startswith("linux"):
        os_name = "linux"
        os_abi = "gnu"
    else:
        fail("Unsupported OS: " + os)

    # Map architecture
    if arch == "amd64" or arch == "x86_64":
        arch_name = "x86_64"
    elif arch == "aarch64" or arch == "arm64":
        arch_name = "aarch64"
    else:
        fail("Unsupported architecture: " + arch)

    platform = "{}-{}-{}".format(arch_name, os_name, os_abi)
    filename = "zig-{}-baseline.tar.xz".format(platform)

    url = "https://github.com/haivivi/embed-zig/releases/download/{}/{}".format(
        _ZIG_VERSION,
        filename,
    )

    ctx.download_and_extract(
        url = url,
        sha256 = _ZIG_SHA256.get(platform, ""),
        strip_prefix = "zig-{}-baseline".format(platform),
    )

    ctx.file("BUILD.bazel", """
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "zig_files",
    srcs = glob(["**/*"]),
)

exports_files(["zig"])

sh_binary(
    name = "zig_bin",
    srcs = ["zig"],
    data = glob(["lib/**/*"]),
)
""")

    # Create a version file
    ctx.file("VERSION", _ZIG_VERSION)

_zig_toolchain_repo = repository_rule(
    implementation = _zig_toolchain_impl,
)

def _zig_toolchain_ext_impl(ctx):
    """Module extension for Zig toolchain."""
    _zig_toolchain_repo(name = "zig_toolchain")

zig_toolchain = module_extension(
    implementation = _zig_toolchain_ext_impl,
)

# =============================================================================
# ESP Sysroot (auto-detect newlib headers for cross-compilation)
# =============================================================================

def _esp_sysroot_impl(ctx):
    """Auto-detect ESP-IDF toolchain newlib headers."""
    home = ctx.os.environ.get("HOME", "")
    espressif_dir = home + "/.espressif/tools/xtensa-esp-elf"

    # Find the latest installed version
    result = ctx.execute(["ls", espressif_dir])
    newlib_include = ""
    if result.return_code == 0:
        versions = sorted(result.stdout.strip().split("\n"), reverse = True)
        for v in versions:
            if v.startswith("esp-"):
                candidate = espressif_dir + "/" + v + "/xtensa-esp-elf/xtensa-esp-elf/include"
                check = ctx.execute(["test", "-d", candidate])
                if check.return_code == 0:
                    newlib_include = candidate
                    break

    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

# Auto-detected newlib include path: {path}
NEWLIB_INCLUDE = "{path}"
""".format(path = newlib_include))

    ctx.file("defs.bzl", """
# Auto-detected ESP newlib include path for cross-compilation
NEWLIB_INCLUDE = "{path}"
""".format(path = newlib_include))

_esp_sysroot_repo = repository_rule(
    implementation = _esp_sysroot_impl,
    environ = ["HOME"],
)

def _esp_sysroot_ext_impl(ctx):
    """Module extension for ESP sysroot detection."""
    _esp_sysroot_repo(name = "esp_sysroot")

esp_sysroot = module_extension(
    implementation = _esp_sysroot_ext_impl,
)
