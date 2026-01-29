# Sdkconfig validation
# Checks configuration consistency at build time

def _esp_validate_impl(ctx):
    """Validate sdkconfig consistency."""
    out = ctx.actions.declare_file(ctx.attr.name + ".validated")
    
    # Read all config files and check consistency
    check_script = """
set -e

# Parse configs
PSRAM_ENABLED="n"
RUN_IN_PSRAM="n"

# Check psram config
if [ -f "{psram}" ]; then
    if grep -q "CONFIG_SPIRAM=y" "{psram}"; then
        PSRAM_ENABLED="y"
    fi
fi

# Check app config
if [ -f "{app}" ]; then
    if grep -q "RUN_APP_IN_PSRAM=y" "{app}"; then
        RUN_IN_PSRAM="y"
    fi
fi

# Validation rules
if [ "$RUN_IN_PSRAM" = "y" ] && [ "$PSRAM_ENABLED" = "n" ]; then
    echo "ERROR: run_in_psram=True requires PSRAM to be enabled" >&2
    echo "       Add psram module to esp_sdkconfig" >&2
    exit 1
fi

# All checks passed
echo "# Validation passed" > {out}
echo "PSRAM_ENABLED=$PSRAM_ENABLED" >> {out}
echo "RUN_IN_PSRAM=$RUN_IN_PSRAM" >> {out}
"""
    
    inputs = [ctx.file.sdkconfig, ctx.file.app]
    
    # Get psram file path (may be None)
    psram_path = ctx.file.psram.path if ctx.file.psram else "/dev/null"
    
    ctx.actions.run_shell(
        inputs = inputs + ([ctx.file.psram] if ctx.file.psram else []),
        outputs = [out],
        command = check_script.format(
            psram = psram_path,
            app = ctx.file.app.path,
            out = out.path,
        ),
    )
    
    return [DefaultInfo(files = depset([out]))]

esp_validate = rule(
    implementation = _esp_validate_impl,
    attrs = {
        "sdkconfig": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "esp_sdkconfig output",
        ),
        "app": attr.label(
            mandatory = True,
            allow_single_file = True,
            doc = "esp_app output",
        ),
        "psram": attr.label(
            allow_single_file = True,
            doc = "esp_psram output (optional)",
        ),
    },
    doc = """验证 sdkconfig 配置一致性
    
    检查规则：
    - run_in_psram=True 时必须启用 PSRAM
    """,
)
