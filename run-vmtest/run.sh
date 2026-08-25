#!/bin/bash

set -euo pipefail
trap 'exit 2' ERR

source "${GITHUB_ACTION_PATH}/../helpers.sh"

export ARCH=${ARCH:-$(uname -m)}
export KERNEL=${KERNEL:-"LATEST"}

# vmsh boots the uncompressed ELF image, so unlike vmtest we have no use
# for the compressed one and no need to ask the kernel Makefile what it
# is called. The same file is what libbpf reads BTF out of below.
VMLINUX=${VMLINUX:-"$KBUILD_OUTPUT/vmlinux"}
if [[ ! -f "${VMLINUX}" ]]; then
    echo "Could not find VMLINUX=\"$VMLINUX\", exiting"
    exit 2
fi
# Absolute, because it is about to become a symlink target elsewhere in
# the file system.
export VMLINUX=$(realpath "${VMLINUX}")

# Create a symlink to vmlinux from a "standard" location
# See btf__load_vmlinux_btf() in libbpf
VMLINUX_VERSION="$(strings ${VMLINUX} | grep -m 1 'Linux version' | awk '{print $3}')" || true
sudo mkdir -p /usr/lib/debug/boot
sudo ln -sf "${VMLINUX}" "/usr/lib/debug/boot/vmlinux-${VMLINUX_VERSION}"

RUN_BPFTOOL_CHECKS=${RUN_BPFTOOL_CHECKS:-}
if [[ -z "${RUN_BPFTOOL_CHECKS}" \
          && "${KERNEL}" = 'LATEST' \
          && "$KERNEL_TEST" != "sched_ext" ]];
then
    RUN_BPFTOOL_CHECKS=true
fi

VMTEST_CONFIGS=${VMTEST_CONFIGS:-}

# The guest shares this working directory, so pin the paths the in-VM
# scripts write to here instead of letting them guess at a mount point.
# Both sides then agree on where the status file and the test output land.
export SELFTESTS_BPF=${SELFTESTS_BPF:-"${PWD}/selftests/bpf"}
export STATUS_FILE=${STATUS_FILE:-"${PWD}/exitstatus"}
export OUTPUT_DIR=${OUTPUT_DIR:-"${PWD}"}
export VERISTAT_CONFIGS=${VERISTAT_CONFIGS:-${VMTEST_CONFIGS:-"${PWD}/ci/vmtest/configs"}}

# Sourced after the above, because it builds the allow/denylist paths out
# of $SELFTESTS_BPF.
if [[ -n "$VMTEST_CONFIGS" && -f "${VMTEST_CONFIGS}/run-vmtest.env" ]];
then
    source "${VMTEST_CONFIGS}/run-vmtest.env"
fi

VMTEST_SCRIPT=${VMTEST_SCRIPT:-}
if [[ -z "$VMTEST_SCRIPT" && "$KERNEL_TEST" == "sched_ext" ]];
then
    VMTEST_SCRIPT="${GITHUB_ACTION_PATH}/run-scx-selftests.sh"
elif [[ -z "$VMTEST_SCRIPT" ]];
then
    ${GITHUB_ACTION_PATH}/prepare-bpf-selftests.sh
    VMTEST_SCRIPT="${GITHUB_ACTION_PATH}/run-bpf-selftests.sh"
fi

# clear exitstatus file
echo -n > "${STATUS_FILE}"

foldable start bpftool_checks "Running bpftool checks..."

# bpftool checks are aimed at checking type names, documentation, shell
# completion etc. against the current kernel, so only run on LATEST.
if [[ -n "${RUN_BPFTOOL_CHECKS}" ]]; then
	bpftool_exitstatus=0
	# "&& true" does not change the return code (it is not executed if the
	# Python script fails), but it prevents the trap on ERR set at the top
	# of this file to trigger on failure.
	"${KERNEL_ROOT}/tools/testing/selftests/bpf/test_bpftool_synctypes.py" && true
	bpftool_exitstatus=$?
	if [[ $bpftool_exitstatus -eq 0 ]]; then
		echo "bpftool checks passed successfully."
	else
		echo "bpftool checks returned ${bpftool_exitstatus}."
	fi
	echo "bpftool:${bpftool_exitstatus}" >> "${STATUS_FILE}"
else
	echo "bpftool checks skipped."
fi

foldable end bpftool_checks

foldable start vmsh "Starting virtual machine..."

# Tests may be comma-separated. The test script expects them to come from
# the CLI space-separated.
TEST_RUNNERS=$(echo ${KERNEL_TEST} | tr -s ',' ' ')

VMTEST_NUM_CPUS=${VMTEST_NUM_CPUS:-2}
VMTEST_MEMORY=${VMTEST_MEMORY:-4G}

# vmsh wants a bare number of MiB, whereas VMTEST_MEMORY is spelled the
# way QEMU spells it.
to_mib() {
	local value=${1^^}
	local digits=${value%%[!0-9]*}

	case "${value}" in
		"")                 echo "VMTEST_MEMORY is empty" >&2; return 1 ;;
		"${digits}"G|"${digits}"GB|"${digits}"GIB) echo $((digits * 1024)) ;;
		"${digits}"M|"${digits}"MB|"${digits}"MIB) echo "${digits}" ;;
		"${digits}")        echo "${digits}" ;;
		*)                  echo "Cannot parse VMTEST_MEMORY=\"$1\"" >&2; return 1 ;;
	esac
}

# Via a variable, so that a VMTEST_MEMORY we cannot parse trips set -e
# rather than handing vmsh an empty --memory.
VMTEST_MEMORY_MIB=$(to_mib "${VMTEST_MEMORY}")

# --all-envs, because the in-VM scripts are configured entirely through
# the environment. --share-rw /, to match the read-write host root vmtest
# gave us, rather than vmsh's read-only default. vmsh runs the command
# with the host's working directory, and exec's it without a shell, hence
# guest-entry.sh.
vmsh \
	--kernel "${VMLINUX}" \
	--cpus "${VMTEST_NUM_CPUS}" \
	--memory "${VMTEST_MEMORY_MIB}" \
	--all-envs \
	--share-rw / \
	-- "${GITHUB_ACTION_PATH}/guest-entry.sh" "${VMTEST_SCRIPT}" ${TEST_RUNNERS}

foldable end vmsh

if grep -q '^kernel_splats:1$' "${STATUS_FILE}"; then
  splat_error="kernel splat check failed"
  if [[ -s kernel_splats.log ]]; then
    cat kernel_splats.log
    splat_error=$(head -n 1 kernel_splats.log)
  fi
  splat_error=${splat_error//'%'/'%25'}
  splat_error=${splat_error//$'\r'/'%0D'}
  printf '::error title=kernel_splats::%s\n' "${splat_error}"
fi

foldable start collect_status "Collecting exit status"

exitfile="$(cat "${STATUS_FILE}" 2>/dev/null)"
exitstatus="$(echo -e "$exitfile" | awk --field-separator ':' \
  'BEGIN { s=0 } { if ($2) {s=1} } END { print s }')"

if [[ "$exitstatus" =~ ^[0-9]+$ ]]; then
  printf '\nTests exit status: %s\n' "$exitstatus" >&2
else
  printf '\nCould not read tests exit status ("%s")\n' "$exitstatus" >&2
  exitstatus=1
fi

foldable end collect_status

SUMMARIES=$(find . -maxdepth 1 -name "test_*.json")
for summary in ${SUMMARIES}; do
  if [ -f "${summary}" ]; then
    "${GITHUB_ACTION_PATH}/print_test_summary.py" -s "${GITHUB_STEP_SUMMARY}" -j "${summary}"
  fi
done

# Final summary - Don't use a fold, keep it visible
echo -e "\033[1;33mTest Results:\033[0m"
echo -e "$exitfile" | while read result; do
  testgroup=${result%:*}
  status=${result#*:}
  # Print final result for each group of tests
  if [[ "$status" -eq 0 ]]; then
    printf "%20s: \033[1;32mPASS\033[0m\n" "$testgroup"
  else
    printf "%20s: \033[1;31mFAIL\033[0m (returned %s)\n" "$testgroup" "$status"
  fi
done

exit "$exitstatus"
