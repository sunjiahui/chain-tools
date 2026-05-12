#!/usr/bin/env python3
"""
查找 Arbitrum/Geth ancient freezer .cdat 文件对应的区块范围。

索引格式 (.cidx): 每条记录 6 字节 (大端序)
  - 2 字节: 文件序号 filenum (uint16 BE)
  - 4 字节: 数据在 cdat 文件中的偏移量 (uint32 BE)

用法:
    python3 ancient_lookup.py <cidx文件路径> <目标文件序号>

示例:
    python3 ancient_lookup.py /data/ancient/receipts.cidx 200
    python3 ancient_lookup.py /data/ancient/bodies.cidx 241
"""

import struct
import sys
import os
import mmap

RECORD_SIZE = 6


def find_block_range(idx_path: str, target_filenum: int):
    file_size = os.path.getsize(idx_path)
    total_blocks = file_size // RECORD_SIZE

    if total_blocks == 0:
        print("索引文件为空")
        return

    with open(idx_path, 'rb') as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

        # 格式: [2B filenum BE] + [4B offset BE]
        def get_filenum(block_idx: int) -> int:
            off = block_idx * RECORD_SIZE
            return struct.unpack('>H', mm[off:off + 2])[0]

        first_fn = get_filenum(0)
        last_fn = get_filenum(total_blocks - 1)

        print(f"总区块数: {total_blocks}, filenum 范围: {first_fn} ~ {last_fn}")

        if target_filenum < first_fn or target_filenum > last_fn:
            print(f"目标 filenum={target_filenum} 不在范围 [{first_fn}, {last_fn}] 内")
            mm.close()
            return

        # 二分查找: 第一个 filenum >= target
        lo, hi = 0, total_blocks
        while lo < hi:
            mid = (lo + hi) // 2
            if get_filenum(mid) < target_filenum:
                lo = mid + 1
            else:
                hi = mid
        first_block = lo

        if first_block >= total_blocks or get_filenum(first_block) != target_filenum:
            print(f"未找到 filenum={target_filenum} 的记录")
            mm.close()
            return

        # 二分查找: 最后一个 filenum <= target
        lo, hi = first_block, total_blocks
        while lo < hi:
            mid = (lo + hi) // 2
            if get_filenum(mid) <= target_filenum:
                lo = mid + 1
            else:
                hi = mid
        last_block = lo - 1

        mm.close()

    table_name = os.path.basename(idx_path).split('.')[0]
    print(f"{table_name}.{target_filenum:04d}.cdat -> 区块 {first_block} ~ {last_block} (共 {last_block - first_block + 1} 个区块)")


def main():
    if len(sys.argv) != 3:
        print(f"用法: {sys.argv[0]} <cidx文件路径> <目标文件序号>")
        print(f"示例: {sys.argv[0]} /data/ancient/receipts.cidx 200")
        sys.exit(1)

    idx_path = sys.argv[1]
    target_filenum = int(sys.argv[2])

    if not os.path.isfile(idx_path):
        print(f"错误: 文件不存在 {idx_path}")
        sys.exit(1)

    find_block_range(idx_path, target_filenum)


if __name__ == '__main__':
    main()
