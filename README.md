# GNU M4 packaged for Zig

Work in progress.

## Goal

Provide GNU M4 as a Zig package that works on Linux, macOS and Windows without
requiring system dependencies.

## Current status

All non-test headers are configured with values chosen for a particular Linux system.

## Next steps

1. Compile the `m4` executable.
2. Port the test suite and expose it as a build step.
3. Implement checks for those configuration values that do not depend on
   preprocessing, compiling or running checking code. Exclude unused or
   redundant checks.
4. Implement a `LazyValue` system to allow configuration values to be passed to
   `ConfigHeader` by other build steps.
5. Implement checks for the remaining configuration values, excluding unused or
   redundant ones.
6. Extract a reusable configuration library for other projects based on
   Autotools or Gnulib.

## Requirements

- Uses Zig 0.14.0-dev.3046+08d661fcf.

## Limitations

- Native language support is disabled.
