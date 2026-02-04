# ESP32 SPIFFS Image Generator
# Creates a SPIFFS filesystem image from source files

def _esp_spiffs_image_impl(ctx):
    """Generate a SPIFFS image from source files."""
    
    # Output binary file
    out_bin = ctx.actions.declare_file(ctx.attr.name + ".bin")
    
    # Collect all source files
    src_files = []
    for src in ctx.attr.srcs:
        src_files.extend(src.files.to_list())
    
    if not src_files:
        fail("No source files provided for SPIFFS image")
    
    # Parse size
    size_str = ctx.attr.partition_size.strip().upper()
    if size_str.endswith("K"):
        size_bytes = int(size_str[:-1]) * 1024
    elif size_str.endswith("M"):
        size_bytes = int(size_str[:-1]) * 1024 * 1024
    elif size_str.startswith("0X"):
        size_bytes = int(size_str, 16)
    else:
        size_bytes = int(size_str)
    
    # Page size and block size
    page_size = ctx.attr.page_size
    block_size = ctx.attr.block_size
    
    # Create a script that:
    # 1. Creates a temp directory
    # 2. Copies files preserving structure
    # 3. Runs spiffsgen.py
    
    # Build copy commands
    copy_commands = []
    strip_prefix = ctx.attr.strip_prefix
    
    # Auto-detect common subdir after strip_prefix (for data_select support)
    # e.g., if files are data/tiga/a.txt and data/tiga/b.txt, auto-strip "tiga/"
    common_subdir = None
    if strip_prefix and ctx.attr.auto_strip_subdir:
        subdirs = set()
        for f in src_files:
            rel = f.short_path
            if rel.startswith(strip_prefix):
                rel = rel[len(strip_prefix):]
                if rel.startswith("/"):
                    rel = rel[1:]
                # Get first directory component
                if "/" in rel:
                    subdirs.add(rel.split("/")[0])
        # If all files share the same subdir, strip it too
        if len(subdirs) == 1:
            common_subdir = list(subdirs)[0]
    
    for f in src_files:
        # Strip prefix from path to get relative path in SPIFFS
        rel_path = f.short_path
        if strip_prefix and rel_path.startswith(strip_prefix):
            rel_path = rel_path[len(strip_prefix):]
            if rel_path.startswith("/"):
                rel_path = rel_path[1:]
            # Strip common subdir if detected
            if common_subdir and rel_path.startswith(common_subdir + "/"):
                rel_path = rel_path[len(common_subdir) + 1:]
        # Just use basename if still too long or no strip prefix
        if not strip_prefix:
            rel_path = f.basename
        copy_commands.append('mkdir -p "$SPIFFS_DIR/$(dirname {})" && cp "{}" "$SPIFFS_DIR/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    script = """#!/bin/bash
set -e

SPIFFS_DIR=$(mktemp -d)
trap "rm -rf $SPIFFS_DIR" EXIT

# Copy files
{copy_commands}

# Find IDF path
if [ -z "$IDF_PATH" ]; then
    if [ -d "$HOME/esp/esp-idf" ]; then
        export IDF_PATH="$HOME/esp/esp-idf"
    elif [ -d "$HOME/esp/esp-adf/esp-idf" ]; then
        export IDF_PATH="$HOME/esp/esp-adf/esp-idf"
    else
        echo "Error: IDF_PATH not set and ESP-IDF not found"
        exit 1
    fi
fi

# Run spiffsgen.py
python3 "$IDF_PATH/components/spiffs/spiffsgen.py" \\
    {size} \\
    "$SPIFFS_DIR" \\
    "{output}" \\
    --page-size={page_size} \\
    --block-size={block_size}

echo "Generated SPIFFS image: {output}"
""".format(
        copy_commands = "\n".join(copy_commands),
        size = size_bytes,
        output = out_bin.path,
        page_size = page_size,
        block_size = block_size,
    )
    
    ctx.actions.run_shell(
        outputs = [out_bin],
        inputs = src_files,
        command = script,
        use_default_shell_env = True,
        mnemonic = "SpiffsGen",
        progress_message = "Generating SPIFFS image %s" % ctx.label,
    )
    
    return [DefaultInfo(files = depset([out_bin]))]

esp_spiffs_image = rule(
    implementation = _esp_spiffs_image_impl,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Source files to include in the SPIFFS image",
        ),
        "partition_size": attr.string(
            mandatory = True,
            doc = "Partition size: '512K', '1M', etc. Must match partition entry size.",
        ),
        "page_size": attr.int(
            default = 256,
            doc = "SPIFFS page size in bytes. Default: 256",
        ),
        "block_size": attr.int(
            default = 4096,
            doc = "SPIFFS block size in bytes. Default: 4096",
        ),
        "strip_prefix": attr.string(
            doc = "Path prefix to strip from source files. E.g., 'examples/apps/myapp/data'",
        ),
        "auto_strip_subdir": attr.bool(
            default = True,
            doc = "Auto-detect and strip common subdirectory (e.g., 'tiga' from data/tiga/**). Useful with data_select.",
        ),
    },
    doc = """Generate a SPIFFS filesystem image.
    
    Example:
    ```
    esp_spiffs_image(
        name = "assets",
        srcs = glob(["assets/**"]),
        partition_size = "512K",
    )
    
    esp_partition_entry(
        name = "storage",
        type = "data",
        subtype = "spiffs",
        partition_size = "512K",
        data = [":assets"],
    )
    ```
    """,
)
