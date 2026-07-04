// 一次解析所得包含的最大的被解析关系对的数量。
// 它就是解析线程的flush_threshold，解析线程达到这一阈值就会立即发送，因此是最大的被解析关系对。
pub const parsed_chunk_max = 512;
// keys buf的容量。如果溢出会导致数据丢失。
pub const keys_buf_capacity = 4096;
// write batch的写入rocksdb的阈值，超过它就需要立即写入。为了防止溢出，需要预留一次解析所得最大关系对的数量。
pub const write_batch_threshold = 4096 - 512;
