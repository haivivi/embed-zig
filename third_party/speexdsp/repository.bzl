"""Repository rule for downloading and setting up libspeexdsp.

External projects using //third_party/speexdsp:speexdsp_fixed or speexdsp_float
must call speexdsp_repository() in their MODULE.bazel:

    load("@embed_zig//third_party/speexdsp:repository.bzl", "speexdsp_repository")
    speexdsp_repository(name = "speexdsp")
"""

_SPEEXDSP_VERSION = "1.2.1"

def _speexdsp_repository_impl(ctx):
    """Download and setup speexdsp source."""
    ctx.download_and_extract(
        url = "https://github.com/xiph/speexdsp/archive/refs/tags/SpeexDSP-{}.tar.gz".format(_SPEEXDSP_VERSION),
        strip_prefix = "speexdsp-SpeexDSP-{}".format(_SPEEXDSP_VERSION),
        sha256 = "d17ca363654556a4ff1d02cc13d9eb1fc5a8642c90b40bd54ce266c3807b91a7",
    )
    # Generate speexdsp_config_types.h (normally created by autoconf)
    ctx.file("include/speex/speexdsp_config_types.h", """
#ifndef SPEEXDSP_CONFIG_TYPES_H
#define SPEEXDSP_CONFIG_TYPES_H
#include <stdint.h>
typedef int16_t spx_int16_t;
typedef uint16_t spx_uint16_t;
typedef int32_t spx_int32_t;
typedef uint32_t spx_uint32_t;
#endif
""")

    # Include path marker — zig_library auto-detects -I from .h parent dirs.
    ctx.file("include/speexdsp_include_marker.h", "/* path marker */\n")

    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "headers",
    srcs = glob(["include/**/*.h"]),
)

filegroup(
    name = "core_srcs",
    srcs = [
        "libspeexdsp/mdf.c",
        "libspeexdsp/preprocess.c",
        "libspeexdsp/filterbank.c",
        "libspeexdsp/fftwrap.c",
        "libspeexdsp/smallft.c",
        "libspeexdsp/kiss_fft.c",
        "libspeexdsp/kiss_fftr.c",
        "libspeexdsp/resample.c",
        "libspeexdsp/buffer.c",
        "libspeexdsp/jitter.c",
        "libspeexdsp/scal.c",
    ],
)

filegroup(
    name = "internal_headers",
    srcs = glob(["libspeexdsp/*.h"]),
)
""")

speexdsp_repository = repository_rule(
    implementation = _speexdsp_repository_impl,
    doc = "Downloads libspeexdsp {} and creates filegroups for C sources and headers.".format(_SPEEXDSP_VERSION),
)
