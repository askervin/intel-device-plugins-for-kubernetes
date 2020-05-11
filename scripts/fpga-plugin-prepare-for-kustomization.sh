#!/bin/bash

# This script prepares fpga_plugin ready for full deployment.

namespace=""

usage() {
    echo "Usage: $(basename $0) [-n NAMESPACE]"
    exit 0
}

while getopts "hn:" opt; do
    case "${opt}" in
	h)
	    usage
	    ;;
	n)
	    namespace=${OPTARG}
	    ;;
	*)
	    usage
	    ;;
    esac
done
shift $((OPTIND-1))

service="intel-fpga-webhook-svc"
secret="intel-fpga-webhook-certs"

script_dir="$(realpath $(dirname $0))"
srcroot="$(realpath ${script_dir}/..)"

kustomize_secret_dir="${srcroot}/deployments/fpga_admissionwebhook/base/${secret}-secret"

mkdir -p "${kustomize_secret_dir}"

# Create signed cert files to kustomize_secret_dir
if ! ${script_dir}/webhook-create-signed-cert.sh --output-dir ${kustomize_secret_dir} --service $service; then
    echo "error: failed to create signed certificate to ${kustomize_secret_dir}" >&2
    exit 1
fi

# Modify namespaces if a namespace is defined
if [ -n "${namespace}" ]; then
    for yaml in $(find ${srcroot}/deployments/fpga* -name '*.yaml' | egrep '/base/|/overlays/'); do
	if grep -q 'namespace:' $yaml; then
	    sed -i "s/namespace: .*/namespace: $namespace/g" $yaml;
	    modified="${modified}\n- ${yaml#$srcroot/}"
	fi
    done
    createopts="${createopts} -n $namespace"
    kubectl create namespace $namespace 2>/dev/null
else
    modified=""
    createopts=""
fi

# Print summary
echo ""
echo "Created for kustomization:"
echo "- ${kustomize_secret_dir}"
echo ""
echo -n "Modified for special namespace:"
printf "${modified}\n"
echo ""
echo "Next steps:"
echo "    - Install FPGA plugin in the af mode:"
echo "      $ kubectl create${createopts} -k deployments/fpga_plugin/overlays/af"
echo "    - Install FPGA plugin in the region mode:"
echo "      $ kubectl create${createopts} -k deployments/fpga_plugin/overlays/region"
echo "    - To uninstall FPGA plugin, use \"delete\" instead of \"create\"."
