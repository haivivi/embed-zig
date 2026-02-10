# BK7258 Partition Presets
# Standard partition layouts for common use cases

load(":entry.bzl", "bk_partition_entry")
load(":table.bzl", "bk_partition_table")

def bk7258_default_partitions(name = "partitions", ap_size = "1156K", cp_size = "1360K", ota_size = "1428K"):
    """Standard BK7258 partition layout (8MB flash).

    Args:
        name: Target name for the partition table
        ap_size: AP application size (default 1156K)
        cp_size: CP application size (default 1360K)
        ota_size: OTA data size (default 1428K)
    """

    # Code partitions (auto-calculated offsets, sequential)
    bk_partition_entry(
        name = name + "_bootloader",
        partition_name = "primary_bootloader",
        type = "code",
        partition_size = "68K",
    )

    bk_partition_entry(
        name = name + "_cp_app",
        partition_name = "primary_cp_app",
        type = "code",
        partition_size = cp_size,
    )

    bk_partition_entry(
        name = name + "_ap_app",
        partition_name = "primary_ap_app",
        type = "code",
        partition_size = ap_size,
    )

    # Data partitions (auto-calculated, after code)
    bk_partition_entry(
        name = name + "_ota",
        partition_name = "ota",
        type = "data",
        partition_size = ota_size,
        write = True,
    )

    bk_partition_entry(
        name = name + "_usr_config",
        partition_name = "usr_config",
        type = "data",
        partition_size = "60K",
        write = True,
    )

    # System partitions (fixed offsets at flash end)
    bk_partition_entry(
        name = name + "_easyflash",
        partition_name = "easyflash",
        type = "data",
        partition_size = "8K",
        offset = "0x7fa000",
        write = True,
    )

    bk_partition_entry(
        name = name + "_easyflash_ap",
        partition_name = "easyflash_ap",
        type = "data",
        partition_size = "8K",
        offset = "0x7fc000",
        write = True,
    )

    bk_partition_entry(
        name = name + "_sys_rf",
        partition_name = "sys_rf",
        type = "data",
        partition_size = "4K",
        offset = "0x7fe000",
        write = True,
    )

    bk_partition_entry(
        name = name + "_sys_net",
        partition_name = "sys_net",
        type = "data",
        partition_size = "4K",
        offset = "0x7ff000",
        write = True,
    )

    # Assemble table
    bk_partition_table(
        name = name,
        entries = [
            ":" + name + "_bootloader",
            ":" + name + "_cp_app",
            ":" + name + "_ap_app",
            ":" + name + "_ota",
            ":" + name + "_usr_config",
            ":" + name + "_easyflash",
            ":" + name + "_easyflash_ap",
            ":" + name + "_sys_rf",
            ":" + name + "_sys_net",
        ],
    )
