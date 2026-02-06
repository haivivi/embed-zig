"""Board transition rules for building ESP apps with specific board configurations.

Usage:
    esp_board_build(
        name = "myapp_korvo2_v3",
        target = "//examples/apps/myapp/esp:app",
        board = "korvo2_v3",
    )

This allows building the same app target with different board settings
in a single `bazel build` invocation.
"""

def _board_transition_impl(settings, attr):
    return {"//bazel:board": attr.board}

_board_transition = transition(
    implementation = _board_transition_impl,
    inputs = [],
    outputs = ["//bazel:board"],
)

def _esp_board_build_impl(ctx):
    # With transitions, ctx.attr.target is a list (even for 1:1 transitions)
    target = ctx.attr.target[0]
    return [DefaultInfo(files = target[DefaultInfo].files)]

esp_board_build = rule(
    implementation = _esp_board_build_impl,
    attrs = {
        "target": attr.label(cfg = _board_transition),
        "board": attr.string(mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Build an ESP app target with a specific board configuration.",
)
