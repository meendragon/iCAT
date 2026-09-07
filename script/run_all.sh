#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================================
# run_all.sh
#
# Final GC/iCAT 통합 batch runner
#
# Supported:
#   1) fio
#   2) sqlite
#   3) rocksdb
#   4) filebench
#   5) llama
#
# Usage:
#   /home/meen/iCAT/script/run_all.sh fio <workload> [repeats]
#   /home/meen/iCAT/script/run_all.sh sqlite <a|b|d> [repeats]
#   /home/meen/iCAT/script/run_all.sh rocksdb <a|b|d> [repeats]
#   /home/meen/iCAT/script/run_all.sh filebench <workload> [repeats]
#   /home/meen/iCAT/script/run_all.sh llama [repeats]
#
# Examples:
#   /home/meen/iCAT/script/run_all.sh fio test5
#   /home/meen/iCAT/script/run_all.sh fio test5 3
#   /home/meen/iCAT/script/run_all.sh sqlite a 3
#   /home/meen/iCAT/script/run_all.sh rocksdb d
#   /home/meen/iCAT/script/run_all.sh filebench varmail 2
#   /home/meen/iCAT/script/run_all.sh llama 3
#
# Policy sweep per repeat:
#   - greedy: 1
#   - CAT: 4(k) * 5(scale) * 3(ratio) = 60
#   - total: 61 modules
#
# Every child runner appends final GC/WAF data to <result-dir>/summary.txt.
#
# Result roots:
#   fio       -> /home/meen/iCAT/result/<workload>/
#   sqlite    -> /home/meen/iCAT/result/sqlite/workload{a|b|d}/
#   rocksdb   -> /home/meen/iCAT/result/rocksdb/workload{a|b|d}/
#   filebench -> /home/meen/iCAT/result/filebench/<workload>/
#   llama     -> /home/meen/iCAT/result/llama/
# ============================================================================

readonly SUITE="${1:-}"

readonly SCRIPT_DIR="/home/meen/iCAT/script"
readonly MODULE_DIR="/home/meen/iCAT/buildoutput"
readonly WORKLOAD_DIR="/home/meen/iCAT/workloads"
readonly RESULT_ROOT="/home/meen/iCAT/result"

readonly FIO_SCRIPT="${SCRIPT_DIR}/fio.sh"
readonly SQLITE_SCRIPT="${SCRIPT_DIR}/sqlite.sh"
readonly ROCKSDB_SCRIPT="${SCRIPT_DIR}/rocksdb.sh"
readonly FILEBENCH_SCRIPT="${SCRIPT_DIR}/filebench.sh"
readonly LLAMA_SCRIPT="${SCRIPT_DIR}/llama.sh"

readonly MKDIR_BIN="/usr/bin/mkdir"
readonly TEE_BIN="/usr/bin/tee"
readonly DATE_BIN="/usr/bin/date"

readonly -a CAT_KS=(02 04 07 10)
readonly -a CAT_SCALES=(025 050 100 200 400)
readonly -a CAT_RATIOS=(04 07 16)

declare -a MODULE_TAGS=(greedy)

RUNNER=""
TARGET=""
REPEATS=""
WORKLOAD_FILE=""
WORKLOAD_NAME=""
RESULT_DIR=""
BATCH_KIND_DESC=""

die()
{
	printf 'run_all.sh: %s\n' "$*" >&2
	exit 2
}

usage()
{
	cat <<'EOF'
Usage:
  /home/meen/iCAT/script/run_all.sh fio <workload> [repeats]
  /home/meen/iCAT/script/run_all.sh sqlite <a|b|d> [repeats]
  /home/meen/iCAT/script/run_all.sh rocksdb <a|b|d> [repeats]
  /home/meen/iCAT/script/run_all.sh filebench <workload> [repeats]
  /home/meen/iCAT/script/run_all.sh llama [repeats]

Examples:
  /home/meen/iCAT/script/run_all.sh fio test5
  /home/meen/iCAT/script/run_all.sh fio test5 3
  /home/meen/iCAT/script/run_all.sh sqlite a 3
  /home/meen/iCAT/script/run_all.sh rocksdb d
  /home/meen/iCAT/script/run_all.sh filebench varmail 2
  /home/meen/iCAT/script/run_all.sh llama 3
EOF
}

is_positive_integer()
{
	[[ "$1" =~ ^[1-9][0-9]*$ ]]
}

prepare_module_tags()
{
	local k
	local scale
	local ratio

	for k in "${CAT_KS[@]}"; do
		for scale in "${CAT_SCALES[@]}"; do
			for ratio in "${CAT_RATIOS[@]}"; do
				MODULE_TAGS+=("cat-fig7-k${k}-s${scale}-r${ratio}")
			done
		done
	done
}

resolve_suite_and_args()
{
	case "${SUITE}" in
		fio)
			[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
			TARGET="$2"
			REPEATS="${3:-1}"

			[[ "${TARGET}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
				die "invalid fio workload name: ${TARGET}"

			if [[ "${TARGET}" == *.fio ]]; then
				WORKLOAD_FILE="${TARGET}"
				WORKLOAD_NAME="${TARGET%.fio}"
			else
				WORKLOAD_FILE="${TARGET}.fio"
				WORKLOAD_NAME="${TARGET}"
			fi

			RUNNER="${FIO_SCRIPT}"
			RESULT_DIR="${RESULT_ROOT}/${WORKLOAD_NAME}"
			BATCH_KIND_DESC="fio:${WORKLOAD_NAME}"
			;;

		sqlite)
			[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
			TARGET="$2"
			REPEATS="${3:-1}"

			case "${TARGET}" in
				a|b|d) ;;
				*) die "sqlite workload must be one of: a, b, d" ;;
			esac

			WORKLOAD_NAME="workload${TARGET}"
			RUNNER="${SQLITE_SCRIPT}"
			RESULT_DIR="${RESULT_ROOT}/sqlite/${WORKLOAD_NAME}"
			BATCH_KIND_DESC="sqlite:${WORKLOAD_NAME}"
			;;

		rocksdb)
			[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
			TARGET="$2"
			REPEATS="${3:-1}"

			case "${TARGET}" in
				a|b|d) ;;
				*) die "rocksdb workload must be one of: a, b, d" ;;
			esac

			WORKLOAD_NAME="workload${TARGET}"
			RUNNER="${ROCKSDB_SCRIPT}"
			RESULT_DIR="${RESULT_ROOT}/rocksdb/${WORKLOAD_NAME}"
			BATCH_KIND_DESC="rocksdb:${WORKLOAD_NAME}"
			;;

		filebench)
			[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 2; }
			TARGET="$2"
			REPEATS="${3:-1}"

			[[ "${TARGET}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
				die "invalid filebench workload name: ${TARGET}"

			if [[ "${TARGET}" == *.f ]]; then
				WORKLOAD_FILE="${TARGET}"
				WORKLOAD_NAME="${TARGET%.f}"
			else
				WORKLOAD_FILE="${TARGET}.f"
				WORKLOAD_NAME="${TARGET}"
			fi

			RUNNER="${FILEBENCH_SCRIPT}"
			RESULT_DIR="${RESULT_ROOT}/filebench/${WORKLOAD_NAME}"
			BATCH_KIND_DESC="filebench:${WORKLOAD_NAME}"
			;;

		llama)
			[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
			REPEATS="${2:-1}"
			WORKLOAD_NAME="llama"
			RUNNER="${LLAMA_SCRIPT}"
			RESULT_DIR="${RESULT_ROOT}/llama"
			BATCH_KIND_DESC="llama"
			;;

		""|-h|--help)
			usage
			exit 2
			;;

		*)
			die "unknown suite: ${SUITE} (use fio|sqlite|rocksdb|filebench|llama)"
			;;
	esac

	is_positive_integer "${REPEATS}" ||
		die "repeat count must be a positive integer"
}

validate_runner_inputs()
{
	local tag
	local module_path

	[[ -x "${RUNNER}" ]] ||
		die "runner missing or not executable: ${RUNNER}"
	[[ -x "${MKDIR_BIN}" ]] ||
		die "required executable not found: ${MKDIR_BIN}"
	[[ -x "${TEE_BIN}" ]] ||
		die "required executable not found: ${TEE_BIN}"
	[[ -x "${DATE_BIN}" ]] ||
		die "required executable not found: ${DATE_BIN}"

	case "${SUITE}" in
		fio)
			[[ -f "${WORKLOAD_DIR}/${WORKLOAD_FILE}" ]] ||
				die "fio workload not found: ${WORKLOAD_DIR}/${WORKLOAD_FILE}"
			;;

		sqlite)
			[[ -f "${WORKLOAD_DIR}/sqlite/${WORKLOAD_NAME}" ]] ||
				die "sqlite workload not found: ${WORKLOAD_DIR}/sqlite/${WORKLOAD_NAME}"
			;;

		rocksdb)
			[[ -f "${WORKLOAD_DIR}/rocksdb/${WORKLOAD_NAME}" ]] ||
				die "rocksdb workload not found: ${WORKLOAD_DIR}/rocksdb/${WORKLOAD_NAME}"
			;;

		filebench)
			[[ -f "${WORKLOAD_DIR}/filebench/${WORKLOAD_FILE}" ]] ||
				die "filebench workload not found: ${WORKLOAD_DIR}/filebench/${WORKLOAD_FILE}"
			;;

		llama)
			:
			;;
	esac

	for tag in "${MODULE_TAGS[@]}"; do
		module_path="${MODULE_DIR}/nvmev-${tag}.ko"
		[[ -f "${module_path}" ]] ||
			die "module not found: ${module_path}"
	done
}

run_one()
{
	local tag="$1"

	case "${SUITE}" in
		fio)
			"${RUNNER}" "${tag}" "${TARGET}"
			;;

		sqlite|rocksdb|filebench)
			"${RUNNER}" "${tag}" "${TARGET}"
			;;

		llama)
			"${RUNNER}" "${tag}"
			;;

		*)
			die "internal error: unknown suite in run_one: ${SUITE}"
			;;
	esac
}

main()
{
	local repeat
	local index
	local tag
	local batch_id
	local batch_log
	local total_runs

	resolve_suite_and_args "$@"
	prepare_module_tags
	validate_runner_inputs

	"${MKDIR_BIN}" -p "${RESULT_DIR}"

	batch_log="${RESULT_DIR}/batch.log"
	total_runs="$((REPEATS * ${#MODULE_TAGS[@]}))"

	exec > >("${TEE_BIN}" "${batch_log}") 2>&1

	printf '[BATCH] suite=%s desc=%s\n' "${SUITE}" "${BATCH_KIND_DESC}"
	printf '[BATCH] runner=%s\n' "${RUNNER}"

	case "${SUITE}" in
		fio)
			printf '[BATCH] workload_file=%s\n' "${WORKLOAD_DIR}/${WORKLOAD_FILE}"
			;;
		sqlite)
			printf '[BATCH] workload_file=%s\n' "${WORKLOAD_DIR}/sqlite/${WORKLOAD_NAME}"
			;;
		rocksdb)
			printf '[BATCH] workload_file=%s\n' "${WORKLOAD_DIR}/rocksdb/${WORKLOAD_NAME}"
			;;
		filebench)
			printf '[BATCH] workload_file=%s\n' "${WORKLOAD_DIR}/filebench/${WORKLOAD_FILE}"
			;;
		llama)
			printf '[BATCH] workload_file=%s\n' "N/A (llama-bench uses its configured model)"
			;;
	esac

	printf '[BATCH] repeats=%s policies=%s total_runs=%s\n' \
		"${REPEATS}" \
		"${#MODULE_TAGS[@]}" \
		"${total_runs}"

	printf '[BATCH] result_dir=%s\n' "${RESULT_DIR}"
	printf '[BATCH] log=%s\n' "${batch_log}"

	for ((repeat = 1; repeat <= REPEATS; repeat++)); do
		for index in "${!MODULE_TAGS[@]}"; do
			tag="${MODULE_TAGS[index]}"

			printf '\n[RUN] suite=%s repeat=%d/%d policy=%d/%d tag=%s start=%s\n' \
				"${SUITE}" \
				"${repeat}" \
				"${REPEATS}" \
				"$((index + 1))" \
				"${#MODULE_TAGS[@]}" \
				"${tag}" \
				"$("${DATE_BIN}" '+%F %T%z')"

			run_one "${tag}"

			printf '[PASS] suite=%s repeat=%d tag=%s end=%s\n' \
				"${SUITE}" \
				"${repeat}" \
				"${tag}" \
				"$("${DATE_BIN}" '+%F %T%z')"
		done
	done

	printf '\n[DONE] suite=%s total_runs=%s result_dir=%s log=%s\n' \
		"${SUITE}" \
		"${total_runs}" \
		"${RESULT_DIR}" \
		"${batch_log}"
}

main "$@"
