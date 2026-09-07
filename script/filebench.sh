#!/bin/bash
set -Eeuo pipefail

# ============================================================================
# filebench.sh
#
# E1 filebench_run.sh의 Final GC/iCAT 1:1 대응판.
#
# Usage:
#   /home/meen/iCAT/script/filebench.sh <module-tag> <workload>
#
# Examples:
#   ./filebench.sh greedy varmail
#   ./filebench.sh cat-fig7 fileserver
#
# Optional:
#   FILEBENCH_RUNTIME=60
#   FILEBENCH_STARTUP_TIMEOUT=120
#   FILEBENCH_EXIT_GRACE=15
#   FILEBENCH_WORKLOAD_DIR=/home/meen/iCAT/workloads/filebench
#   FILEBENCH_BIN=/usr/local/bin/filebench
#   DC_LOOP=run|both|off
#   DC_INTERVAL=4
#
# E1 semantics retained:
#   - fileset population/preallocation = prepare
#   - workload's set $dir is rewritten to /home/meen/mnt/filebench
#   - workload's run N is rewritten to FILEBENCH_RUNTIME
#   - per-process ASLR disable with setarch -R
#   - startup watchdog
#
# Final GC adaptation:
#   - no SARO reset/dump
#   - current run is isolated using /dev/kmsg start/end markers
# ============================================================================

readonly MODULE_TAG="${1:-}"
readonly WORKLOAD_KEY="${2:-}"

readonly SCRIPT_DIR="/home/meen/iCAT/script"
readonly RESULT_ROOT="/home/meen/iCAT/result/filebench"
readonly START_SCRIPT="${SCRIPT_DIR}/start_virt.sh"
readonly END_SCRIPT="${SCRIPT_DIR}/end_virt.sh"
readonly DEVICE="/dev/nvme1n1"
readonly MOUNT_POINT="/home/meen/mnt"
readonly TEST_DIR="${MOUNT_POINT}/filebench"

readonly FILEBENCH_RUNTIME="${FILEBENCH_RUNTIME:-60}"
readonly FILEBENCH_STARTUP_TIMEOUT="${FILEBENCH_STARTUP_TIMEOUT:-120}"
readonly FILEBENCH_EXIT_GRACE="${FILEBENCH_EXIT_GRACE:-15}"
readonly DC_LOOP="${DC_LOOP:-run}"
readonly DC_INTERVAL="${DC_INTERVAL:-4}"
readonly MACHINE_ARCH="$(uname -m)"

readonly SUDO_BIN="/usr/bin/sudo"
readonly DATE_BIN="/usr/bin/date"
readonly DMESG_BIN="/usr/bin/dmesg"
readonly AWK_BIN="/usr/bin/awk"
readonly TEE_BIN="/usr/bin/tee"
readonly NVME_BIN="/usr/sbin/nvme"

WORKLOAD_NAME=""
WORKLOAD_DIR=""
WORKLOAD_FILE=""
FILEBENCH_EXEC=""
EFFECTIVE_WL=""
LOG_DIR=""
APP_LOG=""
DMESG_RESULT=""
SUMMARY_FILE=""

readonly RUN_ID="$("${DATE_BIN}" '+%Y%m%d-%H%M%S')-$$"
readonly RUN_SEEN_FLAG="/tmp/icat_filebench_seen_$$.flag"
readonly DMESG_START_MARKER="iCAT_FILEBENCH_START module=${MODULE_TAG} workload=${WORKLOAD_KEY} run=${RUN_ID}"
readonly DMESG_END_MARKER="iCAT_FILEBENCH_END module=${MODULE_TAG} workload=${WORKLOAD_KEY} run=${RUN_ID}"

DC_FLAG="/tmp/icat_filebench_dc_$$.flag"
DC_RUN_FLAG="/tmp/icat_filebench_run_$$.flag"
DC_PID=""
virt_started=0
run_marked=0

die() { printf 'filebench.sh: %s\n' "$*" >&2; exit 2; }

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

request_stop_drop_caches() {
    rm -f "${DC_FLAG}" "${DC_RUN_FLAG}" "${RUN_SEEN_FLAG}" 2>/dev/null || true
}

stop_drop_caches() {
    request_stop_drop_caches
    if [[ -n "${DC_PID}" ]]; then
        wait "${DC_PID}" 2>/dev/null || true
        DC_PID=""
    fi
}

start_drop_caches_now() {
    [[ "${DC_LOOP}" != "off" ]] || return 0
    [[ -z "${DC_PID}" ]] || return 0

    touch "${DC_FLAG}"
    "${SUDO_BIN}" sh -c "
        echo 3 > /proc/sys/vm/drop_caches
        while [ -e '${DC_FLAG}' ]; do
            sleep '${DC_INTERVAL}'
            [ -e '${DC_FLAG}' ] || break
            echo 3 > /proc/sys/vm/drop_caches
        done
    " &
    DC_PID=$!
}

arm_drop_caches_for_run() {
    [[ "${DC_LOOP}" == "run" ]] || return 0
    [[ -z "${DC_PID}" ]] || return 0

    touch "${DC_FLAG}"
    rm -f "${DC_RUN_FLAG}" "${RUN_SEEN_FLAG}"
    "${SUDO_BIN}" sh -c "
        while [ -e '${DC_FLAG}' ] && [ ! -e '${DC_RUN_FLAG}' ]; do sleep 1; done
        [ -e '${DC_FLAG}' ] || exit 0
        echo 3 > /proc/sys/vm/drop_caches
        while [ -e '${DC_FLAG}' ]; do
            sleep '${DC_INTERVAL}'
            [ -e '${DC_FLAG}' ] || break
            echo 3 > /proc/sys/vm/drop_caches
        done
    " &
    DC_PID=$!
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
    stop_drop_caches
    [[ -n "${EFFECTIVE_WL}" ]] && rm -f "${EFFECTIVE_WL}"

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

resolve_paths() {
    local candidate
    WORKLOAD_NAME="${WORKLOAD_KEY%.f}"

    if [[ -n "${FILEBENCH_BIN:-}" ]]; then
        if [[ "${FILEBENCH_BIN}" == */* ]]; then
            FILEBENCH_EXEC="${FILEBENCH_BIN}"
        else
            FILEBENCH_EXEC="$(command -v "${FILEBENCH_BIN}" 2>/dev/null || true)"
        fi
    else
        FILEBENCH_EXEC="$(command -v filebench 2>/dev/null || true)"
    fi

    if [[ -n "${FILEBENCH_WORKLOAD_DIR:-}" ]]; then
        WORKLOAD_DIR="${FILEBENCH_WORKLOAD_DIR}"
    else
        for candidate in \
            "/home/meen/iCAT/workloads/filebench" \
            "/usr/local/share/filebench/workloads" \
            "/usr/share/filebench/workloads"; do
            if [[ -f "${candidate}/${WORKLOAD_NAME}.f" ]]; then
                WORKLOAD_DIR="${candidate}"
                break
            fi
        done
    fi

    WORKLOAD_FILE="${WORKLOAD_DIR}/${WORKLOAD_NAME}.f"
    LOG_DIR="${RESULT_ROOT}/${WORKLOAD_NAME}"
    APP_LOG="${LOG_DIR}/${MODULE_TAG}.txt"
    DMESG_RESULT="${LOG_DIR}/dmesg-${MODULE_TAG}.log"
    SUMMARY_FILE="${LOG_DIR}/summary.txt"
}

prepare_effective_workload() {
    local awk_rc
    EFFECTIVE_WL="$(mktemp "/tmp/icat_filebench_${WORKLOAD_NAME}_XXXXXX.f")"

    set +e
    awk -v testdir="${TEST_DIR}" -v runtime="${FILEBENCH_RUNTIME}" '
        BEGIN{dir_seen=0;run_seen=0}
        /^[[:space:]]*set[[:space:]]+\$dir[[:space:]]*=/ {
            print "set $dir=" testdir; dir_seen++; next
        }
        /^[[:space:]]*run([[:space:]]|$)/ {
            print "run " runtime; run_seen++; next
        }
        {print}
        END{if(dir_seen==0||run_seen==0)exit 42}
    ' "${WORKLOAD_FILE}" > "${EFFECTIVE_WL}"
    awk_rc=$?
    set -e

    [[ "${awk_rc}" -eq 0 ]] || die "profile lacks set \$dir= or run: ${WORKLOAD_FILE}"
}

validate_inputs() {
    [[ -n "${MODULE_TAG}" && -n "${WORKLOAD_KEY}" ]] || \
        die "usage: filebench.sh <module-tag> <workload>"
    [[ "${MODULE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid module tag"
    [[ "${WORKLOAD_KEY}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid workload name"
    case "${DC_LOOP}" in run|both|off) ;; *) die "DC_LOOP must be run|both|off";; esac

    resolve_paths

    [[ -x "${START_SCRIPT}" ]] || die "not executable: ${START_SCRIPT}"
    [[ -x "${END_SCRIPT}" ]] || die "not executable: ${END_SCRIPT}"
    [[ -n "${FILEBENCH_EXEC}" && -x "${FILEBENCH_EXEC}" ]] || die "filebench not found"
    [[ -f "${WORKLOAD_FILE}" ]] || die "workload not found: ${WORKLOAD_FILE}"

    command -v timeout >/dev/null || die "timeout not found"
    command -v setarch >/dev/null || die "setarch not found"
    command -v stdbuf >/dev/null || die "stdbuf not found"
}

run_filebench() {
    local statuses fb_rc parser_rc total_timeout
    total_timeout=$((FILEBENCH_STARTUP_TIMEOUT + FILEBENCH_RUNTIME + FILEBENCH_EXIT_GRACE))

    rm -f "${DC_RUN_FLAG}" "${RUN_SEEN_FLAG}"

    if [[ "${DC_LOOP}" == "run" ]]; then
        arm_drop_caches_for_run
    elif [[ "${DC_LOOP}" == "both" ]]; then
        start_drop_caches_now
    fi

    set +e
    "${SUDO_BIN}" timeout --signal=TERM --kill-after=10s "${total_timeout}s" \
        setarch "${MACHINE_ARCH}" -R \
        stdbuf -oL -eL "${FILEBENCH_EXEC}" -f "${EFFECTIVE_WL}" 2>&1 | \
        while IFS= read -r line; do
            printf '%s\n' "${line}"
            if [[ "${line}" =~ Running(\.\.\.|[[:space:]]+for[[:space:]]) ]]; then
                if [[ ! -e "${RUN_SEEN_FLAG}" ]]; then
                    touch "${RUN_SEEN_FLAG}"
                    write_dmesg_marker "iCAT_FILEBENCH_MEASURE_START run=${RUN_ID}"
                    [[ "${DC_LOOP}" == "run" ]] && touch "${DC_RUN_FLAG}"
                fi
            fi
        done
    statuses=("${PIPESTATUS[@]}")
    set -e

    fb_rc="${statuses[0]:-1}"
    parser_rc="${statuses[1]:-1}"
    [[ "${parser_rc}" -eq 0 ]] || die "output parser failed: ${parser_rc}"
    [[ "${fb_rc}" -eq 0 ]] || die "filebench failed/timeout: ${fb_rc}"
    [[ -e "${RUN_SEEN_FLAG}" ]] || die "Filebench never reached Running...; measurement start was not found"

    write_dmesg_marker "iCAT_FILEBENCH_MEASURE_END run=${RUN_ID}"
}

main() {
    validate_inputs
    prepare_effective_workload
    "${SUDO_BIN}" -v
    ensure_meen_dir "${LOG_DIR}"
    ensure_meen_file "${APP_LOG}"
    ensure_meen_file "${DMESG_RESULT}"
    ensure_meen_file "${SUMMARY_FILE}"
    : > "${APP_LOG}"
    : > "${DMESG_RESULT}"

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
    mkdir -p "${TEST_DIR}"

    printf '[WORKLOAD] source=%s runtime=%ss\n' "${WORKLOAD_FILE}" "${FILEBENCH_RUNTIME}"
    run_filebench
    request_stop_drop_caches

    printf '[DURABLE] sync + NVMe flush\n'
    flush_device "run-durable-end"
    stop_drop_caches

    printf '[RESULT] app=%s\n' "${APP_LOG}"
    printf '[RESULT] dmesg=%s\n' "${DMESG_RESULT}"
    printf '[RESULT] summary=%s\n' "${SUMMARY_FILE}"
}

main "$@"
