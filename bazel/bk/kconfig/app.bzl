# BK7258 App runtime configuration (AP/CP)
# Matches esp_app pattern: controls generated C wrapper behavior

# =============================================================================
# AP app config
# =============================================================================

def _bk_ap_app_impl(ctx):
    # Kconfig fragment (for bk_config modules list)
    kconfig = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    kconfig_lines = [
        "# AP app-main configuration",
        "CONFIG_APP_MAIN_TASK_PRIO={}".format(ctx.attr.main_task_prio),
        "CONFIG_APP_MAIN_TASK_STACK_SIZE={}".format(ctx.attr.main_task_stack_size),
        "# CONFIG_MATTER_START is not set",
        "# CONFIG_AT is not set",
        "# CONFIG_AT_SERVER is not set",
    ]
    ctx.actions.write(output = kconfig, content = "\n".join(kconfig_lines) + "\n")

    # App config (for bk_zig_app app_config — like esp_app)
    appconfig = ctx.actions.declare_file(ctx.attr.name + ".appconfig")
    appconfig_lines = [
        "# BK App Config (sourceable by shell)",
        'export BK_RUN_IN_PSRAM="{}"'.format(ctx.attr.run_in_psram),
    ]
    ctx.actions.write(output = appconfig, content = "\n".join(appconfig_lines) + "\n")

    return [
        DefaultInfo(files = depset([kconfig])),
        OutputGroupInfo(appconfig = depset([appconfig])),
    ]

bk_ap_app = rule(
    implementation = _bk_ap_app_impl,
    attrs = {
        "main_task_prio": attr.int(mandatory = True, doc = "CONFIG_APP_MAIN_TASK_PRIO (0..9)"),
        "main_task_stack_size": attr.int(mandatory = True, doc = "CONFIG_APP_MAIN_TASK_STACK_SIZE"),
        "run_in_psram": attr.int(
            default = 0,
            doc = """PSRAM task stack size (bytes).
            0: use SRAM (16KB default stack)
            >0: allocate stack from PSRAM via psram_malloc
            Recommended: 32768 (32KB) normal apps, 131072 (128KB) TLS/crypto apps.""",
        ),
    },
    doc = """AP app configuration.
    Generates Kconfig fragment (for bk_config modules) AND appconfig (for bk_zig_app).
    Matches esp_app pattern with run_in_psram.""",
)

# =============================================================================
# CP app config
# =============================================================================

def _bk_cp_app_impl(ctx):
    kconfig = ctx.actions.declare_file(ctx.attr.name + ".kconfig")
    kconfig_lines = [
        "# CP app-main configuration",
        "CONFIG_APP_MAIN_TASK_PRIO={}".format(ctx.attr.main_task_prio),
        "CONFIG_APP_MAIN_TASK_STACK_SIZE={}".format(ctx.attr.main_task_stack_size),
        "# CONFIG_MATTER_START is not set",
    ]
    ctx.actions.write(output = kconfig, content = "\n".join(kconfig_lines) + "\n")
    return [DefaultInfo(files = depset([kconfig]))]

bk_cp_app = rule(
    implementation = _bk_cp_app_impl,
    attrs = {
        "main_task_prio": attr.int(mandatory = True, doc = "CONFIG_APP_MAIN_TASK_PRIO (0..9)"),
        "main_task_stack_size": attr.int(mandatory = True, doc = "CONFIG_APP_MAIN_TASK_STACK_SIZE"),
    },
    doc = "CP app-main task config (Kconfig only, no PSRAM runtime).",
)
