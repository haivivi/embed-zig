# ESP-IDF FreeRTOS
# Component: freertos, esp_system

def _esp_freertos_impl(ctx):
    """Generate FreeRTOS sdkconfig fragment."""
    out = ctx.actions.declare_file(ctx.attr.name + ".sdkconfig")
    
    lines = []
    
    lines.append("# Task Stack")
    lines.append("CONFIG_ESP_MAIN_TASK_STACK_SIZE={}".format(ctx.attr.main_task_stack_size))
    lines.append("CONFIG_ESP_SYSTEM_EVENT_TASK_STACK_SIZE=3072")
    
    lines.append("")
    lines.append("# FreeRTOS")
    lines.append("CONFIG_FREERTOS_HZ={}".format(ctx.attr.hz))
    lines.append("CONFIG_FREERTOS_ENABLE_BACKWARD_COMPATIBILITY=y")
    lines.append("CONFIG_FREERTOS_THREAD_LOCAL_STORAGE_POINTERS=2")
    
    lines.append("")
    lines.append("# Watchdog")
    lines.append("CONFIG_ESP_TASK_WDT_EN=y")
    lines.append("CONFIG_ESP_TASK_WDT_INIT=y")
    lines.append("CONFIG_ESP_TASK_WDT_TIMEOUT_S={}".format(ctx.attr.task_wdt_timeout_s))
    lines.append("CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0={}".format("y" if ctx.attr.task_wdt_check_idle_cpu0 else "n"))
    lines.append("CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1={}".format("y" if ctx.attr.task_wdt_check_idle_cpu1 else "n"))
    
    ctx.actions.write(out, "\n".join(lines) + "\n")
    return [DefaultInfo(files = depset([out]))]

esp_freertos = rule(
    implementation = _esp_freertos_impl,
    attrs = {
        "hz": attr.int(
            mandatory = True,
            doc = """CONFIG_FREERTOS_HZ
            FreeRTOS 时钟节拍频率（每秒 tick 数）
            100: 低 CPU 开销，10ms 精度
            1000: 高精度，1ms 精度（推荐）""",
        ),
        "main_task_stack_size": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_MAIN_TASK_STACK_SIZE
            app_main() 函数运行的主任务栈大小（字节）
            Typical: 4096, 8192, 16384""",
        ),
        "task_wdt_timeout_s": attr.int(
            mandatory = True,
            doc = """CONFIG_ESP_TASK_WDT_TIMEOUT_S
            任务看门狗超时时间（秒）
            Typical: 5 (strict), 30 (relaxed)""",
        ),
        "task_wdt_check_idle_cpu0": attr.bool(
            mandatory = True,
            doc = """CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU0
            是否监控 CPU0 的 idle task
            True: 如果 CPU0 idle task 被阻塞超时则触发 panic""",
        ),
        "task_wdt_check_idle_cpu1": attr.bool(
            mandatory = True,
            doc = """CONFIG_ESP_TASK_WDT_CHECK_IDLE_TASK_CPU1
            是否监控 CPU1 的 idle task（仅双核芯片有效）
            True: 如果 CPU1 idle task 被阻塞超时则触发 panic
            单核芯片（如 ESP32-C3）应设为 False""",
        ),
    },
    doc = """FreeRTOS 配置：tick 频率、任务栈、看门狗""",
)
