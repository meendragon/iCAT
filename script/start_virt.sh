#!/bin/bash

# $1 = buildoutput의 모듈 태그 (예: p1-greedy, p2-cb-profile2-cat7)
MODULE_TAG=${1:?"Usage: $0 <module-tag>"}
MODULE_PATH=/home/meen/iCAT/buildoutput/nvmev-${MODULE_TAG}.ko

DEV=/dev/nvme1n1
MNT_DIR=/home/meen/mnt

# 1. 기존 모듈 및 마운트 정리
if lsmod | grep -q "^nvmev"; then
    sudo umount ${MNT_DIR} 2>/dev/null
    sudo rmmod nvmev
    sleep 1
fi

# 2. 마운트 디렉토리 생성 (없을 경우)
mkdir -p ${MNT_DIR}

# 3. NVMeVirt 드라이버 로드
sudo insmod ${MODULE_PATH} memmap_start=4G memmap_size=8192M cpus=1,2
sleep 1

# 4. 포맷 및 마운트
echo y | sudo mkfs.ext4 ${DEV}
sudo mount ${DEV} ${MNT_DIR}
sudo chown -R meen:meen ${MNT_DIR}

echo "Virt Ready: ${MNT_DIR}"
