#!/bin/bash
set -euo pipefail

# PuraPi 的源码可读性门禁：超过阈值的文件应按职责拆分，而不是继续堆叠。
root="$(cd "$(dirname "$0")/.." && pwd)"
max_lines="${MAX_LINES:-1000}"
status=0

while IFS= read -r -d '' file; do
    lines="$(wc -l < "$file" | tr -d ' ')"
    if [ "$lines" -gt "$max_lines" ]; then
        printf '源文件超过 %s 行：%s（%s 行）\n' "$max_lines" "${file#"$root"/}" "$lines" >&2
        status=1
    fi
done < <(find "$root/Sources" "$root/Tests" -type f -name '*.swift' -print0)

if [ "$status" -ne 0 ]; then
    printf '请按职责拆分文件后再继续。可用 MAX_LINES=800 提前检查预警线。\n' >&2
    exit "$status"
fi

printf '源码大小检查通过：Sources/ 和 Tests/ 中没有超过 %s 行的 Swift 文件。\n' "$max_lines"
