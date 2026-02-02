# Zig App runtime configuration
# Non-IDF, controls generated app_main behavior

def _esp_app_impl(ctx):
    """Generate app config fragment (shell sourceable)."""
    out = ctx.actions.declare_file(ctx.attr.name + ".appconfig")
    
    stack_size = ctx.attr.run_in_psram
    run_in_psram = stack_size > 0
    
    lines = []
    lines.append("# Zig App Config (sourceable by shell)")
    lines.append('export RUN_APP_IN_PSRAM="{}"'.format("y" if run_in_psram else "n"))
    lines.append('export PSRAM_STACK_SIZE="{}"'.format(stack_size))
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_app = rule(
    implementation = _esp_app_impl,
    attrs = {
        "run_in_psram": attr.int(
            default = 0,
            doc = """PSRAM 任务栈大小（字节）
            0: 不在 PSRAM 运行，直接在 app_main 任务中运行（栈在内部 RAM）
            >0: 在 PSRAM 中创建任务运行，使用指定的栈大小
                推荐值：32768 (32KB) 普通应用，65536 (64KB) TLS/加密应用""",
        ),
    },
    doc = """Zig App 运行时配置""",
)
