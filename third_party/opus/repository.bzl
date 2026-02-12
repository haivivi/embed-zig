"""Repository rule for downloading and setting up libopus.

External projects using //third_party/opus:opus_fixed or opus_float
must call opus_repository() in their WORKSPACE or MODULE.bazel:

    load("@embed_zig//third_party/opus:repository.bzl", "opus_repository")
    opus_repository(name = "opus")
"""

_OPUS_VERSION = "1.5.2"

def _opus_repository_impl(ctx):
    """Download and setup opus source."""
    ctx.download_and_extract(
        url = "https://downloads.xiph.org/releases/opus/opus-{}.tar.gz".format(_OPUS_VERSION),
        strip_prefix = "opus-{}".format(_OPUS_VERSION),
        sha256 = "65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1",
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

opus_repository = repository_rule(
    implementation = _opus_repository_impl,
    doc = "Downloads libopus {} and creates filegroups for C sources and headers.".format(_OPUS_VERSION),
)
