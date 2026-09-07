#!/usr/bin/env bash
set -Eeuo pipefail

# Builds one Greedy module and all 4 x 5 x 3 transformed-age configurations.
# Output: /home/meen/iCAT/buildoutput/nvmev-*.ko

readonly SOURCE_DIR="/home/meen/iCAT/nvmevirt_test"
readonly KBUILD_FILE="/home/meen/iCAT/nvmevirt_test/Kbuild"
readonly CONV_FTL_C="/home/meen/iCAT/nvmevirt_test/conv_ftl.c"
readonly CONV_FTL_H="/home/meen/iCAT/nvmevirt_test/conv_ftl.h"
readonly BUILT_MODULE="/home/meen/iCAT/nvmevirt_test/nvmev.ko"
readonly OUTPUT_DIR="/home/meen/iCAT/buildoutput"
readonly MANIFEST="/home/meen/iCAT/buildoutput/build-manifest.tsv"
readonly HASH_FILE="/home/meen/iCAT/buildoutput/sha256sums.txt"

readonly UNAME_BIN="/usr/bin/uname"
readonly MAKE_BIN="/usr/bin/make"
readonly MKDIR_BIN="/usr/bin/mkdir"
readonly INSTALL_BIN="/usr/bin/install"
readonly GREP_BIN="/usr/bin/grep"
readonly AWK_BIN="/usr/bin/awk"
readonly STRINGS_BIN="/usr/bin/strings"
readonly SHA256SUM_BIN="/usr/bin/sha256sum"
readonly DATE_BIN="/usr/bin/date"

readonly KERNEL_BUILD_DIR="/lib/modules/$("${UNAME_BIN}" -r)/build"
readonly KERNEL_BUILD_MAKEFILE="${KERNEL_BUILD_DIR}/Makefile"

readonly -a CAT_KS=(2 4 7 10)
readonly -a CAT_SCALES=(25 50 100 200 400)
readonly -a CAT_RATIOS=(4 7 16)

if [[ -x /usr/bin/nproc ]]; then
	readonly JOBS="$(/usr/bin/nproc)"
else
	readonly JOBS=1
fi

declare -a BUILT_OUTPUTS=()

die()
{
	printf 'build.sh: %s\n' "$*" >&2
	exit 2
}

require_executable()
{
	[[ -x "$1" ]] || die "required executable not found: $1"
}

validate_inputs()
{
	local executable_path

	for executable_path in \
		"${UNAME_BIN}" "${MAKE_BIN}" "${MKDIR_BIN}" "${INSTALL_BIN}" \
		"${GREP_BIN}" "${AWK_BIN}" "${STRINGS_BIN}" \
		"${SHA256SUM_BIN}" "${DATE_BIN}"; do
		require_executable "${executable_path}"
	done

	[[ -d "${SOURCE_DIR}" ]] || die "source directory not found: ${SOURCE_DIR}"
	[[ -f "${KBUILD_FILE}" ]] || die "Kbuild not found: ${KBUILD_FILE}"
	[[ -f "${CONV_FTL_C}" ]] || die "conv_ftl.c not found: ${CONV_FTL_C}"
	[[ -f "${CONV_FTL_H}" ]] || die "conv_ftl.h not found: ${CONV_FTL_H}"
	[[ -f "${KERNEL_BUILD_MAKEFILE}" ]] || \
		die "kernel build Makefile not found: ${KERNEL_BUILD_MAKEFILE}"

	"${GREP_BIN}" -Eq \
		'^[[:space:]]*CONFIG_NVMEVIRT_SSD[[:space:]]*:=[[:space:]]*y([[:space:]]|$)' \
		"${KBUILD_FILE}" || die "CONFIG_NVMEVIRT_SSD := y is not enabled"

	if "${GREP_BIN}" -Eq \
		'^[[:space:]]*CONFIG_NVMEVIRT_NVM[[:space:]]*:=[[:space:]]*y([[:space:]]|$)' \
		"${KBUILD_FILE}"; then
		die "disable CONFIG_NVMEVIRT_NVM; only SSD must be enabled"
	fi

	"${GREP_BIN}" -q 'NVMEVIRT_CAT_SCALE_PCT' "${KBUILD_FILE}" || \
		die "NVMEVIRT_CAT_SCALE_PCT is missing from Kbuild"
	"${GREP_BIN}" -q 'NVMEVIRT_CAT_K' "${KBUILD_FILE}" || \
		die "NVMEVIRT_CAT_K is missing from Kbuild"
	"${GREP_BIN}" -q 'NVMEVIRT_CAT_AGE_RATIO' "${KBUILD_FILE}" || \
		die "NVMEVIRT_CAT_AGE_RATIO is missing from Kbuild"
	"${GREP_BIN}" -q 'CAT_FIG7_SCALE_PCT' "${CONV_FTL_C}" || \
		die "CAT_FIG7_SCALE_PCT is missing from conv_ftl.c"
	"${GREP_BIN}" -q 'CAT_FIG7_K' "${CONV_FTL_C}" || \
		die "CAT_FIG7_K is missing from conv_ftl.c"
	"${GREP_BIN}" -q 'CAT_FIG7_AGE_RATIO' "${CONV_FTL_C}" || \
		die "CAT_FIG7_AGE_RATIO is missing from conv_ftl.c"
}

verify_policy_string()
{
	local module_path="$1"
	local expected_policy="$2"

	if ! "${STRINGS_BIN}" "${module_path}" | \
		"${GREP_BIN}" -Fx "${expected_policy}" >/dev/null; then
		die "policy verification failed: ${module_path} does not contain ${expected_policy}"
	fi
}

record_module()
{
	local label="$1"
	local policy="$2"
	local age_levels="$3"
	local scale_pct="$4"
	local age_ratio="$5"
	local output_path="$6"
	local module_sha256

	read -r module_sha256 _ < <("${SHA256SUM_BIN}" "${output_path}")
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"${label}" "${policy}" "${age_levels}" "${scale_pct}" "${age_ratio}" \
		"${module_sha256}" "${output_path}" >> "${MANIFEST}"
	BUILT_OUTPUTS+=("${output_path}")
}

build_one()
{
	local label="$1"
	local policy="$2"
	local age_levels="$3"
	local scale_pct="$4"
	local age_ratio="$5"
	local expected_policy="$6"
	local output_path="${OUTPUT_DIR}/nvmev-${label}.ko"

	printf '[BUILD] label=%s policy=%s k=%s scale_pct=%s age_ratio=%s\n' \
		"${label}" "${policy}" "${age_levels}" "${scale_pct}" "${age_ratio}"

	"${MAKE_BIN}" -C "${KERNEL_BUILD_DIR}" M="${SOURCE_DIR}" clean
	"${MAKE_BIN}" -C "${KERNEL_BUILD_DIR}" M="${SOURCE_DIR}" \
		-j"${JOBS}" \
		NVMEVIRT_GC_POLICY="${policy}" \
		NVMEVIRT_CAT_K="${age_levels}" \
		NVMEVIRT_CAT_SCALE_PCT="${scale_pct}" \
		NVMEVIRT_CAT_AGE_RATIO="${age_ratio}" \
		modules

	[[ -f "${BUILT_MODULE}" ]] || die "module was not produced: ${BUILT_MODULE}"
	"${INSTALL_BIN}" -m 0644 "${BUILT_MODULE}" "${output_path}"
	verify_policy_string "${output_path}" "${expected_policy}"
	record_module "${label}" "${policy}" "${age_levels}" "${scale_pct}" \
		"${age_ratio}" "${output_path}"

	printf '[OUTPUT] %s\n' "${output_path}"
}

verify_all_binaries_are_distinct()
{
	local duplicate_report

	"${SHA256SUM_BIN}" "${BUILT_OUTPUTS[@]}" > "${HASH_FILE}"
	duplicate_report="$("${AWK_BIN}" '
		{
			count[$1]++
			files[$1] = files[$1] "\n  " $2
		}
		END {
			for (hash in count) {
				if (count[hash] > 1)
					print "SHA256=" hash files[hash]
			}
		}
	' "${HASH_FILE}")"

	if [[ -n "${duplicate_report}" ]]; then
		printf '[DUPLICATE]\n%s\n' "${duplicate_report}" >&2
		die "two or more output modules have identical binary contents"
	fi

	printf '[VERIFY] all %d module binaries are distinct\n' "${#BUILT_OUTPUTS[@]}"
}

main()
{
	local scale_pct
	local age_ratio
	local age_levels
	local k_tag
	local scale_tag
	local ratio_tag

	validate_inputs
	"${MKDIR_BIN}" -p "${OUTPUT_DIR}"

	{
		printf '# built_at=%s\n' "$("${DATE_BIN}" '+%Y-%m-%dT%H:%M:%S%z')"
		printf 'label\tpolicy\tk\tscale_pct\tage_ratio\tsha256\tpath\n'
	} > "${MANIFEST}"

	build_one "greedy" "GREEDY" "0" "0" "0" "greedy"

	for age_levels in "${CAT_KS[@]}"; do
		printf -v k_tag '%02d' "${age_levels}"
		for scale_pct in "${CAT_SCALES[@]}"; do
			printf -v scale_tag '%03d' "${scale_pct}"
			for age_ratio in "${CAT_RATIOS[@]}"; do
				printf -v ratio_tag '%02d' "${age_ratio}"
				build_one \
					"cat-fig7-k${k_tag}-s${scale_tag}-r${ratio_tag}" \
					"CAT_FIG7" \
					"${age_levels}" \
					"${scale_pct}" \
					"${age_ratio}" \
					"cat-fig7"
			done
		done
	done

	verify_all_binaries_are_distinct
	printf '[DONE] modules=%d output=%s\n' "${#BUILT_OUTPUTS[@]}" "${OUTPUT_DIR}"
	printf '[MANIFEST] %s\n' "${MANIFEST}"
	printf '[SHA256] %s\n' "${HASH_FILE}"
}

main "$@"
