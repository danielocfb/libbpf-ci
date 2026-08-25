#!/bin/bash

/bin/mount bpffs /sys/fs/bpf -t bpf
ip link set lo up

# These used to be kernel command line arguments, but not every VMM lets
# us append to the command line, so set them from here instead. Writing
# /proc/sys directly avoids depending on sysctl(8) being on $PATH inside
# the guest, and skipping knobs the kernel does not expose keeps this
# working across configurations.
for knob in vm/panic_on_oom \
            kernel/hardlockup_all_cpu_backtrace \
            kernel/softlockup_all_cpu_backtrace; do
	if [ -w "/proc/sys/${knob}" ]; then
		echo 1 > "/proc/sys/${knob}"
	fi
done

# The caller chains the test script on our exit status.
exit 0
