#!/bin/bash
# Machine Performance Benchmark Script
# Tests: CPU single/multi-core, Memory bandwidth, NVMe IO (all disks)

set -euo pipefail

# === Thresholds ===
MIN_RAND_READ_IOPS=100000
MIN_RAND_WRITE_IOPS=80000
MIN_MIXED_READ_IOPS=60000
MIN_CPU_SINGLE=4000
MIN_CPU_MULTI_FACTOR=0.8
MIN_MEM_BW=8000

# === Config ===
FIO_SIZE="1G"
FIO_RUNTIME=10
FIO_IODEPTH=64
CPU_TEST_TIME=10

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Install dependencies ===
install_deps() {
    local missing=()
    command -v fio &>/dev/null || missing+=(fio)
    command -v sysbench &>/dev/null || missing+=(sysbench)
    command -v smartctl &>/dev/null || missing+=(smartmontools)
    command -v lspci &>/dev/null || missing+=(pciutils)
    if [ ${#missing[@]} -gt 0 ]; then
        echo "Installing missing tools: ${missing[*]}"
        apt install -y "${missing[@]}"
    fi
}

print_result() {
    local label="$1" value="$2" threshold="$3" unit="$4"
    if (( $(echo "$value >= $threshold" | bc -l) )); then
        printf "  %-25s %'12.0f %-10s ${GREEN}[PASS]${NC} (threshold: %'d)\n" "$label" "$value" "$unit" "$threshold"
    else
        local ratio
        ratio=$(echo "$threshold/$value" | bc -l)
        printf "  %-25s %'12.0f %-10s ${RED}[FAIL]${NC} (threshold: %'d, %.1fx lower)\n" "$label" "$value" "$unit" "$threshold" "$ratio"
    fi
}

get_iops() {
    echo "$1" | grep -oP 'IOPS=\K[0-9.]+k?' | head -1 | sed 's/k/*1000/' | bc | cut -d. -f1
}

# ==================== CPU ====================
bench_cpu() {
    local num_cores
    num_cores=$(nproc)
    local cpu_model
    cpu_model=$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)

    echo ""
    printf "${CYAN}=== CPU: ${cpu_model}, ${num_cores} cores ===${NC}\n"
    echo ""

    echo "  Running single-core test (${CPU_TEST_TIME}s)..."
    local out single_eps
    out=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time=$CPU_TEST_TIME run 2>&1)
    single_eps=$(echo "$out" | grep "events per second" | awk '{print $NF}')
    print_result "Single-core" "$single_eps" "$MIN_CPU_SINGLE" "events/s"

    echo "  Running multi-core test (${CPU_TEST_TIME}s, ${num_cores} threads)..."
    out=$(sysbench cpu --cpu-max-prime=20000 --threads=$num_cores --time=$CPU_TEST_TIME run 2>&1)
    local multi_eps min_multi
    multi_eps=$(echo "$out" | grep "events per second" | awk '{print $NF}')
    min_multi=$(echo "$MIN_CPU_SINGLE * $num_cores * $MIN_CPU_MULTI_FACTOR" | bc | cut -d. -f1)
    print_result "Multi-core (${num_cores}T)" "$multi_eps" "$min_multi" "events/s"

    local avg_freq
    avg_freq=$(awk '{sum+=$1; n++} END {printf "%.0f", sum/n}' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || echo "0")
    [ "$avg_freq" -gt 0 ] && printf "  %-25s %'12.0f %-10s\n" "Avg CPU Frequency" "$((avg_freq/1000))" "MHz"
}

# ==================== Memory ====================
bench_memory() {
    echo ""
    printf "${CYAN}=== Memory: $(free -h | awk '/Mem:/ {print $2}') total ===${NC}\n"
    echo ""

    echo "  Running memory write bandwidth..."
    local out write_bw
    out=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=write --threads=1 run 2>&1)
    write_bw=$(echo "$out" | grep -oP '[0-9.]+\s+MiB/sec' | grep -oP '[0-9.]+')
    print_result "Memory Write BW" "$write_bw" "$MIN_MEM_BW" "MiB/s"

    echo "  Running memory read bandwidth..."
    out=$(sysbench memory --memory-block-size=1M --memory-total-size=10G --memory-oper=read --threads=1 run 2>&1)
    local read_bw
    read_bw=$(echo "$out" | grep -oP '[0-9.]+\s+MiB/sec' | grep -oP '[0-9.]+')
    print_result "Memory Read BW" "$read_bw" "$MIN_MEM_BW" "MiB/s"
}

# ==================== NVMe ====================
bench_disk() {
    local dev="$1" testfile="$2"
    local model size
    model=$(cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null | xargs)
    size=$(lsblk -d -o SIZE "$dev" --noheadings | xargs)

    echo ""
    printf "${CYAN}=== NVMe: $dev | $model | $size ===${NC}\n"
    echo "  Test file: $testfile"
    echo ""

    echo "  Running random read..."
    local out read_iops
    out=$(fio --name=randread --ioengine=libaio --direct=1 --bs=4k --iodepth=$FIO_IODEPTH \
        --size=$FIO_SIZE --numjobs=1 --rw=randread --runtime=$FIO_RUNTIME --time_based \
        --filename="$testfile" 2>&1)
    read_iops=$(get_iops "$out")
    print_result "Random Read" "$read_iops" "$MIN_RAND_READ_IOPS" "IOPS"

    echo "  Running random write..."
    out=$(fio --name=randwrite --ioengine=libaio --direct=1 --bs=4k --iodepth=$FIO_IODEPTH \
        --size=$FIO_SIZE --numjobs=1 --rw=randwrite --runtime=$FIO_RUNTIME --time_based \
        --filename="$testfile" 2>&1)
    local write_iops
    write_iops=$(get_iops "$out")
    print_result "Random Write" "$write_iops" "$MIN_RAND_WRITE_IOPS" "IOPS"

    echo "  Running mixed read/write (70/30)..."
    out=$(fio --name=randrw --ioengine=libaio --direct=1 --bs=4k --iodepth=$FIO_IODEPTH \
        --size=$FIO_SIZE --numjobs=1 --rw=randrw --rwmixread=70 --runtime=$FIO_RUNTIME --time_based \
        --filename="$testfile" 2>&1)
    local mixed_iops
    mixed_iops=$(echo "$out" | grep -A5 "read:" | grep -oP 'IOPS=\K[0-9.]+k?' | head -1 | sed 's/k/*1000/' | bc | cut -d. -f1)
    print_result "Mixed Read (70/30)" "$mixed_iops" "$MIN_MIXED_READ_IOPS" "IOPS"

    rm -f "$testfile"
}

bench_all_nvme() {
    local devs
    # Detect NVMe (nvme*) and non-rotational disks (SSD: sd*, vd*, etc.)
    devs=$(lsblk -d -o NAME,TYPE,ROTA --noheadings | awk '$2=="disk" && $3=="0" {print "/dev/"$1}')

    if [ -z "$devs" ]; then
        echo "  No SSD/NVMe devices found."
        return
    fi

    for dev in $devs; do
        local mountpoint testfile
        mountpoint=$(lsblk -o MOUNTPOINT "$dev" --noheadings | grep -v "^$" | head -1)

        if [ -n "$mountpoint" ]; then
            testfile="${mountpoint}/fiotest_bench"
        else
            echo ""
            printf "  ${YELLOW}$dev is not mounted.${NC}\n"
            read -rp "  Enter mount point to test (or 'skip'): " user_input
            if [ "$user_input" = "skip" ]; then
                echo "  Skipping $dev"
                continue
            fi
            if [ ! -d "$user_input" ]; then
                echo "  Directory does not exist. Skipping."
                continue
            fi
            testfile="${user_input}/fiotest_bench"
        fi

        bench_disk "$dev" "$testfile"
    done
}

# ==================== Main ====================
main() {
    install_deps

    echo "============================================================"
    echo "  Machine Performance Benchmark"
    echo "  Host: $(hostname)"
    echo "  Date: $(date)"
    echo "============================================================"

    bench_cpu
    bench_memory
    bench_all_nvme

    echo ""
    echo "============================================================"
    echo "  Benchmark complete."
    echo "============================================================"
}

main
