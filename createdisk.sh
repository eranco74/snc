#!/bin/bash

set -x

function get_git_tag {
    GIT_TAG=$(git describe --exact-match HEAD) || GIT_TAG=

    # Based on code from git-version-gen
    # Don't declare a version "dirty" merely because a time stamp has changed
    git update-index --refresh > /dev/null 2>&1

    dirty=`sh -c 'git diff-index --name-only HEAD' 2>/dev/null` || dirty=
    case "$dirty" in
        '') ;;
        *) # Don't build an 'official' version if git tree is dirty
            GIT_TAG=
    esac
    # end of git-version-gen code
}

function create_crc_libvirt_sh {
    destDir=$1

    hostInfo=$(sudo virsh net-dumpxml ${VM_PREFIX} | grep ${VM_PREFIX}-master-0 | sed "s/^[ \t]*//")
    masterMac=$(sudo virsh dumpxml ${VM_PREFIX}-master-0 | grep "mac address" | sed "s/^[ \t]*//")

    sed "s|ReplaceMeWithCorrectVmName|${CRC_VM_NAME}|g" crc_libvirt.template > $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectBaseDomain|${BASE_DOMAIN}|g" $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectHost|$hostInfo|g" $destDir/crc_libvirt.sh
    sed -i "s|ReplaceMeWithCorrectMac|$masterMac|g" $destDir/crc_libvirt.sh

    chmod +x $destDir/crc_libvirt.sh
}

function create_disk_image {
    destDir=$1

    sudo cp /var/lib/libvirt/images/${VM_PREFIX}-master-0 $destDir
    sudo cp /var/lib/libvirt/images/${VM_PREFIX}-base $destDir

    sudo chown $USER:$USER -R $destDir
    ${QEMU_IMG} rebase -b ${VM_PREFIX}-base $destDir/${VM_PREFIX}-master-0
    ${QEMU_IMG} commit $destDir/${VM_PREFIX}-master-0

    # TMPDIR must point at a directory with as much free space as the size of the
    # image we want to sparsify
    TMPDIR=$(pwd)/$destDir ${VIRT_SPARSIFY} $destDir/${VM_PREFIX}-base $destDir/${CRC_VM_NAME}.qcow2
    rm -fr $destDir/.guestfs-*

    rm -fr $destDir/${VM_PREFIX}-master-0 $destDir/${VM_PREFIX}-base
}

function update_json_description {
    srcDir=$1
    destDir=$2

    cat $srcDir/crc-bundle-info.json \
        | ${JQ} '.clusterInfo.sshPrivateKeyFile = "id_rsa_crc"' \
        | ${JQ} '.clusterInfo.kubeConfig = "kubeconfig"' \
        | ${JQ} '.clusterInfo.kubeadminPasswordFile = "kubeadmin-password"' \
        | ${JQ} '.nodes[0].kind[0] = "master"' \
        | ${JQ} '.nodes[0].kind[1] = "worker"' \
        | ${JQ} ".nodes[0].hostname = \"${VM_PREFIX}-master-0\"" \
        | ${JQ} ".nodes[0].diskImage = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} ".storage.diskImages[0].name = \"${CRC_VM_NAME}.qcow2\"" \
        | ${JQ} '.storage.diskImages[0].format = "qcow2"' \
        >$destDir/crc-bundle-info.json
}

# CRC_VM_NAME: short VM name to use in crc_libvirt.sh
# BASE_DOMAIN: domain used for the cluster
# VM_PREFIX: full VM name with the random string generated by openshift-installer
CRC_VM_NAME=${CRC_VM_NAME:-crc}
BASE_DOMAIN=${CRC_BASE_DOMAIN:-testing}
JQ=${JQ:-jq}
VIRT_SPARSIFY=${VIRT_SPARSIFY:-virt-sparsify}
QEMU_IMG=${QEMU_IMG:-qemu-img}

if [[ $# -ne 1 ]]; then
   echo "You need to provide the running cluster directory to copy kubeconfig"
   exit 1
fi

if ! which ${JQ}; then
    sudo yum -y install /usr/bin/jq
fi

if ! which ${VIRT_SPARSIFY}; then
    sudo yum -y install /usr/bin/virt-sparsify
fi

if ! which ${QEMU_IMG}; then
    sudo yum -y install /usr/bin/qemu-img
fi

get_git_tag

if [ -z ${GIT_TAG} ]; then
    tarballDirectory="crc_libvirt_$(date --iso-8601)"
else
    tarballDirectory="crc_libvirt_${GIT_TAG}"
fi
echo "${tarballDirectory}"

mkdir $tarballDirectory

random_string=$(sudo virsh list --all | grep -oP "(?<=${CRC_VM_NAME}-).*(?=-master-0)")
if [ -z $random_string ]; then
    echo "Could not find virtual machine created by snc.sh"
    exit 1;
fi
VM_PREFIX=${CRC_VM_NAME}-${random_string}

# Shutdown the instance
sudo virsh shutdown ${VM_PREFIX}-master-0

create_crc_libvirt_sh $tarballDirectory

create_disk_image $tarballDirectory

# Copy the kubeconfig and kubeadm password file
cp $1/auth/kube* $tarballDirectory/

# Copy the master public key
cp id_rsa_crc $tarballDirectory/
chmod 400 $tarballDirectory/id_rsa_crc

update_json_description $1 $tarballDirectory

tar cJSf $tarballDirectory.tar.xz $tarballDirectory