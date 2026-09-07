#!/bin/bash
set -Eeuo pipefail

export JAVA_TOOL_OPTIONS="-Xshare:off"

# ============================================================================
# sqlite.sh
#
# E1 e1_sqlite_run.sh의 Final GC/iCAT 1:1 대응판.
# YCSB SQLite/JDBC workload A/B/D 단일 실험.
#
# Usage:
#   /home/meen/iCAT/script/sqlite.sh <module-tag> <a|b|d>
#
# Optional:
#   YCSB_THREADS=1
#   DC_LOOP=run|both|off
#   DC_INTERVAL=4
#   YCSB_DIR=/home/meen/YCSB/ycsb-0.17.0
#   SQLITE_WORKLOAD_DIR=/home/meen/iCAT/workloads/sqlite
#
# 주의:
#   첨부된 E1 runner에는 workloada/workloadb/workloadd 본문이 포함되어 있지
#   않으므로, 그 파일은 기존 E1 파일을 그대로 복사해서 사용해야 한다.
# ============================================================================

readonly MODULE_TAG="${1:-}"
readonly WORKLOAD_KEY="${2:-}"

readonly SCRIPT_DIR="/home/meen/iCAT/script"
readonly WORKLOAD_DIR="${SQLITE_WORKLOAD_DIR:-/home/meen/iCAT/workloads/sqlite}"
readonly RESULT_ROOT="/home/meen/iCAT/result/sqlite"
readonly START_SCRIPT="${SCRIPT_DIR}/start_virt.sh"
readonly END_SCRIPT="${SCRIPT_DIR}/end_virt.sh"
readonly DEVICE="/dev/nvme1n1"
readonly MOUNT_POINT="/home/meen/mnt"
readonly DB_FILE="${MOUNT_POINT}/ycsb.db"

readonly YCSB_THREADS="${YCSB_THREADS:-1}"
readonly DC_LOOP="${DC_LOOP:-run}"
readonly DC_INTERVAL="${DC_INTERVAL:-4}"

readonly SUDO_BIN="/usr/bin/sudo"
readonly DATE_BIN="/usr/bin/date"
readonly DMESG_BIN="/usr/bin/dmesg"
readonly AWK_BIN="/usr/bin/awk"
readonly TEE_BIN="/usr/bin/tee"
readonly NVME_BIN="/usr/sbin/nvme"

readonly RUN_ID="$("${DATE_BIN}" '+%Y%m%d-%H%M%S')-$$"
readonly WL="${WORKLOAD_DIR}/workload${WORKLOAD_KEY}"
readonly WL_NAME="workload${WORKLOAD_KEY}"
readonly LOG_DIR="${RESULT_ROOT}/${WL_NAME}"
readonly APP_LOG="${LOG_DIR}/${MODULE_TAG}.txt"
readonly DMESG_RESULT="${LOG_DIR}/dmesg-${MODULE_TAG}.log"
readonly SUMMARY_FILE="${LOG_DIR}/summary.txt"
readonly DMESG_START_MARKER="iCAT_SQLITE_START module=${MODULE_TAG} workload=${WORKLOAD_KEY} run=${RUN_ID}"
readonly DMESG_END_MARKER="iCAT_SQLITE_END module=${MODULE_TAG} workload=${WORKLOAD_KEY} run=${RUN_ID}"

YCSB_HOME=""
SQLITE_LIB=""
DC_FLAG="/tmp/icat_sqlite_dc_$$.flag"
DC_PID=""
virt_started=0
run_marked=0

die() { printf 'sqlite.sh: %s\n' "$*" >&2; exit 2; }

usage() {
    cat <<'EOF'
Usage:
  /home/meen/iCAT/script/sqlite.sh <module-tag> <a|b|d>
EOF
}

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

stop_drop_caches() {
    rm -f "${DC_FLAG}" 2>/dev/null || true
    if [[ -n "${DC_PID}" ]]; then
        wait "${DC_PID}" 2>/dev/null || true
        DC_PID=""
    fi
}

start_drop_caches() {
    [[ "${DC_LOOP}" != "off" ]] || return 0
    [[ -z "${DC_PID}" ]] || return 0

    touch "${DC_FLAG}"
    "${SUDO_BIN}" sh -c "while [ -e '${DC_FLAG}' ]; do sleep '${DC_INTERVAL}'; echo 3 > /proc/sys/vm/drop_caches; done" &
    DC_PID=$!
    printf '[DROP-CACHES] scope=%s interval=%ss pid=%s\n' "${DC_LOOP}" "${DC_INTERVAL}" "${DC_PID}"
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

resolve_ycsb() {
    if [[ -n "${YCSB_DIR:-}" ]]; then
        YCSB_HOME="${YCSB_DIR}"
    elif [[ -x "/home/meen/YCSB/ycsb-0.17.0/bin/ycsb" ]]; then
        YCSB_HOME="/home/meen/YCSB/ycsb-0.17.0"
    else
        YCSB_HOME="/home/meen/YCSB"
    fi
    SQLITE_LIB="${YCSB_HOME}/jdbc-binding/lib"
}

run_ycsb_load() {
    pushd "${YCSB_HOME}" >/dev/null
    ./bin/ycsb load jdbc -s -P "${WL}" -threads "${YCSB_THREADS}" \
        -cp "${SQLITE_LIB}/*" \
        -p db.driver=org.sqlite.JDBC \
        -p db.url="jdbc:sqlite:${DB_FILE}" \
        -p db.user= -p db.passwd= \
        -p db.batchsize=1000 \
        -p jdbc.autocommit=false
    popd >/dev/null
}

run_ycsb_run() {
    pushd "${YCSB_HOME}" >/dev/null
    ./bin/ycsb run jdbc -s -P "${WL}" -threads "${YCSB_THREADS}" \
        -cp "${SQLITE_LIB}/*" \
        -p db.driver=org.sqlite.JDBC \
        -p db.url="jdbc:sqlite:${DB_FILE}" \
        -p db.user= -p db.passwd= \
        -p jdbc.autocommit=true \
        -p hdrhistogram.percentiles=95,99,99.9,99.99,99.999,99.9999
    popd >/dev/null
}

validate_inputs() {
    [[ -n "${MODULE_TAG}" && -n "${WORKLOAD_KEY}" ]] || { usage; exit 2; }
    [[ "${MODULE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid module tag: ${MODULE_TAG}"
    case "${WORKLOAD_KEY}" in a|b|d) ;; *) die "workload must be a, b, or d";; esac
    case "${DC_LOOP}" in run|both|off) ;; *) die "DC_LOOP must be run|both|off";; esac
    [[ "${YCSB_THREADS}" =~ ^[1-9][0-9]*$ ]] || die "YCSB_THREADS must be positive integer"
    [[ "${DC_INTERVAL}" =~ ^[1-9][0-9]*$ ]] || die "DC_INTERVAL must be positive integer"

    resolve_ycsb

    [[ -x "${START_SCRIPT}" ]] || die "not executable: ${START_SCRIPT}"
    [[ -x "${END_SCRIPT}" ]] || die "not executable: ${END_SCRIPT}"
    [[ -f "${WL}" ]] || die "workload file not found: ${WL}"
    [[ -x "${YCSB_HOME}/bin/ycsb" ]] || die "YCSB not found: ${YCSB_HOME}/bin/ycsb"
    [[ -d "${SQLITE_LIB}" ]] || die "SQLite JDBC lib not found: ${SQLITE_LIB}"
    command -v sqlite3 >/dev/null || die "sqlite3 not found"
}

main() {
    validate_inputs
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

    printf '[DMESG] start marker: %s\n' "${DMESG_START_MARKER}"
    write_dmesg_marker "${DMESG_START_MARKER}"
    run_marked=1

    printf '[START] module=%s\n' "${MODULE_TAG}"
    "${START_SCRIPT}" "${MODULE_TAG}"
    virt_started=1
    verify_mount_source
    "${SUDO_BIN}" chown meen:meen "${MOUNT_POINT}"

    printf '[SQLITE] schema setup: %s\n' "${DB_FILE}"
    rm -f "${DB_FILE}" "${DB_FILE}-journal" "${DB_FILE}-wal" "${DB_FILE}-shm"
    sqlite3 "${DB_FILE}" \
        "PRAGMA page_size=4096;
         PRAGMA synchronous=NORMAL;
         PRAGMA journal_mode=WAL;
         CREATE TABLE usertable (
           YCSB_KEY VARCHAR(255) PRIMARY KEY,
           FIELD0 TEXT, FIELD1 TEXT, FIELD2 TEXT, FIELD3 TEXT, FIELD4 TEXT,
           FIELD5 TEXT, FIELD6 TEXT, FIELD7 TEXT, FIELD8 TEXT, FIELD9 TEXT
         );"

    [[ "${DC_LOOP}" == "both" ]] && start_drop_caches

    write_dmesg_marker "iCAT_SQLITE_LOAD_START run=${RUN_ID}"
    printf '[LOAD] %s\n' "${WL}"
    run_ycsb_load
    flush_device "load-end"
    write_dmesg_marker "iCAT_SQLITE_LOAD_END run=${RUN_ID}"

    [[ "${DC_LOOP}" == "run" ]] && start_drop_caches
    if [[ "${DC_LOOP}" != "off" ]]; then
        "${SUDO_BIN}" sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    fi

    write_dmesg_marker "iCAT_SQLITE_RUN_START run=${RUN_ID}"
    printf '[RUN] %s\n' "${WL}"
    run_ycsb_run
    stop_drop_caches
    flush_device "run-end"
    write_dmesg_marker "iCAT_SQLITE_RUN_END run=${RUN_ID}"

    printf '[RESULT] app=%s\n' "${APP_LOG}"
    printf '[RESULT] dmesg=%s\n' "${DMESG_RESULT}"
    printf '[RESULT] summary=%s\n' "${SUMMARY_FILE}"
}

main "$@"
