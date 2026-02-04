# ESP32 NVS (Non-Volatile Storage) Rules
# Define NVS entries that can be compiled into an NVS partition image

# NVS entry provider - carries NVS data to partition
EspNvsEntryInfo = provider(
    doc = "Information about a single NVS entry",
    fields = {
        "namespace": "NVS namespace",
        "key": "NVS key",
        "type": "NVS type: string, u8, i8, u16, i16, u32, i32, u64, i64, bool, blob",
        "default": "Default value (can be overridden by --define)",
        "define_key": "Key for --define override: key@namespace",
    },
)

def _esp_nvs_entry_impl(ctx, nvs_type):
    """Common implementation for all NVS entry types."""
    namespace = ctx.attr.namespace
    key = ctx.attr.key
    
    # Validate namespace and key
    if not namespace:
        fail("namespace is required")
    if not key:
        fail("key is required")
    if len(namespace) > 15:
        fail("namespace '{}' exceeds 15 characters".format(namespace))
    if len(key) > 15:
        fail("key '{}' exceeds 15 characters".format(key))
    
    # Define key for --define override: use target name
    define_key = ctx.label.name
    
    # Get default value
    default = None
    if hasattr(ctx.attr, "default"):
        default = ctx.attr.default
    elif hasattr(ctx.attr, "default_value"):
        default = ctx.attr.default_value
    
    return [
        EspNvsEntryInfo(
            namespace = namespace,
            key = key,
            type = nvs_type,
            default = default,
            define_key = define_key,
        ),
        DefaultInfo(files = depset()),
    ]

# String entry
def _esp_nvs_string_impl(ctx):
    return _esp_nvs_entry_impl(ctx, "string")

esp_nvs_string = rule(
    implementation = _esp_nvs_string_impl,
    attrs = {
        "namespace": attr.string(
            mandatory = True,
            doc = "NVS namespace (max 15 chars)",
        ),
        "key": attr.string(
            mandatory = True,
            doc = "NVS key (max 15 chars)",
        ),
        "default": attr.string(
            doc = "Default value. Can be overridden by --define key@namespace=value",
        ),
    },
    doc = """Define an NVS string entry.
    
    Example:
    ```
    esp_nvs_string(
        name = "nvs_sn",
        namespace = "device",
        key = "sn",
    )
    ```
    
    Override with: --define nvs_sn=H106-000001
    If no default and no --define value, the entry is skipped.
    """,
)

# Integer entries - use string for default to distinguish "not set" from "0"
def _make_int_rule(type_name):
    """Create an integer NVS rule."""
    
    def _impl(ctx):
        return _esp_nvs_entry_impl(ctx, type_name)
    
    return rule(
        implementation = _impl,
        attrs = {
            "namespace": attr.string(
                mandatory = True,
                doc = "NVS namespace (max 15 chars)",
            ),
            "key": attr.string(
                mandatory = True,
                doc = "NVS key (max 15 chars)",
            ),
            "default": attr.string(
                doc = "Default value as string. Can be overridden by --define key@namespace=value",
            ),
        },
        doc = """Define an NVS {} entry.
        
        Example:
        ```
        esp_nvs_{}(
            name = "nvs_hw_ver",
            namespace = "device",
            key = "hw_ver",
        )
        ```
        
        Override with: --define nvs_hw_ver=3
        """.format(type_name, type_name),
    )

esp_nvs_u8 = _make_int_rule("u8")
esp_nvs_i8 = _make_int_rule("i8")
esp_nvs_u16 = _make_int_rule("u16")
esp_nvs_i16 = _make_int_rule("i16")
esp_nvs_u32 = _make_int_rule("u32")
esp_nvs_i32 = _make_int_rule("i32")
esp_nvs_u64 = _make_int_rule("u64")
esp_nvs_i64 = _make_int_rule("i64")

# Boolean entry - use string for default to distinguish "not set" from "false"
def _esp_nvs_bool_impl(ctx):
    return _esp_nvs_entry_impl(ctx, "bool")

esp_nvs_bool = rule(
    implementation = _esp_nvs_bool_impl,
    attrs = {
        "namespace": attr.string(
            mandatory = True,
            doc = "NVS namespace (max 15 chars)",
        ),
        "key": attr.string(
            mandatory = True,
            doc = "NVS key (max 15 chars)",
        ),
        "default": attr.string(
            doc = "Default value as string (true/false). Can be overridden by --define key@namespace=true/false",
        ),
    },
    doc = """Define an NVS boolean entry.
    
    Example:
    ```
    esp_nvs_bool(
        name = "nvs_debug",
        namespace = "device",
        key = "debug",
    )
    ```
    
    Override with: --define nvs_debug=true
    """,
)

# Blob entry (from file)
def _esp_nvs_blob_impl(ctx):
    namespace = ctx.attr.namespace
    key = ctx.attr.key
    
    if not namespace:
        fail("namespace is required")
    if not key:
        fail("key is required")
    if len(namespace) > 15:
        fail("namespace '{}' exceeds 15 characters".format(namespace))
    if len(key) > 15:
        fail("key '{}' exceeds 15 characters".format(key))
    
    define_key = "{}@{}".format(key, namespace)
    
    # Get file if provided
    files = []
    if ctx.attr.file:
        files = ctx.attr.file.files.to_list()
    
    return [
        EspNvsEntryInfo(
            namespace = namespace,
            key = key,
            type = "blob",
            default = files[0].path if files else None,
            define_key = define_key,
        ),
        DefaultInfo(files = depset(files)),
    ]

esp_nvs_blob = rule(
    implementation = _esp_nvs_blob_impl,
    attrs = {
        "namespace": attr.string(
            mandatory = True,
            doc = "NVS namespace (max 15 chars)",
        ),
        "key": attr.string(
            mandatory = True,
            doc = "NVS key (max 15 chars)",
        ),
        "file": attr.label(
            allow_single_file = True,
            doc = "Binary file to store as blob",
        ),
    },
    doc = """Define an NVS blob entry from a file.
    
    Example:
    ```
    esp_nvs_blob(
        name = "nvs_cal_data",
        namespace = "cal",
        key = "adc",
        file = ":calibration.bin",
    )
    ```
    """,
)

# =============================================================================
# NVS Image Generation
# =============================================================================

def _nvs_type_to_csv_type(nvs_type):
    """Convert NVS type to CSV type string."""
    type_map = {
        "string": "data",
        "u8": "data",
        "i8": "data",
        "u16": "data",
        "i16": "data",
        "u32": "data",
        "i32": "data",
        "u64": "data",
        "i64": "data",
        "bool": "data",
        "blob": "file",
    }
    return type_map.get(nvs_type, "data")

def _nvs_type_to_csv_encoding(nvs_type):
    """Convert NVS type to CSV encoding string."""
    encoding_map = {
        "string": "string",
        "u8": "u8",
        "i8": "i8",
        "u16": "u16",
        "i16": "i16",
        "u32": "u32",
        "i32": "i32",
        "u64": "u64",
        "i64": "i64",
        "bool": "u8",  # bool stored as u8
        "blob": "binary",
    }
    return encoding_map.get(nvs_type, "string")

def _esp_nvs_image_impl(ctx):
    """Generate NVS partition binary from entries."""
    
    # Collect entries and build CSV
    csv_lines = ["key,type,encoding,value"]
    current_namespace = None
    
    for entry_target in ctx.attr.entries:
        if EspNvsEntryInfo not in entry_target:
            fail("Target {} does not provide EspNvsEntryInfo".format(entry_target.label))
        
        entry = entry_target[EspNvsEntryInfo]
        
        # Add namespace line if changed
        if entry.namespace != current_namespace:
            csv_lines.append("{},namespace,,".format(entry.namespace))
            current_namespace = entry.namespace
        
        # Get value: check --define override, else use default
        value = ctx.var.get(entry.define_key, "")
        if not value and entry.default != None:
            value = str(entry.default)
        
        # Skip if no value
        if not value:
            continue
        
        # Handle bool conversion
        if entry.type == "bool":
            value = "1" if value.lower() in ["true", "1", "yes"] else "0"
        
        csv_type = _nvs_type_to_csv_type(entry.type)
        csv_encoding = _nvs_type_to_csv_encoding(entry.type)
        
        csv_lines.append("{},{},{},{}".format(
            entry.key,
            csv_type,
            csv_encoding,
            value,
        ))
    
    # Write CSV file
    csv_file = ctx.actions.declare_file(ctx.attr.name + ".csv")
    ctx.actions.write(csv_file, "\n".join(csv_lines) + "\n")
    
    # Generate NVS binary using nvs_partition_gen.py
    bin_file = ctx.actions.declare_file(ctx.attr.name + ".bin")
    
    # Parse partition size
    size_str = ctx.attr.partition_size.strip().upper()
    if size_str.endswith("K"):
        size_bytes = int(size_str[:-1]) * 1024
    elif size_str.endswith("M"):
        size_bytes = int(size_str[:-1]) * 1024 * 1024
    elif size_str.startswith("0X"):
        size_bytes = int(size_str, 16)
    else:
        size_bytes = int(size_str)
    
    ctx.actions.run_shell(
        outputs = [bin_file],
        inputs = [csv_file],
        command = """#!/bin/bash
set -e

# Find IDF path and use its Python environment
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

# Use IDF's Python venv if available
IDF_PYTHON="$HOME/.espressif/python_env/idf5.5_py3.13_env/bin/python"
if [ ! -f "$IDF_PYTHON" ]; then
    # Fallback: find any idf python env
    IDF_PYTHON=$(find "$HOME/.espressif/python_env" -name "python" -type f 2>/dev/null | head -1)
fi
if [ ! -f "$IDF_PYTHON" ]; then
    IDF_PYTHON="python3"
fi

"$IDF_PYTHON" -m esp_idf_nvs_partition_gen generate "{csv}" "{bin}" {size}
""".format(
            csv = csv_file.path,
            bin = bin_file.path,
            size = size_bytes,
        ),
        use_default_shell_env = True,
        progress_message = "Generating NVS image %s" % ctx.label,
    )
    
    return [
        DefaultInfo(files = depset([bin_file, csv_file])),
    ]

esp_nvs_image = rule(
    implementation = _esp_nvs_image_impl,
    attrs = {
        "entries": attr.label_list(
            mandatory = True,
            providers = [EspNvsEntryInfo],
            doc = "List of esp_nvs_* entries",
        ),
        "partition_size": attr.string(
            default = "24K",
            doc = "NVS partition size (must match partition table)",
        ),
    },
    doc = """Generate NVS partition binary from entries.
    
    Values can be overridden with --define key@namespace=value
    
    Example:
    ```
    esp_nvs_image(
        name = "nvs_data",
        entries = [
            ":nvs_sn",
            ":nvs_hw_ver",
            ":nvs_debug",
        ],
        partition_size = "24K",
    )
    ```
    
    Override values:
    ```
    bazel build //:nvs_data --define sn@device=H106-001
    ```
    """,
)
