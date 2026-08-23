#!/bin/bash
set -Eeuo pipefail

# Usage:
#   /home/meen/iCAT/script/fio.sh greedy
#   /home/meen/iCAT/script/fio.sh cat-fig7
#
# Optional:
#   FIO_TEST_SIZE=6G FIO_IO_SIZE=20G /home/meen/iCAT/script/fio.sh greedy

readonly MODULE_TAG="${1:?Usage: /home/meen/iCAT/script/fio.sh <module-tag>}"
readonly SCRIPT_DIR="/home/meen/iCAT/script"
readonly WORKLOAD_DIR="/home/meen/iCAT/workloads"
readonly RESULT_DIR="/home/meen/iCAT/result"
readonly START_SCRIPT="${SCRIPT_DIR}/start_virt.sh"
readonly END_SCRIPT="${SCRIPT_DIR}/end_virt.sh"
readonly PRESET_JOB="${WORKLOAD_DIR}/preset.fio"
readonly TEST_JOB="${WORKLOAD_DIR}/test3.fio"
readonly DEVICE="/dev/nvme1n1"

readonly SUDO_BIN="/usr/bin/sudo"
readonly FIO_BIN="/usr/bin/fio"
readonly AWK_BIN="/usr/bin/awk"
readonly DATE_BIN="/usr/bin/date"
readonly DMESG_BIN="/usr/bin/dmesg"
readonly MKDIR_BIN="/usr/bin/mkdir"
readonly TEE_BIN="/usr/bin/tee"
readonly NVME_BIN="/usr/sbin/nvme"

readonly RUN_ID="$("${DATE_BIN}" '+%Y%m%d-%H%M%S')-$$"
readonly DMESG_RESULT="${RESULT_DIR}/dmesg-${MODULE_TAG}-${RUN_ID}.log"
readonly DMESG_START_MARKER="iCAT_FIO_START module=${MODULE_TAG} run=${RUN_ID}"
readonly DMESG_END_MARKER="iCAT_FIO_END module=${MODULE_TAG} run=${RUN_ID}"

export FIO_TEST_SIZE="${FIO_TEST_SIZE:-6G}"
export FIO_IO_SIZE="${FIO_IO_SIZE:-200G}"

virt_started=0
run_marked=0

die()
{
	printf 'fio.sh: %s\n' "$*" >&2
	exit 2
}

write_dmesg_marker()
{
	printf '%s\n' "$1" | \
		"${SUDO_BIN}" "${TEE_BIN}" /dev/kmsg >/dev/null
}

save_run_dmesg()
{
	"${SUDO_BIN}" "${DMESG_BIN}" --color=never | \
		"${AWK_BIN}" \
			-v start_marker="${DMESG_START_MARKER}" \
			-v end_marker="${DMESG_END_MARKER}" '
			index($0, start_marker) {
				capturing = 1
				found_start = 1
				next
			}
			index($0, end_marker) {
				capturing = 0
				found_end = 1
				next
			}
			capturing {
				print
			}
			END {
				if (!found_start || !found_end)
					exit 1
			}
		' > "${DMESG_RESULT}"
}

finish_virt()
{
	local original_status="$?"
	local finish_status=0

	trap - EXIT INT TERM
	set +e

	if ((virt_started)); then
		if [[ -b "${DEVICE}" ]]; then
			printf '[FLUSH] %s\n' "${DEVICE}"
			"${SUDO_BIN}" "${NVME_BIN}" flush "${DEVICE}" -n 1
			if (($? != 0)); then
				finish_status=1
			fi
		fi

		printf '[STOP] NVMeVirt\n'
		"${END_SCRIPT}"
		if (($? != 0)); then
			finish_status=1
		fi

	fi

	if ((run_marked)); then
		printf '[DMESG] end marker: %s\n' "${DMESG_END_MARKER}"
		write_dmesg_marker "${DMESG_END_MARKER}"
		if (($? != 0)); then
			printf 'fio.sh: failed to write the dmesg end marker\n' >&2
			finish_status=1
		fi

		printf '[DMESG] saving this run: %s\n' "${DMESG_RESULT}"
		save_run_dmesg
		if (($? != 0)); then
			printf 'fio.sh: failed to extract this run from dmesg: %s\n' \
				"${DMESG_RESULT}" >&2
			finish_status=1
		else
			printf '[RESULT] %s\n' "${DMESG_RESULT}"
		fi
	fi

	if ((original_status != 0)); then
		exit "${original_status}"
	fi
	exit "${finish_status}"
}

validate_inputs()
{
	local required_file

	[[ "${MODULE_TAG}" =~ ^[A-Za-z0-9._-]+$ ]] || \
		die "invalid module tag: ${MODULE_TAG}"

	for required_file in \
		"${START_SCRIPT}" "${END_SCRIPT}" "${PRESET_JOB}" "${TEST_JOB}"; do
		[[ -f "${required_file}" ]] || die "required file not found: ${required_file}"
	done

	[[ -x "${START_SCRIPT}" ]] || die "not executable: ${START_SCRIPT}"
	[[ -x "${END_SCRIPT}" ]] || die "not executable: ${END_SCRIPT}"
	[[ -x "${SUDO_BIN}" ]] || die "required executable not found: ${SUDO_BIN}"
	[[ -x "${FIO_BIN}" ]] || die "required executable not found: ${FIO_BIN}"
	[[ -x "${AWK_BIN}" ]] || die "required executable not found: ${AWK_BIN}"
	[[ -x "${DATE_BIN}" ]] || die "required executable not found: ${DATE_BIN}"
	[[ -x "${DMESG_BIN}" ]] || die "required executable not found: ${DMESG_BIN}"
	[[ -x "${MKDIR_BIN}" ]] || die "required executable not found: ${MKDIR_BIN}"
	[[ -x "${TEE_BIN}" ]] || die "required executable not found: ${TEE_BIN}"
	[[ -x "${NVME_BIN}" ]] || die "required executable not found: ${NVME_BIN}"
	[[ -e /dev/kmsg ]] || die "kernel message device not found: /dev/kmsg"
}

main()
{
	validate_inputs
	"${SUDO_BIN}" -v
	"${MKDIR_BIN}" -p "${RESULT_DIR}"

	trap finish_virt EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM

	printf '[DMESG] start marker: %s\n' "${DMESG_START_MARKER}"
	write_dmesg_marker "${DMESG_START_MARKER}"
	run_marked=1

	printf '[START] module=%s\n' "${MODULE_TAG}"
	"${START_SCRIPT}" "${MODULE_TAG}"
	virt_started=1

	printf '[PRESET] size=%s job=%s\n' "${FIO_TEST_SIZE}" "${PRESET_JOB}"
	"${FIO_BIN}" "${PRESET_JOB}"

	printf '[TEST] size=%s io_size=%s job=%s\n' \
		"${FIO_TEST_SIZE}" "${FIO_IO_SIZE}" "${TEST_JOB}"
	"${FIO_BIN}" "${TEST_JOB}"
}

main "$@"
