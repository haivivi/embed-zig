# Zig App runtime configuration
# Non-IDF, controls generated app_main behavior

def _esp_app_impl(ctx):
    """Generate app config fragment (shell sourceable)."""
    out = ctx.actions.declare_file(ctx.attr.name + ".appconfig")
    
    lines = []
    lines.append("# Zig App Config (sourceable by shell)")
    lines.append('export RUN_APP_IN_PSRAM="{}"'.format("y" if ctx.attr.run_in_psram else "n"))
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_app = rule(
    implementation = _esp_app_impl,
    attrs = {
        "run_in_psram": attr.bool(
            mandatory = True,
            doc = """是否将 run_app 运行在 PSRAM 中
            True: app_main 创建一个栈在 PSRAM 的任务来运行 run_app
                  适合大多数程序，可以使用更大的栈空间
                  注意：如果需要同时读取 flash，需要在 IRAM 任务中操作
            False: run_app 直接在 app_main 任务中运行（栈在内部 RAM）""",
        ),
    },
    doc = """Zig App 运行时配置""",
)
