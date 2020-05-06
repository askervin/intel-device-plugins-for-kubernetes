#!/bin/bash

tests=${tests-test.policy.*.cfg}
cleanup=${cleanup-1}
containerd_endpoint=/var/run/containerd/containerd.sock
test_out_dir=$(mktemp --tmpdir -d test.cri-resmgr.critest.XXX)
cri_resmgr_endpoint=$test_out_dir/cri-resmgr.sock

error() {
    echo "error: $@" >&2
    exit 1
}

log() {
    echo "$@"
}

cleanup() {
    if [ "x$cleanup" == "x1" ]; then
        rm -rf $test_out_dir
        log "cleaned up $test_out_dir (disable with cleanup=0)"
    else
        log "not cleaning up $test_out_dir"
    fi
}
trap 'cleanup' EXIT

require_cmd() {
    cmd=$1
    if ! command -v $cmd >/dev/null ; then
        error "required command missing \"${cmd}\", make sure it is in PATH"
    fi
}

detect_cri_endpoint() {
    for cri_endpoint in $containerd_endpoint; do
        if fuser $cri_endpoint >/dev/null 2>&1; then
            echo $cri_endpoint
            break
        fi
    done
}

# Pre-flight checks

# Check that needed commands are available
require_cmd critest
require_cmd cri-resmgr
require_cmd fuser
require_cmd tsl
require_cmd ss

# Check that needed ports are free
if port_listener=$(ss -ltp | grep :8888); then
    error "port 8888 is taken by ${port_listener##*users:}"
fi

# Autodetect or validate cri_endpoint
if [ -z "$cri_endpoint" ]; then
    cri_endpoint=$(detect_cri_endpoint)
    if [ -z "$cri_endpoint" ]; then
        error "backend CRI not found"
    fi
elif ! fuser $cri_endpoint >/dev/null 2>&1; then
    error "no process is listening to $cri_endpoint"
fi
log "using backend CRI endpoint $cri_endpoint"

# Run policy test configurations
for policy in $tests; do
    # Launch cri-resmgr
    cri_resmgr_out_file=$test_out_dir/cri-resmgr.output.tsl
    set -x
    cri-resmgr -force-config $policy -runtime-socket $cri_endpoint -relay-socket $cri_resmgr_endpoint -relay-dir $test_out_dir 2>&1 | tsl -uU -F "%(ts)s cri-resmgr: %(line)s" -o $cri_resmgr_out_file -o stdout &
    set +x
    cri_resmgr_pid=$(pidof cri-resmgr)
    xargs -0 -n 1 echo < /proc/$cri_resmgr_pid/cmdline > $policy.log.cri-resmgr.cmdline
    sleep 5

    # Make sure cri-resmgr is up and running
    if ! grep -q "up and running" $cri_resmgr_out_file; then
        error "cri-resmgr did not become up-and-running"
    fi

    critest -runtime-endpoint unix://$cri_resmgr_endpoint 2>&1 | tsl -uU -F "%(ts)s critest: %(line)s" -o $test_out_dir/critest.cri-resmgr.output.tsl -o stdout
    cat $test_out_dir/*.output.tsl | sort -n > $policy.cri-resmgr.log
    kill $cri_resmgr_pid

    echo test $policy finished
    sleep 5
done

no_cri_resmgr_out_file=$test_out_dir/test.without-cri-resmgr.log
if [ -f $no_cri_resmgr_out_file ]; then
    echo "skipping reference run without cri-resmgr, log already exists: $no_cri_resmgr_out_file"
else
    echo "next: reference run without cri-resmgr"
    critest -runtime-endpoint unix://$cri_endpoint 2>&1 | tsl -uU -F "%(ts)s critest: %(line)s" -o $no_cri_resmgr_out_file -o stdout
fi
