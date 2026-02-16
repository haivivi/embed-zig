# BK7258 Partition Entry
# Defines a single partition in the BK partition table

BkPartitionEntryInfo = provider(
    doc = "Information about a single BK partition entry",
    fields = {
        "name": "Partition name",
        "type": "Partition type: code or data",
        "size": "Partition size as string (e.g., '68K', '1360K')",
        "offset": "Optional fixed offset (auto-calculated if empty)",
        "read": "Read permission",
        "write": "Write permission",
    },
)

def _bk_partition_entry_impl(ctx):
    name = ctx.attr.partition_name or ctx.label.name
    return [
        BkPartitionEntryInfo(
            name = name,
            type = ctx.attr.type,
            size = ctx.attr.partition_size,
            offset = ctx.attr.offset,
            read = ctx.attr.read,
            write = ctx.attr.write,
        ),
    ]

bk_partition_entry = rule(
    implementation = _bk_partition_entry_impl,
    attrs = {
        "partition_name": attr.string(
            doc = "Partition name. Defaults to target name.",
        ),
        "type": attr.string(
            mandatory = True,
            values = ["code", "data"],
            doc = "Partition type: 'code' or 'data'",
        ),
        "partition_size": attr.string(
            mandatory = True,
            doc = "Partition size: '68K', '1360K', '8K', etc.",
        ),
        "offset": attr.string(
            doc = "Fixed offset (hex string like '0x7fa000'). If empty, auto-calculated.",
        ),
        "read": attr.bool(default = True),
        "write": attr.bool(default = False),
    },
    doc = """Define a single BK partition entry.

    Example:
    ```
    bk_partition_entry(
        name = "bootloader",
        partition_name = "primary_bootloader",
        type = "code",
        partition_size = "68K",
    )
    ```
    """,
)
