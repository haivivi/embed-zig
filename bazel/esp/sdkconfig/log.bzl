# ESP-IDF Log
# Component: log

def _esp_log_impl(ctx):
    """Generate log sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    log_levels = {
        "none": 0,
        "error": 1,
        "warn": 2,
        "info": 3,
        "debug": 4,
        "verbose": 5,
    }
    level_num = log_levels.get(ctx.attr.default_level, 3)
    
    lines = []
    lines.append("# Log")
    lines.append("CONFIG_LOG_DEFAULT_LEVEL={}".format(level_num))
    lines.append("CONFIG_LOG_DEFAULT_LEVEL_{}=y".format(ctx.attr.default_level.upper()))
    lines.append("CONFIG_LOG_MAXIMUM_LEVEL_DEBUG=y")
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_log = rule(
    implementation = _esp_log_impl,
    attrs = {
        "default_level": attr.string(
            mandatory = True,
            doc = """CONFIG_LOG_DEFAULT_LEVEL
            默认日志输出级别
            none: 无输出
            error: 仅错误
            warn: 错误 + 警告
            info: 正常运行信息（生产环境推荐）
            debug: 详细调试信息
            verbose: 所有信息""",
        ),
    },
    doc = """日志配置""",
)
