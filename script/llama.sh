#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# llama.sh
#
# E1 llama_run.sh의 Final GC/iCAT 1:1 대응판.
#
# Usage:
#   /home/meen/iCAT/script/llama.sh <module-tag> [MemoryMax]
#
# Optional:
#   LLAMA_BIN=/home/meen/llama.cpp/build/bin/llama-bench
#   MODEL_SRC=/home/meen/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf
#   MEMORY_MAX=1500M
#   MEMORY_SWAP_MAX=0
#   LLAMA_PP=128
#   LLAMA_TG=128
#   LLAMA_REPETITIONS=3
#   LLAMA_THREADS=8
#
# E1 semantics retained:
#   - copy GGUF to NVMeVirt device first (prepare)
#   - flush
#   - drop page cache once
#   - llama-bench under systemd MemoryMax scope
#   - final durable flush
#
# Final GC adaptation:
#   - no SARO quiesce/reset/dump interfaces
#   - dmesg markers distinguish MODEL_PREPARE and LLAMA_RUN
# ============================================================================

readonly MODULE_TAG="${1:-}"
readonly MEMORY_MAX="${2:-${MEMORY_MAX:-${MEMMAX:-1500M}}}"

readonly SCRIPT_DIR="/home/meen/iCAT/script"
readonly RESULT_ROOT="/home/meen/iCAT/result/llama"
readonly START_SCRIPT="${SCRIPT_DIR}/start_virt.sh"
readonly END_SCRIPT="${SCRIPT_DIR}/end_virt.sh"
readonly DEVICE="/dev/nvme1n1"
readonly MOUNT_POINT="/home/meen/mnt"

readonly MEMORY_SWAP_MAX="${MEMORY_SWAP_MAX:-0}"
readonly LLAMA_EXEC="${LLAMA_BIN:-/home/meen/llama.cpp/build/bin/llama-bench}"
readonly MODEL_SOURCE="${MODEL_SRC:-/home/meen/models/Llama-3.2-3B-Instruct-Q4_K_M.gguf}"
readonly MODEL_TARGET="${MOUNT_POINT}/$(basename -- "${MODEL_SOURCE}")"
readonly LLAMA_PP="${LLAMA_PP:-128}"
readonly LLAMA_TG="${LLAMA_TG:-128}"
readonly LLAMA_REPETITIONS="${LLAMA_REPETITIONS:-3}"
readonly LLAMA_THREADS="${LLAMA_THREADS:-8}"
readonly CACHE_SETTLE_SECONDS="${CACHE_SETTLE_SECONDS:-5}"

readonly SUDO_BIN="/usr/bin/sudo"
readonly DATE_BIN="/usr/bin/date"
readonly DMESG_BIN="/usr/bin/dmesg"
readonly AWK_BIN="/usr/bin/awk"
readonly TEE_BIN="/usr/bin/tee"
readonly NVME_BIN="/usr/sbin/nvme"

readonly RUN_ID="$("${DATE_BIN}" '+%Y%m%d-%H%M%S')-$$"
readonly APP_LOG="${RESULT_ROOT}/${MODULE_TAG}.txt"
readonly DMESG_RESULT="${RESULT_ROOT}/dmesg-${MODULE_TAG}.log"
readonly BENCH_OUTPUT="${RESULT_ROOT}/bench-${MODULE_TAG}.txt"
readonly SUMMARY_FILE="${RESULT_ROOT}/summary.txt"
readonly DMESG_START_MARKER="iCAT_LLAMA_START module=${MODULE_TAG} run=${RUN_ID}"
readonly DMESG_END_MARKER="iCAT_LLAMA_END module=${MODULE_TAG} run=${RUN_ID}"

virt_started=0
run_marked=0

die() { printf 'llama.sh: %s\n' "$*" >&2; exit 2; }

write_dmesg_marker() {
    printf '%s\n' "$1" | "${SUDO_BIN}" "${TEE_BIN}" /dev/kmsg >/dev/null
}

save_run_dmesg() {
    "${SUDO_BIN}" "${DMESG_BIN}" --color=never | \
        "${AWK_BIN}" -v start_marker="${DMESG_START_MARKER}" -v end_marker="${DMESG_END_MARKER}" '
            index($0,start_marker){capturing=1;found_start=1;next}
            index($0,end_marker){capturing=0;found_end=1;next}
            capturing{print}
            END{if(!found_start||!found_end)exit 1}
        ' > "${DMESG_RESULT}"
}



append_waf_summary() {
    local last_line=""
    local waf_x1000=""
    local waf=""
    local host_pages=""
    local gc_copied=""
    local gc_cnt=""
    local source="not-found"

    [[ -f "${DMESG_RESULT}" ]] || return 0

    # iCAT/Final-GC의 대표 형식:
    #   [FLUSH-RESULT] ... waf_x1000=1234 host_pages=... gc_copied=...
    #
    # 다른 계측 버전의 WAF=1.234 형식도 함께 허용한다.
    last_line="$(
        grep -Ei \
            '\[FLUSH-RESULT\]|waf_x1000=|(^|[^[:alnum:]_])WAF=' \
            "${DMESG_RESULT}" 2>/dev/null | tail -n 1 || true
    )"

    if [[ -n "${last_line}" ]]; then
        source="dmesg"

        if [[ "${last_line}" =~ waf_x1000=([0-9]+) ]]; then
            waf_x1000="${BASH_REMATCH[1]}"
            waf="$(
                "${AWK_BIN}" -v n="${waf_x1000}" \
                    'BEGIN { printf "%.3f", n / 1000.0 }'
            )"
        elif [[ "${last_line}" =~ WAF=([0-9]+([.][0-9]+)?) ]]; then
            waf="${BASH_REMATCH[1]}"
        fi

        if [[ "${last_line}" =~ host_pages=([0-9]+) ]]; then
            host_pages="${BASH_REMATCH[1]}"
        elif [[ "${last_line}" =~ host_write_pages=([0-9]+) ]]; then
            host_pages="${BASH_REMATCH[1]}"
        fi

        if [[ "${last_line}" =~ gc_copied=([0-9]+) ]]; then
            gc_copied="${BASH_REMATCH[1]}"
        elif [[ "${last_line}" =~ gc_valid_copied=([0-9]+) ]]; then
            gc_copied="${BASH_REMATCH[1]}"
        fi

        if [[ "${last_line}" =~ gc_cnt=([0-9]+) ]]; then
            gc_cnt="${BASH_REMATCH[1]}"
        fi
    fi

    # 보고된 WAF 필드가 없는 계측 버전이면
    # WAF = (host write pages + GC copied pages) / host write pages 로 계산.
    if [[ -z "${waf}" &&
          "${host_pages}" =~ ^[0-9]+$ &&
          "${gc_copied}" =~ ^[0-9]+$ &&
          "${host_pages}" -gt 0 ]]; then
        waf="$(
            "${AWK_BIN}" \
                -v h="${host_pages}" \
                -v g="${gc_copied}" \
                'BEGIN { printf "%.3f", (h + g) / h }'
        )"
        source="calculated-from-host-and-gc-pages"
    fi

    {
        printf '\n===== GC / WAF RESULT =====\n'
        printf 'date        : %s\n' "$("${DATE_BIN}" '+%F %T %z')"
        printf 'module      : %s\n' "${MODULE_TAG}"

        if [[ -n "${WORKLOAD_NAME:-}" ]]; then
            printf 'workload    : %s\n' "${WORKLOAD_NAME}"
        elif [[ -n "${WL_NAME:-}" ]]; then
            printf 'workload    : %s\n' "${WL_NAME}"
        else
            printf 'workload    : llama\n'
        fi

        printf 'source      : %s\n' "${source}"
        printf 'WAF         : %s\n' "${waf:-N/A}"
        printf 'waf_x1000   : %s\n' "${waf_x1000:-N/A}"
        printf 'host_pages  : %s\n' "${host_pages:-N/A}"
        printf 'gc_copied   : %s\n' "${gc_copied:-N/A}"
        printf 'gc_cnt      : %s\n' "${gc_cnt:-N/A}"

        printf '%s\n' '--- final WAF source line ---'
        if [[ -n "${last_line}" ]]; then
            printf '%s\n' "${last_line}"
        else
            printf '%s\n' '<no WAF-bearing line found in current-run dmesg>'
        fi

        printf '%s\n' '--- all current-run WAF lines ---'
        if ! grep -Ei \
            '\[FLUSH-RESULT\]|waf_x1000=|(^|[^[:alnum:]_])WAF=' \
            "${DMESG_RESULT}" 2>/dev/null; then
            printf '%s\n' '<none>'
        fi
    } >> "${SUMMARY_FILE}"

    printf '[WAF] module=%s WAF=%s host_pages=%s gc_copied=%s -> %s\n' \
        "${MODULE_TAG}" \
        "${waf:-N/A}" \
        "${host_pages:-N/A}" \
        "${gc_copied:-N/A}" \
        "${SUMMARY_FILE}"
}

ensure_meen_dir() {
    local dir="$1"

    mkdir -p "${dir}"

    # 과거 실행에서 root 소유로 남은 결과가 있어도 이번부터 meen이 직접 쓴다.
    if [[ "$(stat -c '%U:%G' "${dir}" 2>/dev/null || true)" != "meen:meen" ]]; then
        "${SUDO_BIN}" chown -R meen:meen "${dir}"
    fi
}

ensure_meen_file() {
    local file="$1"

    if [[ -e "${file}" ]]; then
        "${SUDO_BIN}" chown meen:meen "${file}" 2>/dev/null || true
    fi
    touch "${file}"
    "${SUDO_BIN}" chown meen:meen "${file}" 2>/dev/null || true
}

flush_device() {
    local phase="${1:-unspecified}"
    local output=""
    local rc=0

    sync

    if output="$("${SUDO_BIN}" "${NVME_BIN}" flush "${DEVICE}" -n 1 2>&1)"; then
        rc=0
    else
        rc=$?
    fi

    {
        printf '
===== NVME FLUSH =====
'
        printf 'date        : %s
' "$("${DATE_BIN}" '+%F %T %z')"
        printf 'module      : %s
' "${MODULE_TAG}"
        printf 'phase       : %s
' "${phase}"
        printf 'device      : %s
' "${DEVICE}"
        printf 'exit_status : %s
' "${rc}"
        if [[ -n "${output}" ]]; then
            printf 'output      : %s
' "${output}"
        else
            printf 'output      : <none>
'
        fi
    } >> "${SUMMARY_FILE}"

    if ((rc != 0)); then
        printf '[FLUSH-FAIL] phase=%s device=%s exit=%s
' \
            "${phase}" "${DEVICE}" "${rc}" >&2
        return "${rc}"
    fi

    printf '[FLUSH] phase=%s device=%s -> %s
' \
        "${phase}" "${DEVICE}" "${SUMMARY_FILE}"
}


verify_mount_source() {
    local mounted_source expected_real mounted_real
    mounted_source="$(findmnt -n -o SOURCE --target "${MOUNT_POINT}" 2>/dev/null || true)"
    [[ -n "${mounted_source}" ]] || die "not mounted: ${MOUNT_POINT}"
    expected_real="$(readlink -f "${DEVICE}")"
    mounted_real="$(readlink -f "${mounted_source}")"
    [[ "${mounted_real}" == "${expected_real}" ]] || \
        die "wrong mount: expected=${expected_real}, actual=${mounted_real}"
}

finish_virt() {
    local original_status="$?"
    local finish_status=0

    trap - EXIT INT TERM
    set +e

    if ((virt_started)); then
        [[ -b "${DEVICE}" ]] && flush_device "cleanup"
        "${END_SCRIPT}" || finish_status=1
    fi

    if ((run_marked)); then
        write_dmesg_marker "${DMESG_END_MARKER}" || finish_status=1
        if save_run_dmesg; then
            "${SUDO_BIN}" chown meen:meen "${DMESG_RESULT}" 2>/dev/null || true
            append_waf_summary
        else
            finish_status=1
        fi
    fi

    ((original_status != 0)) && exit "${original_status}"
    exit "${finish_status}"
}

validate_inputs() {
    [[ -n "${MODULE_TAG}" ]] || die "usage: llama.sh <module-tag> [MemoryMax]"
    [[ "${MODULE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid module tag"
    [[ -f "${MODEL_SOURCE}" ]] || die "model not found: ${MODEL_SOURCE}"
    [[ -x "${LLAMA_EXEC}" ]] || die "llama-bench not found: ${LLAMA_EXEC}"
    [[ -x "${START_SCRIPT}" ]] || die "not executable: ${START_SCRIPT}"
    [[ -x "${END_SCRIPT}" ]] || die "not executable: ${END_SCRIPT}"
    command -v systemd-run >/dev/null || die "systemd-run not found"
}

main() {
    validate_inputs
    "${SUDO_BIN}" -v
    ensure_meen_dir "${RESULT_ROOT}"
    ensure_meen_file "${APP_LOG}"
    ensure_meen_file "${DMESG_RESULT}"
    ensure_meen_file "${BENCH_OUTPUT}"
    ensure_meen_file "${SUMMARY_FILE}"
    : > "${APP_LOG}"
    : > "${DMESG_RESULT}"
    : > "${BENCH_OUTPUT}"

    exec > >(tee "${APP_LOG}") 2>&1

    trap finish_virt EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    write_dmesg_marker "${DMESG_START_MARKER}"
    run_marked=1

    printf '[START] module=%s\n' "${MODULE_TAG}"
    "${START_SCRIPT}" "${MODULE_TAG}"
    virt_started=1
    verify_mount_source
    "${SUDO_BIN}" chown meen:meen "${MOUNT_POINT}"

    write_dmesg_marker "iCAT_LLAMA_PREPARE_START run=${RUN_ID}"
    printf '[PREPARE] copy model: %s -> %s\n' "${MODEL_SOURCE}" "${MODEL_TARGET}"
    flush_device "prepare-before-copy"
    "${SUDO_BIN}" sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    cp -- "${MODEL_SOURCE}" "${MODEL_TARGET}"
    flush_device "prepare-after-copy"
    write_dmesg_marker "iCAT_LLAMA_PREPARE_END run=${RUN_ID}"

    "${SUDO_BIN}" sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep "${CACHE_SETTLE_SECONDS}"

    write_dmesg_marker "iCAT_LLAMA_RUN_START run=${RUN_ID}"
    printf '[RUN] pp=%s tg=%s reps=%s threads=%s MemoryMax=%s\n' \
        "${LLAMA_PP}" "${LLAMA_TG}" "${LLAMA_REPETITIONS}" "${LLAMA_THREADS}" "${MEMORY_MAX}"

    set +e
    "${SUDO_BIN}" systemd-run --scope --quiet \
        --property="MemoryMax=${MEMORY_MAX}" \
        --property="MemorySwapMax=${MEMORY_SWAP_MAX}" \
        "${LLAMA_EXEC}" \
        -m "${MODEL_TARGET}" \
        -p "${LLAMA_PP}" \
        -n "${LLAMA_TG}" \
        -r "${LLAMA_REPETITIONS}" \
        -t "${LLAMA_THREADS}" 2>&1 | tee "${BENCH_OUTPUT}"
    statuses=("${PIPESTATUS[@]}")
    set -e

    bench_rc="${statuses[0]:-1}"
    tee_rc="${statuses[1]:-1}"

    flush_device "run-end"
    write_dmesg_marker "iCAT_LLAMA_RUN_END run=${RUN_ID}"

    [[ "${tee_rc}" -eq 0 ]] || die "tee failed: ${tee_rc}"
    [[ "${bench_rc}" -eq 0 ]] || die "llama-bench failed: ${bench_rc}"

    printf '[RESULT] app=%s\n' "${APP_LOG}"
    printf '[RESULT] bench=%s\n' "${BENCH_OUTPUT}"
    printf '[RESULT] dmesg=%s\n' "${DMESG_RESULT}"
    printf '[RESULT] summary=%s\n' "${SUMMARY_FILE}"
}

main "$@"
