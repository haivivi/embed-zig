# ESP32 LittleFS Image Generator
# Creates a LittleFS filesystem image from source files

def _esp_littlefs_image_impl(ctx):
    """Generate a LittleFS image from source files."""
    
    # Output binary file
    out_bin = ctx.actions.declare_file(ctx.attr.name + ".bin")
    
    # Collect all source files
    src_files = []
    for src in ctx.attr.srcs:
        src_files.extend(src.files.to_list())
    
    if not src_files:
        fail("No source files provided for LittleFS image")
    
    # Parse size
    size_str = ctx.attr.size.strip().upper()
    if size_str.endswith("K"):
        size_bytes = int(size_str[:-1]) * 1024
    elif size_str.endswith("M"):
        size_bytes = int(size_str[:-1]) * 1024 * 1024
    elif size_str.startswith("0X"):
        size_bytes = int(size_str, 16)
    else:
        size_bytes = int(size_str)
    
    # Block size
    block_size = ctx.attr.block_size
    
    # Build copy commands
    copy_commands = []
    for f in src_files:
        rel_path = f.short_path
        copy_commands.append('mkdir -p "$LFS_DIR/$(dirname {})" && cp "{}" "$LFS_DIR/{}"'.format(
            rel_path, f.path, rel_path
        ))
    
    # LittleFS uses mklittlefs tool or ESP-IDF's littlefsgen.py
    # Try ESP-IDF component first, fall back to mklittlefs
    script = """#!/bin/bash
set -e

LFS_DIR=$(mktemp -d)
trap "rm -rf $LFS_DIR" EXIT

# Copy files
{copy_commands}

# Find IDF path
if [ -z "$IDF_PATH" ]; then
    if [ -d "$HOME/esp/esp-idf" ]; then
        export IDF_PATH="$HOME/esp/esp-idf"
    elif [ -d "$HOME/esp/esp-adf/esp-idf" ]; then
        export IDF_PATH="$HOME/esp/esp-adf/esp-idf"
    fi
fi

# Try ESP-IDF littlefs component first
LITTLEFS_GEN=""
if [ -n "$IDF_PATH" ]; then
    # Check managed components
    if [ -f "$HOME/.espressif/components/joltwallet__littlefs/littlefsgen.py" ]; then
        LITTLEFS_GEN="$HOME/.espressif/components/joltwallet__littlefs/littlefsgen.py"
    elif [ -f "$IDF_PATH/components/littlefs/littlefsgen.py" ]; then
        LITTLEFS_GEN="$IDF_PATH/components/littlefs/littlefsgen.py"
    fi
fi

# Fall back to mklittlefs if available
if [ -z "$LITTLEFS_GEN" ]; then
    if command -v mklittlefs &> /dev/null; then
        mklittlefs -c "$LFS_DIR" -s {size} -b {block_size} "{output}"
        echo "Generated LittleFS image: {output}"
        exit 0
    else
        echo "Error: Neither littlefsgen.py nor mklittlefs found"
        echo "Install with: pip install littlefs-python"
        echo "Or: brew install mklittlefs"
        exit 1
    fi
fi

# Use littlefsgen.py
python3 "$LITTLEFS_GEN" \\
    --image-size={size} \\
    --block-size={block_size} \\
    "$LFS_DIR" \\
    "{output}"

echo "Generated LittleFS image: {output}"
""".format(
        copy_commands = "\n".join(copy_commands),
        size = size_bytes,
        output = out_bin.path,
        block_size = block_size,
    )
    
    ctx.actions.run_shell(
        outputs = [out_bin],
        inputs = src_files,
        command = script,
        use_default_shell_env = True,
        mnemonic = "LittleFsGen",
        progress_message = "Generating LittleFS image %s" % ctx.label,
    )
    
    return [DefaultInfo(files = depset([out_bin]))]

esp_littlefs_image = rule(
    implementation = _esp_littlefs_image_impl,
    attrs = {
        "srcs": attr.label_list(
            mandatory = True,
            allow_files = True,
            doc = "Source files to include in the LittleFS image",
        ),
        "size": attr.string(
            mandatory = True,
            doc = "Partition size: '512K', '1M', etc. Must match partition entry size.",
        ),
        "block_size": attr.int(
            default = 4096,
            doc = "LittleFS block size in bytes. Default: 4096",
        ),
    },
    doc = """Generate a LittleFS filesystem image.
    
    Example:
    ```
    esp_littlefs_image(
        name = "resources",
        srcs = glob(["resources/**"]),
        size = "512K",
    )
    
    esp_partition_entry(
        name = "storage",
        type = "data",
        subtype = "littlefs",
        size = "512K",
        data = [":resources"],
    )
    ```
    """,
)
