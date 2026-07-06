// 旧实现犯了个严重的错误：keys_buf是无存在价值的。
// 旧实现建立于一个认知错误上，就是误以为write batch仅仅保存引用。实际上它深拷贝了key和value，因此外部的缓冲是纯粹多余的拷贝。
// 因此旧实现的相关水位预留设计也没有价值。

// write batch超过此水位时立即写入rocksdb。为了防止溢出，需要预留一次解析所得最大关系对的数量。
pub const write_batch_watermark = 4096;
