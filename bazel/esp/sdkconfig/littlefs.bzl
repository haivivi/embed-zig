# ESP-IDF LittleFS
# Component: esp_littlefs

def _esp_littlefs_impl(ctx):
    """Generate LittleFS sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    
    lines.append("# LittleFS")
    lines.append("CONFIG_LITTLEFS_MAX_PARTITIONS={}".format(ctx.attr.max_partitions))
    lines.append("CONFIG_LITTLEFS_PAGE_SIZE=256")
    lines.append("CONFIG_LITTLEFS_READ_SIZE=128")
    lines.append("CONFIG_LITTLEFS_WRITE_SIZE=128")
    lines.append("CONFIG_LITTLEFS_LOOKAHEAD_SIZE=128")
    lines.append("CONFIG_LITTLEFS_CACHE_SIZE=512")
    lines.append("CONFIG_LITTLEFS_BLOCK_CYCLES=512")
    lines.append("CONFIG_LITTLEFS_OBJ_NAME_LEN=64")
    lines.append("CONFIG_LITTLEFS_USE_MTIME=y")
    lines.append("CONFIG_LITTLEFS_MTIME_USE_SECONDS=y")
    lines.append("CONFIG_LITTLEFS_ASSERTS=y")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_littlefs = rule(
    implementation = _esp_littlefs_impl,
    attrs = {
        "max_partitions": attr.int(
            mandatory = True,
            doc = """CONFIG_LITTLEFS_MAX_PARTITIONS
            最大可挂载的 LittleFS 分区数
            每个挂载的分区会占用一些 RAM 做缓存
            Typical: 1-3""",
        ),
    },
    doc = """LittleFS 文件系统配置
    - 掉电安全
    - 支持目录
    - 比 SPIFFS 更适合大文件
    - 比 SPIFFS 内存占用更低""",
)

LITTLEFS_ATTRS = {
    "littlefs": attr.label(
        allow_single_file = True,
        doc = "LittleFS config from esp_littlefs rule",
    ),
}
