#!/bin/bash
set -euo pipefail

/usr/bin/find /home/meen/iCAT/buildoutput \
    -maxdepth 1 -type f -name '*.ko' \
    -exec /usr/bin/sha256sum {} + |
/usr/bin/sort -k1,1 |
/usr/bin/awk '
{
    print
    count[$1]++
    files[$1] = files[$1] "\n  " $2
    total++
}
END {
    if (total < 2) {
        print "[ERROR] 비교할 .ko 파일이 2개 미만입니다."
        exit 2
    }

    for (hash in count) {
        if (count[hash] > 1) {
            print "[DUPLICATE] SHA256=" hash files[hash]
            duplicate = 1
        }
    }

    if (duplicate)
        exit 1

    print "[OK] 모든 .ko 파일의 이진 내용이 서로 다릅니다."
}'