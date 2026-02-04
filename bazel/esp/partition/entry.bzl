# ESP32 Partition Entry
# Defines a single partition in the partition table

# Partition entry provider - carries partition info to esp_partition_table
EspPartitionEntryInfo = provider(
    doc = "Information about a single partition entry",
    fields = {
        "name": "Partition name (max 16 chars)",
        "type": "Partition type: app or data",
        "subtype": "Partition subtype (factory, ota_0, nvs, phy, spiffs, etc.)",
        "size": "Partition size as string (e.g., '24K', '1M', '*')",
        "offset": "Optional fixed offset (auto-calculated if empty)",
        "data": "Optional data files (NVS entries or filesystem image)",
        "data_bin": "Generated binary file for this partition's data (if any)",
    },
)

def _parse_size(size_str):
    """Parse size string to bytes. Returns -1 for '*' (fill remaining)."""
    if size_str == "*":
        return -1
    
    size_str = size_str.strip().upper()
    
    if size_str.endswith("K"):
        return int(size_str[:-1]) * 1024
    elif size_str.endswith("M"):
        return int(size_str[:-1]) * 1024 * 1024
    elif size_str.startswith("0X"):
        return int(size_str, 16)
    else:
        return int(size_str)

def _esp_partition_entry_impl(ctx):
    """Create a partition entry."""
    
    # Validate name length
    name = ctx.attr.partition_name or ctx.label.name
    if len(name) > 16:
        fail("Partition name '{}' exceeds 16 characters".format(name))
    
    # Validate type
    ptype = ctx.attr.type
    if ptype not in ["app", "data"]:
        fail("Partition type must be 'app' or 'data', got '{}'".format(ptype))
    
    # Validate subtype based on type
    subtype = ctx.attr.subtype
    valid_app_subtypes = ["factory", "ota_0", "ota_1", "ota_2", "ota_3", "test"]
    valid_data_subtypes = ["ota", "phy", "nvs", "nvs_keys", "coredump", "efuse", 
                          "undefined", "esphttpd", "fat", "spiffs", "littlefs"]
    
    if ptype == "app" and subtype not in valid_app_subtypes:
        fail("Invalid app subtype '{}'. Valid: {}".format(subtype, valid_app_subtypes))
    if ptype == "data" and subtype not in valid_data_subtypes:
        fail("Invalid data subtype '{}'. Valid: {}".format(subtype, valid_data_subtypes))
    
    # Parse size
    size_bytes = _parse_size(ctx.attr.partition_size)
    
    # Collect data files
    data_files = []
    for d in ctx.attr.data:
        data_files.extend(d.files.to_list())
    
    # Find data binary if exists (from esp_nvs_*, esp_spiffs_image, etc.)
    data_bin = None
    for d in ctx.attr.data:
        if hasattr(d, "files"):
            for f in d.files.to_list():
                if f.extension == "bin":
                    data_bin = f
                    break
    
    return [
        EspPartitionEntryInfo(
            name = name,
            type = ptype,
            subtype = subtype,
            size = ctx.attr.partition_size,
            offset = ctx.attr.offset,
            data = data_files,
            data_bin = data_bin,
        ),
        DefaultInfo(files = depset(data_files)),
    ]

esp_partition_entry = rule(
    implementation = _esp_partition_entry_impl,
    attrs = {
        "partition_name": attr.string(
            doc = "Partition name (max 16 chars). Defaults to target name.",
        ),
        "type": attr.string(
            mandatory = True,
            doc = "Partition type: 'app' or 'data'",
        ),
        "subtype": attr.string(
            mandatory = True,
            doc = """Partition subtype.
            For app: factory, ota_0, ota_1, ota_2, ota_3, test
            For data: ota, phy, nvs, nvs_keys, coredump, efuse, undefined, 
                      esphttpd, fat, spiffs, littlefs""",
        ),
        "partition_size": attr.string(
            mandatory = True,
            doc = "Partition size: '24K', '1M', '0x100000', or '*' for remaining space",
        ),
        "offset": attr.string(
            doc = "Optional fixed offset. If not set, auto-calculated based on order.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Optional data for this partition (NVS entries, filesystem image, etc.)",
        ),
    },
    doc = """Define a single partition entry.
    
    Example:
    ```
    esp_partition_entry(
        name = "nvs",
        type = "data",
        subtype = "nvs",
        partition_size = "24K",
        data = [":nvs_sn", ":nvs_hw_ver"],
    )
    
    esp_partition_entry(
        name = "factory",
        type = "app",
        subtype = "factory",
        partition_size = "1536K",
    )
    
    esp_partition_entry(
        name = "storage",
        type = "data",
        subtype = "spiffs",
        partition_size = "*",  # Fill remaining space
        data = [":assets_image"],
    )
    ```
    """,
)
