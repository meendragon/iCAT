#!/usr/bin/env bash
set -Eeuo pipefail

readonly NVMEV_ROOT="/home/meen/iCAT/nvmevirt_test"
readonly KBUILD_FILE="/home/meen/iCAT/nvmevirt_test/Kbuild"
readonly CONV_FTL_C="/home/meen/iCAT/nvmevirt_test/conv_ftl.c"
readonly CONV_FTL_H="/home/meen/iCAT/nvmevirt_test/conv_ftl.h"
readonly KERNEL_BUILD_DIR="/lib/modules/$(/usr/bin/uname -r)/build"
readonly KERNEL_BUILD_MAKEFILE="${KERNEL_BUILD_DIR}/Makefile"

readonly BUILD_OUTPUT_DIR="/home/meen/iCAT/buildoutput"
readonly GREEDY_OUTPUT="/home/meen/iCAT/buildoutput/nvmev-greedy.ko"
readonly CAT_FIG7_OUTPUT="/home/meen/iCAT/buildoutput/nvmev-cat-fig7.ko"
readonly GREEDY_INFO_OUTPUT="/home/meen/iCAT/buildoutput/nvmev-greedy.build-info.txt"
readonly CAT_FIG7_INFO_OUTPUT="/home/meen/iCAT/buildoutput/nvmev-cat-fig7.build-info.txt"
readonly BUILT_MODULE="/home/meen/iCAT/nvmevirt_test/nvmev.ko"

readonly MAKE_BIN="/usr/bin/make"
readonly MKDIR_BIN="/usr/bin/mkdir"
readonly INSTALL_BIN="/usr/bin/install"
readonly GREP_BIN="/usr/bin/grep"
readonly STRINGS_BIN="/usr/bin/strings"
readonly SHA256SUM_BIN="/usr/bin/sha256sum"
readonly DATE_BIN="/usr/bin/date"

if [[ -x "/usr/bin/nproc" ]]; then
	readonly JOBS="$(/usr/bin/nproc)"
else
	readonly JOBS="1"
fi

die()
{
	printf 'build_two_gc_policies.sh: %s\n' "$*" >&2
	exit 2
}

require_executable()
{
	local executable_path="$1"

	[[ -x "${executable_path}" ]] || die "required executable not found: ${executable_path}"
}

validate_inputs()
{
	require_executable "${MAKE_BIN}"
	require_executable "${MKDIR_BIN}"
	require_executable "${INSTALL_BIN}"
	require_executable "${GREP_BIN}"
	require_executable "${STRINGS_BIN}"
	require_executable "${SHA256SUM_BIN}"
	require_executable "${DATE_BIN}"

	[[ -d "${NVMEV_ROOT}" ]] || die "NVMeVirt source directory not found: ${NVMEV_ROOT}"
	[[ -f "${KBUILD_FILE}" ]] || die "Kbuild not found: ${KBUILD_FILE}"
	[[ -f "${CONV_FTL_C}" ]] || die "conv_ftl.c not found: ${CONV_FTL_C}"
	[[ -f "${CONV_FTL_H}" ]] || die "conv_ftl.h not found: ${CONV_FTL_H}"
	[[ -f "${KERNEL_BUILD_MAKEFILE}" ]] || \
		die "kernel build Makefile not found: ${KERNEL_BUILD_MAKEFILE}"

	"${GREP_BIN}" -Eq \
		'^[[:space:]]*CONFIG_NVMEVIRT_SSD[[:space:]]*:=[[:space:]]*y([[:space:]]|$)' \
		"${KBUILD_FILE}" || \
		die "CONFIG_NVMEVIRT_SSD := y is not enabled in ${KBUILD_FILE}"

	if "${GREP_BIN}" -Eq \
		'^[[:space:]]*CONFIG_NVMEVIRT_NVM[[:space:]]*:=[[:space:]]*y([[:space:]]|$)' \
		"${KBUILD_FILE}"; then
		die "disable CONFIG_NVMEVIRT_NVM in ${KBUILD_FILE}; only SSD must be enabled"
	fi

	"${GREP_BIN}" -q 'NVMEVIRT_GC_POLICY' "${KBUILD_FILE}" || \
		die "NVMEVIRT_GC_POLICY selection block is missing from ${KBUILD_FILE}"

	"${GREP_BIN}" -q 'CONV_GC_POLICY_CAT_FIG7' "${CONV_FTL_H}" || \
		die "CAT-Fig.7 policy definitions are missing from ${CONV_FTL_H}"
}

verify_module_policy()
{
	local module_path="$1"
	local expected_policy_string="$2"

	[[ -f "${module_path}" ]] || die "built module not found: ${module_path}"

	if ! "${STRINGS_BIN}" "${module_path}" | \
		"${GREP_BIN}" -Fx "${expected_policy_string}" >/dev/null; then
		die "compiled policy verification failed: expected ${expected_policy_string} in ${module_path}"
	fi
}

write_build_info()
{
	local info_output="$1"
	local label="$2"
	local policy="$3"
	local module_output="$4"
	local module_sha256="$5"

	{
		printf 'label=%s\n' "${label}"
		printf 'policy=%s\n' "${policy}"
		printf 'built_at=%s\n' "$("${DATE_BIN}" '+%Y-%m-%dT%H:%M:%S%z')"
		printf 'source_root=%s\n' "${NVMEV_ROOT}"
		printf 'kernel_build_dir=%s\n' "${KERNEL_BUILD_DIR}"
		printf 'module_output=%s\n' "${module_output}"
		printf 'module_sha256=%s\n' "${module_sha256}"
	} > "${info_output}"
}

build_one()
{
	local label="$1"
	local policy="$2"
	local expected_policy_string="$3"
	local module_output="$4"
	local info_output="$5"
	local module_sha256

	printf '[BUILD] label=%s policy=%s\n' "${label}" "${policy}"

	"${MAKE_BIN}" -C "${KERNEL_BUILD_DIR}" M="${NVMEV_ROOT}" clean
	"${MAKE_BIN}" -C "${KERNEL_BUILD_DIR}" M="${NVMEV_ROOT}" \
		-j"${JOBS}" modules NVMEVIRT_GC_POLICY="${policy}"

	[[ -f "${BUILT_MODULE}" ]] || \
		die "build completed but module was not produced: ${BUILT_MODULE}"

	"${INSTALL_BIN}" -m 0644 "${BUILT_MODULE}" "${module_output}"
	verify_module_policy "${module_output}" "${expected_policy_string}"

	read -r module_sha256 _ < <("${SHA256SUM_BIN}" "${module_output}")
	write_build_info "${info_output}" "${label}" "${policy}" \
		"${module_output}" "${module_sha256}"

	printf '[OUTPUT] %s\n' "${module_output}"
}

main()
{
	validate_inputs
	"${MKDIR_BIN}" -p "${BUILD_OUTPUT_DIR}"

	build_one \
		"greedy" \
		"GREEDY" \
		"greedy" \
		"${GREEDY_OUTPUT}" \
		"${GREEDY_INFO_OUTPUT}"

	build_one \
		"cat-fig7" \
		"CAT_FIG7" \
		"cat-fig7" \
		"${CAT_FIG7_OUTPUT}" \
		"${CAT_FIG7_INFO_OUTPUT}"

	printf '[DONE] Greedy module: %s\n' "${GREEDY_OUTPUT}"
	printf '[DONE] CAT-Fig.7 module: %s\n' "${CAT_FIG7_OUTPUT}"
}

main "$@"
