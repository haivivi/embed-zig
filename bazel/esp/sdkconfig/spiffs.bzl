# ESP-IDF SPIFFS
# Component: spiffs

def _esp_spiffs_impl(ctx):
    """Generate SPIFFS sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    
    lines.append("# SPIFFS")
    lines.append("CONFIG_SPIFFS_MAX_PARTITIONS={}".format(ctx.attr.max_partitions))
    lines.append("CONFIG_SPIFFS_CACHE=y")
    lines.append("CONFIG_SPIFFS_CACHE_WR=y")
    lines.append("CONFIG_SPIFFS_PAGE_CHECK=y")
    lines.append("CONFIG_SPIFFS_GC_MAX_RUNS=10")
    lines.append("CONFIG_SPIFFS_PAGE_SIZE=256")
    lines.append("CONFIG_SPIFFS_OBJ_NAME_LEN=32")
    lines.append("CONFIG_SPIFFS_USE_MAGIC=y")
    lines.append("CONFIG_SPIFFS_USE_MAGIC_LENGTH=y")
    lines.append("CONFIG_SPIFFS_META_LENGTH=4")
    lines.append("CONFIG_SPIFFS_USE_MTIME=y")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_spiffs = rule(
    implementation = _esp_spiffs_impl,
    attrs = {
        "max_partitions": attr.int(
            mandatory = True,
            doc = """CONFIG_SPIFFS_MAX_PARTITIONS
            最大可挂载的 SPIFFS 分区数
            每个挂载的分区会占用一些 RAM 做缓存
            Typical: 1-3""",
        ),
    },
    doc = """SPIFFS 文件系统配置
    - 内置磨损均衡
    - 不支持目录
    - 适合小文件和键值存储""",
)

SPIFFS_ATTRS = {
    "spiffs": attr.label(
        allow_single_file = True,
        doc = "SPIFFS config from esp_spiffs rule",
    ),
}
