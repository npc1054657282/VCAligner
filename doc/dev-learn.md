# 开发过程问题解决日志记录

## 跨平台场景的可配置库路径的build.zig

参见<https://ziggit.dev/t/how-can-zls-get-a-configurable-system-include-path-for-c-library/10879>。

- 方案1：使用embedFile读取一个自动生成的配置文件。使用build-on-save解决zls的解析
  
  相关文档：<https://zigtools.org/zls/guides/build-on-save/>

- 方案2：使用参数，并利用`zls.build.json`解决zls读取参数
  
  相关文档：<https://zigtools.org/zls/configure/per-build/>

最终使用方案1，因为方案2对于zls以外，依赖于额外脚本来构建，而方案1可以直接使用`zig build`。

由于vscode快捷执行单元测试时，走的是直接`zig test`而不是`zig build test`，无法享受`zig build`配置的库路径。

因此，需要额外通过`.vscode/settings.json`配置`zig.testArgs`，这一点同样自动生成。

## zig的多态

最优方案参见<https://codeberg.org/ziglings/exercises/src/branch/main/exercises/092_interfaces.zig>。

## zig的Tagged Union相关元操作

### 获取一个Tagged Union类型的对应Enum类型

使用`std.meta.Tag`。

### 获取一个Tagged Union值的对应Enum值

使用`std.meta.activeTag`

### 获取一个Enum值的真实值

使用`@intFromEnum`

### 把一个真实值转换为Enum值

使用`@enumFromInt`。如果不确定真实值是否可能可以转换，使用`std.enums.fromInt`，这个函数返回的是一个可选Enum值。

### 获取一个Enum值的tag字符串

使用`@tagName`。无穷枚举有可能没有tag，因此`std.enums.tagName`可以不报错地处理这种情况，它返回的是可选字符串值。

### 把一个tag字符串转换为Enum值

使用`std.meta.stringToEnum`，它的缺省方法是使用`std.StaticMap`，这种方法可能完全在编译期实现（但如果涉及运行时字符串，会导致静态表出现在运行时占据内存并有运行时开销），而在Enum的量过大时，将完全在运行时实现，以避免编译时间过长。

### 获取Tagged Union类型的指定Enum值的字段类型

如果Enum值是编译时可知的，组合使用`@FieldType`与`@tagName`。

### Union的静态分派模式

<https://github.com/ziglang/zig/blob/0.14.0/doc/langref/test_inline_switch_union_tag.zig>

多数Union的动态输入问题，可以用这个静态分派来解决。现有的Union元编程大多要求静态输入，用这个方案可以把动态tag转换成静态tag。
