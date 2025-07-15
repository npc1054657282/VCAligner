# 开发过程问题解决日志记录

## 跨平台场景的可配置库路径的build.zig

[参见](https://ziggit.dev/t/how-can-zls-get-a-configurable-system-include-path-for-c-library/10879)

- 方案1：使用embedFile读取一个自动生成的配置文件。使用build-on-save解决zls的解析
  
  相关文档：<https://zigtools.org/zls/guides/build-on-save/>

- 方案2：使用参数，并利用`zls.build.json`解决zls读取参数
  
  相关文档：<https://zigtools.org/zls/configure/per-build/>

最终使用方案1，因为方案2对于zls以外，依赖于额外脚本来构建，而方案1可以直接使用`zig build`。

由于vscode快捷执行单元测试时，走的是直接`zig test`而不是`zig build test`，无法享受`zig build`配置的库路径。

因此，需要额外通过`.vscode/settings.json`配置`zig.testArgs`，这一点同样自动生成。

## zig的多态

最优方案[参见](https://codeberg.org/ziglings/exercises/src/branch/main/exercises/092_interfaces.zig)

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

[参见](https://github.com/ziglang/zig/blob/0.14.0/doc/langref/test_inline_switch_union_tag.zig)

多数Union的动态输入问题，可以用这个静态分派来解决。现有的Union元编程大多要求编译时内容，用这个方案可以把运行时tag转换成编译时tag。

## zig的5种多态

- Tagged Union，最静态，计算开销最可能优化，但是需求一个统一入口，扩展性不太好。
- 胖指针虚表，在可扩展的方案里，结合LLVM的后端优化，在调用方法时的计算开销是最优的，缺点就是指针大小大，因此指针传递拷贝过程的内存开销大一点，但综合来讲是可扩展方案的优选了。
- 内嵌共享虚表，相比于胖指针虚表，LLVM的可优化性能差一些，而不考虑优化下本来也总是要多一次访存，因此调用时的计算开销会大一点点，优点就是指针大小正常，且使用时，虚表可能拥有更大的可配置灵活性。灵活性往往和开销是反义词，所以最灵活的实现就可能有最大的开销，这是权衡。
- 古法实例内嵌虚表，每个实例里都保存了一份虚表，内存占用开销大，而调用时的开销理论上小，但实际上由于LLVM的可优化性不如胖指针实现，因此总体来讲不如胖指针。但是对于一些特别的场景，例如单例对象不存在多个实例保存虚表的开销，又或者闭包，只有一个方法所以虚表在多个实例的开销可能还不如胖指针开销，诸如这些情形，内嵌虚表还是可以用的。这种做法不涉及指针强转，而是使用`@fieldParentPtr`实现，看起来比较干净。
- 编译期鸭子类型式的基于`anytype`的泛型多态，它有些类似于C++的模板，但是因为是鸭子类型式所以更灵活，是完全编译期0开销的，但有可能造成二进制膨胀。实际上虚表的实现方案，在生成胖指针对象时，就利用了这种泛型多态实现。灵活性往往和开销是反义词，开销最低的实现也因此存在某些灵活性问题，例如此类泛型多态的函数，无法接收同一个泛型的内部实际为不同对象的数组实现，它会假定参数的数组指针都是同一个对象。灵活性和开销要进行权衡。

[参见](https://zig.news/yglcode/code-study-interface-idiomspatterns-in-zig-standard-libraries-4lkj)
