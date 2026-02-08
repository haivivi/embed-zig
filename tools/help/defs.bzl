"""Reusable help_tool macro for Bazel workspaces.

External repos can import and use this to get a project overview tool:

    # In your BUILD.bazel:
    load("@embed_zig//tools/help:defs.bzl", "help_tool")
    help_tool(name = "help")

    # Then run:
    bazel run //tools/help
"""

# Resolve to the help binary in this repo (embed_zig), regardless of
# which repo loads this .bzl file. Label() at top-level resolves
# relative to the repo containing this .bzl file.
_HELP_BIN = Label("//tools/help:help_bin")

def help_tool(name = "help", visibility = None):
    """Creates a project help tool target.

    The tool runs `bazel query` at runtime to discover the *calling*
    workspace's targets, so it works in any Bazel project.

    Args:
        name: Target name. Defaults to "help".
        visibility: Bazel visibility. Defaults to public.
    """
    native.alias(
        name = name,
        actual = _HELP_BIN,
        visibility = visibility or ["//visibility:public"],
    )
