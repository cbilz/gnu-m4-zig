# GNU M4 packaged for Zig

Work in progress.

## Goal

This project aims to provide a Zig package for GNU M4 that runs on Linux, macOS
and Windows without system dependencies. The longer-term goal is to extract a
reusable Zig library for compiling projects that rely on Autotools and Gnulib.

## Status

Compiles and appears to run correctly on my Linux system when built in
`ReleaseFast` or `ReleaseSmall` mode. However, with safety checks enabled, the
executable hits an illegal instruction immediately on startup, presumably due to
undefined behavior.

## Next steps

1. Fix the illegal instruction issue.
2. Port the test suite and integrate it as a build step.
3. Implement those configuration checks that do not depend on preprocessing,
   compilation or execution of probing code. Exclude any unused or redundant
   checks.
4. Implement a `LazyValue` system to allow other build steps to pass
   configuration values to `ConfigHeader`.
5. Implement remaining configuration checks, again excluding unused or redundant
   ones.
6. Extract a reusable configuration library for projects using Autotools or
   Gnulib.

## Requirements

- Uses Zig 0.14.0-dev.3046+08d661fcf.

## Limitations

- Native language support is disabled.
