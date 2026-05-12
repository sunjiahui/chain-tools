#!/bin/bash
# stream_extract.sh
# 边解压 lz4.tar 边对已读部分打洞释放磁盘空间
#
# 用法: ./stream_extract.sh <file.lz4.tar> [解压目标目录]
# 示例: ./stream_extract.sh /data/a.lz4.tar /data/output

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "用法: $0 <file.lz4.tar> [解压目标目录]"
    exit 1
fi

FILE="$(realpath "$1")"
OUTDIR="${2:-.}"
PUNCH_INTERVAL=$((10 * 1024 * 1024 * 1024))  # 每 10GB 打洞一次

if [ ! -f "$FILE" ]; then
    echo "错误: 文件不存在 $FILE"
    exit 1
fi

# 检查文件系统是否支持 punch hole（用实际长度测试）
TEST_FILE="${FILE}.punch_test"
fallocate -l 8192 "$TEST_FILE" 2>/dev/null || { echo "错误: fallocate 不可用"; exit 1; }
if ! fallocate --punch-hole --offset 0 --length 4096 "$TEST_FILE" 2>/dev/null; then
    rm -f "$TEST_FILE"
    echo "错误: 文件系统不支持 fallocate punch-hole"
    exit 1
fi
rm -f "$TEST_FILE"

FILE_SIZE=$(stat -c%s "$FILE")
echo "源文件: $FILE ($(numfmt --to=iec $FILE_SIZE))"
echo "解压到: $OUTDIR"
echo "打洞间隔: $(numfmt --to=iec $PUNCH_INTERVAL)"
echo ""

mkdir -p "$OUTDIR"

# 启动解压流水线
lz4 -dc "$FILE" | tar xf - -C "$OUTDIR" &
PIPE_PID=$!

# 等待 lz4 进程启动
sleep 2

# 找到 lz4 进程 PID
LZ4_PID=$(pgrep -f "lz4 -dc $FILE" | head -1 || true)

if [ -z "$LZ4_PID" ]; then
    echo "警告: 无法找到 lz4 进程，等待解压完成后删除源文件"
    wait $PIPE_PID
    rm -f "$FILE"
    echo "完成"
    exit 0
fi

# 找到 lz4 打开源文件的 fd 编号
LZ4_FD=""
for fd in /proc/$LZ4_PID/fd/*; do
    if [ -L "$fd" ] && [ "$(readlink "$fd" 2>/dev/null)" = "$FILE" ]; then
        LZ4_FD=$(basename "$fd")
        break
    fi
done

if [ -z "$LZ4_FD" ]; then
    echo "警告: 无法找到 lz4 的文件描述符，等待解压完成后删除源文件"
    wait $PIPE_PID
    rm -f "$FILE"
    echo "完成"
    exit 0
fi

echo "lz4 PID: $LZ4_PID, FD: $LZ4_FD"
echo "开始监控并打洞..."
echo ""

LAST_PUNCH=0

while kill -0 $PIPE_PID 2>/dev/null; do
    # 获取 lz4 读取位置
    POS=$(awk '/^pos:/ {print $2}' /proc/$LZ4_PID/fdinfo/$LZ4_FD 2>/dev/null || echo "")

    if [ -n "$POS" ] && [ "$POS" -gt 0 ]; then
        # 保留 1GB 缓冲
        SAFE_END=$((POS - 1024*1024*1024))
        if [ "$SAFE_END" -gt "$LAST_PUNCH" ] && [ $((SAFE_END - LAST_PUNCH)) -ge "$PUNCH_INTERVAL" ]; then
            # 对齐到 4K
            PUNCH_LEN=$(( (SAFE_END / 4096) * 4096 ))
            if [ "$PUNCH_LEN" -gt "$LAST_PUNCH" ]; then
                fallocate --punch-hole --offset "$LAST_PUNCH" --length $((PUNCH_LEN - LAST_PUNCH)) "$FILE"
                LAST_PUNCH=$PUNCH_LEN
                FREED=$(numfmt --to=iec $LAST_PUNCH)
                PROGRESS=$((LAST_PUNCH * 100 / FILE_SIZE))
                echo "[$(date '+%H:%M:%S')] 已打洞释放: $FREED ($PROGRESS%)"
            fi
        fi
    fi

    sleep 5
done

wait $PIPE_PID
EXIT_CODE=$?

rm -f "$FILE"

if [ $EXIT_CODE -eq 0 ]; then
    echo ""
    echo "[$(date '+%H:%M:%S')] 解压完成，源文件已删除"
else
    echo ""
    echo "[$(date '+%H:%M:%S')] 解压异常 (code=$EXIT_CODE)，源文件已删除"
    exit $EXIT_CODE
fi
