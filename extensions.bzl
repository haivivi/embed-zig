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
        stripPrefix = "opus-{}".format(_OPUS_VERSION),
    )
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "opus_public_headers",
    srcs = glob(["include/*.h"]),
)

filegroup(
    name = "opus_srcs",
    srcs = glob([
        "src/*.c",
        "celt/*.c",
        "silk/*.c",
        "silk/float/*.c",
    ], exclude = [
        "src/opus_demo.c",
        "src/opus_compare.c",
        "src/repacketizer_demo.c",
        "celt/opus_custom_demo.c",
    ]),
)

filegroup(
    name = "opus_internal_headers",
    srcs = glob([
        "src/*.h",
        "celt/*.h",
        "silk/*.h",
        "silk/float/*.h",
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
        stripPrefix = "libogg-{}".format(_OGG_VERSION),
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
        stripPrefix = "zig-{}-baseline".format(platform),
    )

    ctx.file("BUILD.bazel", """
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
