# Data selection macro
# Platform-independent - can be used by ESP, Beken, simulator, etc.

def data_select(name, options, visibility = None):
    """Auto-generate config_setting + select for multi-variant data.
    
    The first option is used as the default when --//bazel:data is not specified.
    
    Args:
        name: Name of the output filegroup
        options: Dict of {variant_name: srcs} where srcs is a list of files.
                 First entry is the default.
        visibility: Optional visibility for generated targets
    
    Example:
        data_select(
            name = "data_files",
            options = {
                "tiga": glob(["data/tiga/**"]),   # default (first)
                "zero": glob(["data/zero/**"]),
            },
        )
    
    Usage:
        bazel build //app:target                  # uses tiga (default)
        bazel build //app:target --//bazel:data=zero
    """
    select_dict = {}
    first_opt = None
    
    for opt, srcs in options.items():
        if first_opt == None:
            first_opt = opt
        
        # Create filegroup for each variant
        native.filegroup(
            name = name + "_" + opt,
            srcs = srcs,
            visibility = visibility,
        )
        
        # Create config_setting for each variant
        native.config_setting(
            name = name + "_is_" + opt,
            flag_values = {"//bazel:data": opt},
        )
        
        # Add to select dict
        select_dict[":" + name + "_is_" + opt] = [":" + name + "_" + opt]
    
    # First option is default
    if first_opt:
        select_dict["//conditions:default"] = [":" + name + "_" + first_opt]
    else:
        select_dict["//conditions:default"] = []
    
    # Create the main filegroup with select
    native.filegroup(
        name = name,
        srcs = select(select_dict),
        visibility = visibility,
    )
