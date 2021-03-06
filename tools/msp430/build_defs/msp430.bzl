# Default target microcontroller device.
_DEFAULT_MMCU = "msp430g2553"

# Environment variable containing the compilation mode.
_COMPILATION_MODE_ENV_VAR = "COMPILATION_MODE"

def _get_mmcu(ctx):
  """Returns target microcontroller device."""
  return ctx.var.get("mmcu", _DEFAULT_MMCU)

def _get_deps_attr(ctx, attr):
  """Returns the merged set of the given attribute from deps."""
  deps = depset()
  for x in ctx.attr.deps:
    deps += getattr(x.msp430, attr)
  return deps

def _get_include_paths(ctx):
  """Returns the include paths available for this target."""
  includes = depset(["/".join([ctx.label.package, x]) for x in ctx.attr.includes])
  includes += _get_deps_attr(ctx, "includes")
  return includes

def _get_obj_file(ctx, src):
  """Returns the obj file for the given src."""
  extension_index = src.short_path.rindex(".c")
  obj_file = src.short_path[0:extension_index] + ".o"
  return ctx.new_file(obj_file)

def _get_extra_compilation_mode_flags(ctx):
  """Returns additional compilation flags for the current compilation mode."""
  mode = ctx.var[_COMPILATION_MODE_ENV_VAR]
  if mode != "opt":
    return ["-g"]
  return ["-O3"]

def _register_compilation_actions(ctx):
  """Registers compilation actions for this target's srcs.

  Returns the list of obj files to be compiled.
  """
  obj_files = []
  common_compile_args = ["-c"]
  common_compile_args.extend(_get_extra_compilation_mode_flags(ctx))
  common_compile_args.extend(["-I", "."])
  common_compile_args.extend(
      ["-isystem", "external/msp430_toolchain/include"]
  )
  common_compile_args.extend(
      ["-isystem", "external/msp430_toolchain/msp430-elf/include"]
  )
  common_compile_args.extend(
      ["-I", "external/msp430_include/include"]
  )

  for include_path in _get_include_paths(ctx):
    common_compile_args.extend(["-I", include_path])

  common_compile_args.append("-mmcu=%s" % _get_mmcu(ctx))

  for src in ctx.files.srcs:
    obj_file = _get_obj_file(ctx, src)
    obj_files.append(obj_file)

    compile_args = list(common_compile_args)
    compile_args.append(src.path)
    compile_args.extend(["-o", obj_file.path])

    action_inputs = [src]
    action_inputs.extend(ctx.files._compiler_support)
    action_inputs.extend(ctx.files._compiler_include)
    action_inputs.extend(list(_get_deps_attr(ctx, "hdrs")))

    print(ctx)

    ctx.action(
        inputs = action_inputs,
        outputs = [obj_file],
        mnemonic = "CompileMSP430Source",
        executable = ctx.executable._compiler,
        arguments = compile_args,
    )
  return depset(obj_files)

def _register_link_action(ctx):
  """Registers the link action for the binary."""
  obj_files = _get_deps_attr(ctx, "obj")

  link_args = [x.path for x in obj_files]
  link_args.append("-mmcu=%s" % _get_mmcu(ctx))
  link_args.extend(["-o", ctx.outputs.binary.path])
  link_args.extend(["-L", "external/msp430_include/include"])

  action_inputs = list(obj_files)
  action_inputs.extend(ctx.files._compiler_support)
  action_inputs.extend(ctx.files._compiler_include)

  ctx.action(
      inputs = action_inputs,
      outputs = [ctx.outputs.binary],
      mnemonic = "LinkMSP430Binary",
      executable = ctx.executable._compiler,
      arguments = link_args,
  )

def _register_runner_action(ctx):
  """Registers the action that generates the runner script."""
  ctx.file_action(
    output = ctx.outputs.executable,
    content = '\n'.join([
        "#!/bin/bash",
        "mspdebug rf2500 'prog %s'" % ctx.outputs.binary.short_path,
    ]),
    executable = True,
  )

def _validate_msp43_library(ctx):
  """Validates msp430_library attribute values."""
  for include in ctx.attr.includes:
    if include.startswith("/"):
      fail("'includes' cannot contain absolute paths.")

def _msp430_library_impl(ctx):
  """Implementation for the msp430_library rule."""
  _validate_msp43_library(ctx)
  obj_files = _register_compilation_actions(ctx)

  return struct(
    msp430 = struct(
        hdrs = _get_deps_attr(ctx, "hdrs") + depset(ctx.files.hdrs),
        includes = _get_include_paths(ctx),
        obj =  _get_deps_attr(ctx, "obj") + depset(obj_files),
    ),
    files = obj_files,
  )

def _msp430_binary_impl(ctx):
  """Implementation for the msp430_binary rule."""
  _register_link_action(ctx)
  _register_runner_action(ctx)

  return struct(
    runfiles = ctx.runfiles(files = [ctx.outputs.binary]),
  )

# Rule that compiles c files into obj files for the target microcontroller.
#
# Attributes:
#   hdrs: List of headers this target provides.
#   srcs: List of sources to compile.
#   includes: List of paths relative to the package that are added as include
#             paths when compiling.
#   deps: List of dependencies of type msp430_library for this target.
#
# Provides:
#   msp430:
#     hdrs: Set of transitive headers that this targets provides and depends on.
#     obj:  Set of transitive obj files that this target provides and depends
#           on.
msp430_library = rule(
    _msp430_library_impl,
    attrs = {
        "_compiler": attr.label(
          executable = True,
          cfg = "host",
          allow_single_file = True,
          default = Label("@msp430_toolchain//:compiler"),
        ),
        "_compiler_support": attr.label(
          allow_files = True,
          cfg = "host",
          default = Label("@msp430_toolchain//:compiler_support"),
        ),
        "_compiler_include": attr.label(
          allow_files = True,
          cfg = "host",
          default = Label("@msp430_include//:compiler_include"),
        ),
        "hdrs": attr.label_list(
          allow_files = [".h"],
        ),
        "includes": attr.string_list(
          default = [],
        ),
        "srcs": attr.label_list(
          allow_files = [".c"],
        ),
        "deps": attr.label_list(
          providers = [["msp430"]],
        )
    },
)

# Rule that links msp430 obj files into a binary that can be installed in the
# target microcontroller. When using "bazel run", it will install the binary
# onto the device using mspdebug.
#
# Attributes:
#   deps: List of dependencies of type msp430_library for this target. All of
#         the transitive set of dependencies will be linked into the final
#         binary.
msp430_binary = rule(
    _msp430_binary_impl,
    executable = True,
    attrs = {
        "_compiler": attr.label(
          executable = True,
          cfg = "host",
          allow_single_file = True,
          default = Label("@msp430_toolchain//:compiler"),
        ),
        "_compiler_support": attr.label(
          allow_files = True,
          cfg = "host",
          default = Label("@msp430_toolchain//:compiler_support"),
        ),
        "_compiler_include": attr.label(
          allow_files = True,
          cfg = "host",
          default = Label("@msp430_include//:compiler_include"),
        ),
        "deps": attr.label_list(
          providers = [["msp430"]],
        )
    },
    outputs = {
        "binary": "%{name}_bin",
    },
)
