# VCAligner

## Build Instructions

### Prerequisites

- [Xmake](https://xmake.io/). Tested in xmake v3.0.8 and v2.9.9. If you are using v2.9.9, change the `set_toolchains("zigcc")` to `set_toolchains("zig")` in `xmake.lua`.

- [Zig v0.15.2](https://ziglang.org/download/#release-0.15.2).

### Build

``` bash
xmake f -m release
xmake
```