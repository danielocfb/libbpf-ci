#!/bin/bash

# The VM's entry point. vmsh exec's us directly, with no shell in
# between, so whatever the test script needs in place has to be set up
# here. vmsh's own init has already mounted /proc, /sys, bpffs, debugfs,
# tracefs and cgroup2, and brought up loopback.
#
# Usage: guest-entry.sh <test-script> [test-runner...]

# /run is the host's, shared in over virtiofs, and virtiofs performs
# writes as the invoking host user -- which cannot write a root-owned
# /run. The selftests need to: network_helpers.c runs "ip netns add",
# which creates /run/netns. Give the guest its own /run, which also keeps
# it from leaving state behind on the host. vmtest's init did the same.
#
# Not via mount(8): it is setuid root, and vmsh runs us in a user
# namespace where the host's root is unmapped, so the binary appears
# setuid *nobody* and exec'ing it drops privileges instead of granting
# them. Call the syscall directly, which is all iproute2 and the
# selftests themselves do.
if ! python3 -c '
import ctypes, os, sys
libc = ctypes.CDLL("libc.so.6", use_errno=True)
MS_NOSUID, MS_NODEV = 2, 4
if libc.mount(b"tmpfs", b"/run", b"tmpfs", MS_NOSUID | MS_NODEV, None) != 0:
    err = ctypes.get_errno()
    sys.exit("mount(2) tmpfs on /run: %s" % os.strerror(err))
'; then
	echo "guest-entry.sh: could not give the guest a private /run" >&2
	exit 2
fi

# These used to be kernel command line arguments, but vmsh does not let
# us append to the command line. Writing /proc/sys directly avoids
# depending on sysctl(8) being on $PATH inside the guest, and skipping
# knobs the kernel does not expose keeps this working across
# configurations.
for knob in vm/panic_on_oom \
            kernel/hardlockup_all_cpu_backtrace \
            kernel/softlockup_all_cpu_backtrace; do
	if [ -w "/proc/sys/${knob}" ]; then
		echo 1 > "/proc/sys/${knob}"
	fi
done

exec "$@"
