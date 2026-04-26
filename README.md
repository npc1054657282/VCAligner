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

## A case study on Xz-Utils

We provide a reproducible [XZ Case Study](https://github.com/npc1054657282/VCAligner-XZ-CaseStudy.git) to demonstrate VCAligner's practical workflow. It showcases how to extract phantom artifacts and integrate them with downstream detection rules.