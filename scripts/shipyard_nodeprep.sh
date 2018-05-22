#!/usr/bin/env bash

# shellcheck disable=SC1091

set -e
set -o pipefail

# version consts
DOCKER_CE_VERSION_DEBIAN=18.03.1
DOCKER_CE_VERSION_CENTOS=18.03.1
DOCKER_CE_VERSION_SLES=17.09.1
NVIDIA_DOCKER_VERSION=2.0.3
SINGULARITY_VERSION=2.5.0

# consts
DOCKER_CE_PACKAGE_DEBIAN="docker-ce=${DOCKER_CE_VERSION_DEBIAN}~ce-0~"
DOCKER_CE_PACKAGE_CENTOS="docker-ce-${DOCKER_CE_VERSION_CENTOS}.ce-1.el7.centos"
DOCKER_CE_PACKAGE_SLES="docker-${DOCKER_CE_VERSION_SLES}_ce-257.3"
NVIDIA_DOCKER_PACKAGE_UBUNTU="nvidia-docker2=${NVIDIA_DOCKER_VERSION}+docker${DOCKER_CE_VERSION_DEBIAN}-1"
NVIDIA_DOCKER_PACKAGE_CENTOS="nvidia-docker2-${NVIDIA_DOCKER_VERSION}-1.docker${DOCKER_CE_VERSION_CENTOS}.ce"
MOUNTS_PATH=$AZ_BATCH_NODE_ROOT_DIR/mounts
VOLATILE_PATH=$AZ_BATCH_NODE_ROOT_DIR/volatile

# status file consts
lisinstalled=${VOLATILE_PATH}/.batch_shipyard_lis_installed
nodeprepfinished=${VOLATILE_PATH}/.batch_shipyard_node_prep_finished
cascadefailed=${VOLATILE_PATH}/.batch_shipyard_cascade_failed

log() {
    local level=$1
    shift
    echo "$(date -u -Ins) - $level - $*"
}

# dump uname immediately
uname -ar

# try to get /etc/lsb-release
if [ -e /etc/lsb-release ]; then
    . /etc/lsb-release
else
    if [ -e /etc/os-release ]; then
        . /etc/os-release
        DISTRIB_ID=$ID
        DISTRIB_RELEASE=$VERSION_ID
    fi
fi
if [ -z ${DISTRIB_ID+x} ] || [ -z ${DISTRIB_RELEASE+x} ]; then
    log ERROR "Unknown DISTRIB_ID or DISTRIB_RELEASE."
    exit 1
fi
DISTRIB_ID=${DISTRIB_ID,,}
DISTRIB_RELEASE=${DISTRIB_RELEASE,,}

# set distribution specific vars
PACKAGER=
USER_MOUNTPOINT=/mnt/resource
SYSTEMD_PATH=/lib/systemd/system
if [ "$DISTRIB_ID" == "ubuntu" ]; then
    PACKAGER=apt
    USER_MOUNTPOINT=/mnt
elif [ "$DISTRIB_ID" == "debian" ]; then
    PACKAGER=apt
elif [[ $DISTRIB_ID == centos* ]] || [ "$DISTRIB_ID" == "rhel" ]; then
    PACKAGER=yum
else
    PACKAGER=zypper
    SYSTEMD_PATH=/usr/lib/systemd/system
fi
if [ "$PACKAGER" == "apt" ]; then
    export DEBIAN_FRONTEND=noninteractive
fi

# globals
azureblob=0
azurefile=0
blobxferversion=latest
block=
cascadecontainer=0
custom_image=0
encrypted=
hpnssh=0
gluster_on_compute=0
gpu=
lis=
networkopt=0
native_mode=0
p2p=
p2penabled=0
prefix=
sc_args=
shipyardversion=

# process command line options
while getopts "h?abcde:fg:l:m:np:s:tuv:wx:" opt; do
    case "$opt" in
        h|\?)
            echo "shipyard_nodeprep.sh parameters"
            echo ""
            echo "-a mount azurefile shares"
            echo "-b block until resources loaded"
            echo "-c mount azureblob containers"
            echo "-d use docker container for cascade"
            echo "-e [thumbprint] encrypted credentials with cert"
            echo "-f set up glusterfs on compute"
            echo "-g [nv-series:driver file:nvidia docker pkg] gpu support"
            echo "-l [lis pkg] LIS package install"
            echo "-m [type:scid] mount storage cluster"
            echo "-n native mode"
            echo "-p [prefix] storage container prefix"
            echo "-s [enabled:non-p2p concurrent download:seed bias:compression] p2p sharing"
            echo "-t optimize network TCP settings"
            echo "-u custom image"
            echo "-v [version] batch-shipyard version"
            echo "-w install openssh-hpn"
            echo "-x [blobxfer version] blobxfer version"
            echo ""
            exit 1
            ;;
        a)
            azurefile=1
            ;;
        b)
            block=${SHIPYARD_CONTAINER_IMAGES_PRELOAD}
            ;;
        c)
            azureblob=1
            ;;
        d)
            cascadecontainer=1
            ;;
        e)
            encrypted=${OPTARG,,}
            ;;
        f)
            gluster_on_compute=1
            ;;
        g)
            gpu=$OPTARG
            ;;
        l)
            lis=$OPTARG
            ;;
        m)
            IFS=',' read -ra sc_args <<< "${OPTARG,,}"
            ;;
        n)
            native_mode=1
            ;;
        p)
            prefix="--prefix $OPTARG"
            ;;
        s)
            p2p=${OPTARG,,}
            IFS=':' read -ra p2pflags <<< "$p2p"
            if [ "${p2pflags[0]}" == "true" ]; then
                p2penabled=1
            else
                p2penabled=0
            fi
            ;;
        t)
            networkopt=1
            ;;
        u)
            custom_image=1
            ;;
        v)
            shipyardversion=$OPTARG
            ;;
        w)
            hpnssh=1
            ;;
        x)
            blobxferversion=$OPTARG
            ;;
    esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift
# check versions
if [ -z "$shipyardversion" ]; then
    log ERROR "batch-shipyard version not specified"
    exit 1
fi
if [ -z "$blobxferversion" ]; then
    log ERROR "blobxfer version not specified"
    exit 1
fi

save_startup_to_volatile() {
    set +e
    touch "${VOLATILE_PATH}"/startup/.save
    set -e
}

check_for_buggy_ntfs_mount() {
    # Check to ensure sdb1 mount is not mounted as ntfs
    set +e
    mount | grep /dev/sdb1 | grep fuseblk
    local rc=$?
    set -e
    if [ $rc -eq 0 ]; then
        log ERROR "/dev/sdb1 temp disk is mounted as fuseblk/ntfs"
        exit 1
    fi
}

optimize_tcp_network_settings() {
    # optimize network TCP settings
    if [ "$1" -eq 1 ]; then
        local sysctlfile=/etc/sysctl.d/60-azure-batch-shipyard.conf
        if [ ! -e $sysctlfile ] || [ ! -s $sysctlfile ]; then
cat > $sysctlfile << EOF
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.netdev_max_backlog=30000
net.ipv4.tcp_max_syn_backlog=80960
net.ipv4.tcp_mem=16777216 16777216 16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_abort_on_overflow=1
net.ipv4.route.flush=1
EOF
        fi
        if [ "$PACKAGER" == "apt" ]; then
            service procps reload
        else
            sysctl -p
        fi
    fi
    # set up hpn-ssh
    if [ "$2" -eq 1 ]; then
        ./shipyard_hpnssh.sh "$DISTRIB_ID" "$DISTRIB_RELEASE"
    fi
}

download_file() {
    log INFO "Downloading: $1"
    local retries=10
    set +e
    while [ $retries -gt 0 ]; do
        if curl -fSsLO "$1"; then
            break
        fi
        retries=$((retries-1))
        if [ $retries -eq 0 ]; then
            log ERROR "Could not download: $1"
            exit 1
        fi
        sleep 1
    done
    set -e
}

add_repo() {
    local url=$1
    set +e
    local retries=120
    local rc
    while [ $retries -gt 0 ]; do
        if [ "$PACKAGER" == "apt" ]; then
            curl -fSsL "$url" | apt-key add -
            rc=$?
        elif [ "$PACKAGER" == "yum" ]; then
            yum-config-manager --add-repo "$url"
            rc=$?
        elif [ "$PACKAGER" == "zypper" ]; then
            zypper addrepo "$url"
            rc=$?
        fi
        if [ $rc -eq 0 ]; then
            break
        fi
        retries=$((retries-1))
        if [ $retries -eq 0 ]; then
            log ERROR "Could not add repo: $url"
            exit 1
        fi
        sleep 1
    done
    set -e
}

refresh_package_index() {
    set +e
    local retries=120
    local rc
    while [ $retries -gt 0 ]; do
        if [ "$PACKAGER" == "apt" ]; then
            apt-get update
            rc=$?
        elif [ "$PACKAGER" == "yum" ]; then
            yum makecache -y fast
            rc=$?
        elif [ "$PACKAGER" == "zypper" ]; then
            zypper -n --gpg-auto-import-keys ref
            rc=$?
        fi
        if [ $rc -eq 0 ]; then
            break
        fi
        retries=$((retries-1))
        if [ $retries -eq 0 ]; then
            log ERROR "Could not update package index"
            exit 1
        fi
        sleep 1
    done
    set -e
}

install_packages() {
    set +e
    local retries=120
    local rc
    while [ $retries -gt 0 ]; do
        if [ "$PACKAGER" == "apt" ]; then
            apt-get install -y -q -o Dpkg::Options::="--force-confnew" --no-install-recommends "$@"
            rc=$?
        elif [ "$PACKAGER" == "yum" ]; then
            yum install -y "$@"
            rc=$?
        elif [ "$PACKAGER" == "zypper" ]; then
            zypper -n in "$@"
            rc=$?
        fi
        if [ $rc -eq 0 ]; then
            break
        fi
        retries=$((retries-1))
        if [ $retries -eq 0 ]; then
            log ERROR "Could not install packages ($PACKAGER): $*"
            exit 1
        fi
        sleep 1
    done
    set -e
}

install_local_packages() {
    set +e
    local retries=120
    local rc
    while [ $retries -gt 0 ]; do
        if [ "$PACKAGER" == "apt" ]; then
            dpkg -i "$@"
            rc=$?
        else
            rpm -Uvh --nodeps "$@"
            rc=$?
        fi
        if [ $rc -eq 0 ]; then
            break
        fi
        retries=$((retries-1))
        if [ $retries -eq 0 ]; then
            log ERROR "Could not install local packages: $*"
            exit 1
        fi
        sleep 1
    done
    set -e
}

blacklist_kernel_upgrade() {
    if [ "$DISTRIB_ID" != "ubuntu" ]; then
        log DEBUG "No kernel upgrade blacklist required on $DISTRIB_ID $DISTRIB_RELEASE"
        return
    fi
    set +e
    grep linux-azure /etc/apt/apt.conf.d/50unattended-upgrades
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        sed -i "/^Unattended-Upgrade::Package-Blacklist {/a\"linux-azure\";\\n\"linux-cloud-tools-azure\";\\n\"linux-headers-azure\";\\n\"linux-image-azure\";\\n\"linux-tools-azure\";" /etc/apt/apt.conf.d/50unattended-upgrades
        log INFO "Added linux-azure to package blacklist for unattended upgrades"
    fi
}

check_for_nvidia_docker() {
    set +e
    if ! nvidia-docker version; then
        log ERROR "nvidia-docker2 not installed"
        exit 1
    fi
    set -e
}

check_for_nvidia_driver_on_custom_or_native() {
    set +e
    local out
    out=$(lsmod)
    echo "$out" | grep -i nvidia > /dev/null
    local rc=$?
    set -e
    echo "$out"
    if [ $rc -ne 0 ]; then
        log ERROR "No Nvidia drivers detected!"
        exit 1
    else
        check_for_nvidia_docker
    fi
}

enable_nvidia_persistence_mode() {
    nvidia-persistenced --user root
    nvidia-smi -pm 1
}

check_for_nvidia_on_custom_or_native() {
    log INFO "Checking for Nvidia Hardware"
    # first check for card
    set +e
    local out
    out=$(lspci)
    echo "$out" | grep -i nvidia > /dev/null
    local rc=$?
    set -e
    echo "$out"
    if [ $rc -ne 0 ]; then
        log INFO "No Nvidia card(s) detected!"
    else
        check_for_nvidia_driver_on_custom_or_native
        # prevent kernel upgrades from breaking driver
        blacklist_kernel_upgrade
        enable_nvidia_persistence_mode
        nvidia-smi
    fi
}

ensure_nvidia_driver_installed() {
    check_for_nvidia_card
    # ensure that nvidia drivers are loaded
    set +e
    local out
    out=$(lsmod)
    echo "$out" | grep -i nvidia > /dev/null
    local rc=$?
    set -e
    echo "$out"
    if [ $rc -ne 0 ]; then
        log WARNING "Nvidia driver not present!"
        install_nvidia_software
    else
        log INFO "Nvidia driver detected"
        enable_nvidia_persistence_mode
        nvidia-smi
    fi
}

check_for_nvidia_card() {
    set +e
    local out
    out=$(lspci)
    echo "$out" | grep -i nvidia > /dev/null
    local rc=$?
    set -e
    echo "$out"
    if [ $rc -ne 0 ]; then
        log ERROR "No Nvidia card(s) detected!"
        exit 1
    fi
}

install_lis() {
    if [ -z "$lis" ]; then
        log INFO "LIS installation not required"
        return
    fi
    if [ -f "$lisinstalled" ]; then
        log INFO "Assuming LIS installed with file presence"
        return
    fi
    # lis install is controlled by variable presence driven from fleet
    log DEBUG "Installing LIS"
    tar zxpf "$lis"
    pushd LISISO
    ./install.sh
    popd
    touch "$lisinstalled"
    rm -rf LISISO "$lis"
    log INFO "LIS installed, rebooting"
    reboot
}

install_nvidia_software() {
    log INFO "Installing Nvidia Software"
    # check for nvidia card
    check_for_nvidia_card
    # split arg into two
    IFS=':' read -ra GPUARGS <<< "$gpu"
    local is_viz=${GPUARGS[0]}
    local nvdriver=${GPUARGS[1]}
    # remove nouveau
    set +e
    rmmod nouveau
    set -e
    # purge nouveau off system
    if [ "$DISTRIB_ID" == "ubuntu" ]; then
        apt-get --purge remove xserver-xorg-video-nouveau xserver-xorg-video-nouveau-hwe-16.04
    elif [[ $DISTRIB_ID == centos* ]]; then
        yum erase -y xorg-x11-drv-nouveau
    else
        log ERROR "unsupported distribution for nvidia/GPU: $DISTRIB_ID $DISTRIB_RELEASE"
        exit 1
    fi
    # blacklist nouveau from being loaded if rebooted
    if [ "$DISTRIB_ID" == "ubuntu" ]; then
cat > /etc/modprobe.d/blacklist-nouveau.conf << EOF
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
    elif [[ $DISTRIB_ID == centos* ]]; then
cat >> /etc/modprobe.d/blacklist.conf << EOF
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
    dracut /boot/initramfs-"$(uname -r)".img "$(uname -r)" --force
    fi
    # get development essentials for nvidia driver
    if [ "$DISTRIB_ID" == "ubuntu" ]; then
        install_packages build-essential
    elif [[ $DISTRIB_ID == centos* ]]; then
        local kernel_devel_package
        local centos_ver
        kernel_devel_package="kernel-devel-$(uname -r)"
        centos_ver=$(cut -d' ' -f 4 /etc/centos-release)
        if [[ "$centos_ver" == 7.3.* ]]; then
            download_file http://vault.centos.org/7.3.1611/updates/x86_64/Packages/"${kernel_devel_package}".rpm
            install_local_packages "${kernel_devel_package}".rpm
        elif [[ "$centos_ver" == 7.4.* ]]; then
            download_file http://mirror.centos.org/centos/7.4.1708/updates/x86_64/Packages/"${kernel_devel_package}".rpm
            install_local_packages "${kernel_devel_package}".rpm
        elif [[ $DISTRIB_ID == "centos-hpc" ]] || [[ "$centos_ver" == 7.* ]]; then
            install_packages "${kernel_devel_package}"
        else
            log ERROR "CentOS $DISTRIB_RELEASE not supported for GPU"
            exit 1
        fi
        install_packages gcc binutils make
    fi
    # get additional dependency if NV-series VMs
    if [ "$is_viz" == "True" ]; then
        if [ "$DISTRIB_ID" == "ubuntu" ]; then
            install_packages xserver-xorg-dev
        elif [[ $DISTRIB_ID == centos* ]]; then
            install_packages xorg-x11-server-devel
        fi
    fi
    # install driver
    ./"${nvdriver}" -s
    # add flag to config for GRID driver
    if [ "$is_viz" == "True" ]; then
        cp /etc/nvidia/gridd.conf.template /etc/nvidia/gridd.conf
        echo "IgnoreSP=TRUE" >> /etc/nvidia/gridd.conf
    fi
    # enable persistence daemon (and mode)
    enable_nvidia_persistence_mode
    # install nvidia-docker
    if [ "$DISTRIB_ID" == "ubuntu" ]; then
        add_repo https://nvidia.github.io/nvidia-docker/gpgkey
        curl -fSsL https://nvidia.github.io/nvidia-docker/ubuntu16.04/amd64/nvidia-docker.list | \
            tee /etc/apt/sources.list.d/nvidia-docker.list
    elif [[ $DISTRIB_ID == centos* ]]; then
        add_repo https://nvidia.github.io/nvidia-docker/centos7/x86_64/nvidia-docker.repo
    fi
    refresh_package_index
    if [ "$DISTRIB_ID" == "ubuntu" ]; then
        install_packages "$NVIDIA_DOCKER_PACKAGE_UBUNTU"
    elif [[ $DISTRIB_ID == centos* ]]; then
        install_packages "$NVIDIA_DOCKER_PACKAGE_CENTOS"
    fi
    # merge daemon configs if necessary
    set +e
    grep \"data-root\" /etc/docker/daemon.json
    local rc=$?
    set -e
    if [ $rc -ne 0 ]; then
        systemctl stop docker.service
        log DEBUG "data-root not detected in Docker daemon.json"
        if [ "$DISTRIB_ID" == "ubuntu" ]; then
            python -c "import json;a=json.load(open('/etc/docker/daemon.json.dpkg-old'));b=json.load(open('/etc/docker/daemon.json'));a.update(b);f=open('/etc/docker/daemon.json','w');json.dump(a,f);f.close();"
            rm -f /etc/docker/daemon.json.dpkg-old
        elif [[ $DISTRIB_ID == centos* ]]; then
            echo "{ \"data-root\": \"$USER_MOUNTPOINT/docker\", \"hosts\": [ \"unix:///var/run/docker.sock\", \"tcp://127.0.0.1:2375\" ] }" > /etc/docker/daemon.json.merge
            python -c "import json;a=json.load(open('/etc/docker/daemon.json.merge'));b=json.load(open('/etc/docker/daemon.json'));a.update(b);f=open('/etc/docker/daemon.json','w');json.dump(a,f);f.close();"
            rm -f /etc/docker/daemon.json.merge
        fi
        # ensure no options are specified after dockerd
        sed -i 's|^ExecStart=/usr/bin/dockerd.*|ExecStart=/usr/bin/dockerd|' "${SYSTEMD_PATH}"/docker.service
        systemctl daemon-reload
        systemctl start docker.service
    else
        systemctl restart docker.service
    fi
    systemctl --no-pager status docker.service
    nvidia-docker version
    set +e
    local rootdir
    rootdir=$(docker info | grep "Docker Root Dir" | cut -d' ' -f 4)
    if echo "$rootdir" | grep "$USER_MOUNTPOINT" > /dev/null; then
        log DEBUG "Docker root dir: $rootdir"
    else
        log ERROR "Docker root dir $rootdir not within $USER_MOUNTPOINT"
        exit 1
    fi
    set -e
    nvidia-smi
}

mount_azurefile_share() {
    log INFO "Mounting Azure File Shares"
    chmod +x azurefile-mount.sh
    ./azurefile-mount.sh
    chmod 700 azurefile-mount.sh
    chown root:root azurefile-mount.sh
}

mount_azureblob_container() {
    log INFO "Mounting Azure Blob Containers"
    if [[ "$DISTRIB_ID" == "ubuntu" ]] && [[ $DISTRIB_RELEASE == 16.04* ]]; then
        debfile=packages-microsoft-prod.deb
        if [ ! -f ${debfile} ]; then
            download_file https://packages.microsoft.com/config/ubuntu/16.04/${debfile}
            install_local_packages ${debfile}
            refresh_package_index
            install_packages blobfuse
        fi
    elif [[ "$DISTRIB_ID" == "rhel" ]] || [[ $DISTRIB_ID == centos* ]]; then
        rpmfile=packages-microsoft-prod.rpm
        if [ ! -f ${rpmfile} ]; then
            download_file https://packages.microsoft.com/config/rhel/7/${rpmfile}
            install_local_packages ${rpmfile}
            refresh_package_index
            install_packages blobfuse
        fi
    else
        echo "ERROR: unsupported distribution for Azure blob: $DISTRIB_ID $DISTRIB_RELEASE"
        exit 1
    fi
    chmod +x azureblob-mount.sh
    ./azureblob-mount.sh
    chmod 700 azureblob-mount.sh
    chown root:root azureblob-mount.sh
    chmod 600 ./*.cfg
    chown root:root ./*.cfg
}

docker_pull_image() {
    local image=$1
    log DEBUG "Pulling Docker Image: $1"
    set +e
    local retries=60
    while [ $retries -gt 0 ]; do
        local pull_out
        pull_out=$(docker pull "$image" 2>&1)
        local rc=$?
        if [ $rc -eq 0 ]; then
            echo "$pull_out"
            break
        fi
        # non-zero exit code: check if pull output has toomanyrequests,
        # connection resets, or image config error
        local tmr
        tmr=$(grep 'toomanyrequests' <<<"$pull_out")
        local crbp
        crbp=$(grep 'connection reset by peer' <<<"$pull_out")
        local epic
        epic=$(grep 'error pulling image configuration' <<<"$pull_out")
        if [[ ! -z "$tmr" ]] || [[ ! -z "$crbp" ]] || [[ ! -z "$epic" ]]; then
            log WARNING "will retry: $pull_out"
        else
            log ERROR "$pull_out"
            exit $rc
        fi
        retries=$((retries-1))
        if [ $retries -le 0 ]; then
            log ERROR "Could not pull docker image: $image"
            exit $rc
        fi
        sleep $((RANDOM % 5 + 1))s
    done
    set -e
}

singularity_basedir=
singularity_setup() {
    local offer
    local sku
    singularity_basedir="${USER_MOUNTPOINT}"/singularity
    if [[ "$DISTRIB_ID" == "ubuntu" ]] && [[ $DISTRIB_RELEASE == 16.04* ]]; then
        offer=ubuntu
        sku=16.04
    elif ( [[ "$DISTRIB_ID" == "rhel" ]] || [[ $DISTRIB_ID == centos* ]] ) && [[ $DISTRIB_RELEASE == 7* ]]; then
        offer=centos
        sku=7
    fi
    if [ -z "$offer" ] || [ -z "$sku" ]; then
        log WARNING "Singularity not supported on $DISTRIB_ID $DISTRIB_RELEASE"
        return
    fi
    log DEBUG "Setting up Singularity for $offer $sku"
    # fetch docker image for singularity bits
    local di=alfpark/singularity:${SINGULARITY_VERSION}-${offer}-${sku}
    docker_pull_image $di
    mkdir -p /opt/singularity
    docker run --rm -v /opt/singularity:/opt/singularity $di \
        /bin/sh -c 'cp -r /singularity/* /opt/singularity'
    # symlink for global exec
    ln -sf /opt/singularity/bin/singularity /usr/bin/singularity
    # fix perms
    chown root.root /opt/singularity/libexec/singularity/bin/*
    chmod 4755 /opt/singularity/libexec/singularity/bin/*-suid
    # prep singularity root/container dir
    mkdir -p $singularity_basedir/mnt/container
    mkdir -p $singularity_basedir/mnt/final
    mkdir -p $singularity_basedir/mnt/overlay
    mkdir -p $singularity_basedir/mnt/session
    chmod 755 $singularity_basedir
    chmod 755 $singularity_basedir/mnt
    chmod 755 $singularity_basedir/mnt/container
    chmod 755 $singularity_basedir/mnt/final
    chmod 755 $singularity_basedir/mnt/overlay
    chmod 755 $singularity_basedir/mnt/session
    # create singularity tmp/cache paths
    mkdir -p $singularity_basedir/tmp
    mkdir -p $singularity_basedir/cache/docker
    mkdir -p $singularity_basedir/cache/metadata
    chmod 775 $singularity_basedir/tmp
    chmod 775 $singularity_basedir/cache
    chmod 775 $singularity_basedir/cache/docker
    chmod 775 $singularity_basedir/cache/metadata
    # set proper ownership
    chown -R _azbatch:_azbatchgrp $singularity_basedir/tmp
    chown -R _azbatch:_azbatchgrp $singularity_basedir/cache
    # selftest
    singularity selftest
    # remove docker image
    docker rmi $di
}

process_fstab_entry() {
    local desc=$1
    local mountpoint=$2
    local fstab_entry=$3
    log INFO "Creating host directory for $desc at $mountpoint"
    mkdir -p "$mountpoint"
    chmod 777 "$mountpoint"
    echo "INFO: Adding $mountpoint to fstab"
    echo "$fstab_entry" >> /etc/fstab
    tail -n1 /etc/fstab
    echo "INFO: Mounting $mountpoint"
    local START
    START=$(date -u +"%s")
    set +e
    while :
    do
        if mount "$mountpoint"; then
            break
        else
            local NOW
            NOW=$(date -u +"%s")
            local DIFF=$(((NOW-START)/60))
            # fail after 5 minutes of attempts
            if [ $DIFF -ge 5 ]; then
                echo "ERROR: Could not mount $desc on $mountpoint"
                exit 1
            fi
            sleep 1
        fi
    done
    set -e
    log INFO "$mountpoint mounted."
}

mount_storage_clusters() {
    if [ ! -z "$sc_args" ]; then
        log DEBUG "Mounting storage clusters"
        # eval and split fstab var to expand vars (this is ok since it is set by shipyard)
        fstab_mounts=$(eval echo "$SHIPYARD_STORAGE_CLUSTER_FSTAB")
        IFS='#' read -ra fstabs <<< "$fstab_mounts"
        i=0
        for sc_arg in "${sc_args[@]}"; do
            IFS=':' read -ra sc <<< "$sc_arg"
            mount "${MOUNTS_PATH}"/"${sc[1]}"
        done
        log INFO "Storage clusters mounted"
    fi
}

process_storage_clusters() {
    if [ ! -z "$sc_args" ]; then
        log DEBUG "Processing storage clusters"
        # eval and split fstab var to expand vars (this is ok since it is set by shipyard)
        fstab_mounts=$(eval echo "$SHIPYARD_STORAGE_CLUSTER_FSTAB")
        IFS='#' read -ra fstabs <<< "$fstab_mounts"
        i=0
        for sc_arg in "${sc_args[@]}"; do
            IFS=':' read -ra sc <<< "$sc_arg"
            fstab_entry="${fstabs[$i]}"
            process_fstab_entry "$sc_arg" "$MOUNTS_PATH/${sc[1]}" "$fstab_entry"
            i=$((i + 1))
        done
        log INFO "Storage clusters mounted"
    fi
}

mount_custom_fstab() {
    if [ ! -z "$SHIPYARD_CUSTOM_MOUNTS_FSTAB" ]; then
        log DEBUG "Mounting custom mounts via fstab"
        IFS='#' read -ra fstab_mounts <<< "$SHIPYARD_CUSTOM_MOUNTS_FSTAB"
        for fstab in "${fstab_mounts[@]}"; do
            # eval and split fstab var to expand vars
            fstab_entry=$(eval echo "$fstab")
            IFS=' ' read -ra parts <<< "$fstab_entry"
            mount "${parts[1]}"
        done
        log INFO "Custom mounts via fstab mounted"
    fi
}

process_custom_fstab() {
    if [ ! -z "$SHIPYARD_CUSTOM_MOUNTS_FSTAB" ]; then
        log DEBUG "Processing custom mounts via fstab"
        IFS='#' read -ra fstab_mounts <<< "$SHIPYARD_CUSTOM_MOUNTS_FSTAB"
        for fstab in "${fstab_mounts[@]}"; do
            # eval and split fstab var to expand vars
            fstab_entry=$(eval echo "$fstab")
            IFS=' ' read -ra parts <<< "$fstab_entry"
            process_fstab_entry "${parts[2]}" "${parts[1]}" "$fstab_entry"
        done
        log INFO "Custom mounts via fstab mounted"
    fi
}

decrypt_encrypted_credentials() {
    # convert pfx to pem
    pfxfile=$AZ_BATCH_CERTIFICATES_DIR/sha1-$encrypted.pfx
    privatekey=$AZ_BATCH_CERTIFICATES_DIR/key.pem
    openssl pkcs12 -in "$pfxfile" -out "$privatekey" -nodes -password file:"${pfxfile}".pw
    # remove pfx-related files
    rm -f "$pfxfile" "${pfxfile}".pw
    # decrypt creds
    SHIPYARD_STORAGE_ENV=$(echo "$SHIPYARD_STORAGE_ENV" | base64 -d | openssl rsautl -decrypt -inkey "$privatekey")
    if [ ! -z ${DOCKER_LOGIN_USERNAME+x} ]; then
        DOCKER_LOGIN_PASSWORD=$(echo "$DOCKER_LOGIN_PASSWORD" | base64 -d | openssl rsautl -decrypt -inkey "$privatekey")
    fi
}

check_for_docker_host_engine() {
    set +e
    # start docker service
    systemctl start docker.service
    systemctl --no-pager status docker.service
    if ! docker version; then
        log ERROR "Docker not installed"
        exit 1
    fi
    set -e
    docker info
}

check_docker_root_dir() {
    set +e
    local rootdir
    rootdir=$(docker info | grep "Docker Root Dir" | cut -d' ' -f 4)
    set -e
    log DEBUG "Docker root dir: $rootdir"
    if [ -z "$rootdir" ]; then
        log ERROR "Could not determine docker root dir"
    elif [[ "$rootdir" == ${USER_MOUNTPOINT}/* ]]; then
        log INFO "Docker root dir is within ephemeral temp disk"
    else
        log WARNING "Docker root dir is on the OS disk. Performance may be impacted."
    fi
}

install_docker_host_engine() {
    log DEBUG "Installing Docker Host Engine"
    # set vars
    local srvstart="systemctl start docker.service"
    local srvstop="systemctl stop docker.service"
    local srvdisable="systemctl disable docker.service"
    local srvstatus="systemctl --no-pager status docker.service"
    if [ "$PACKAGER" == "apt" ]; then
        local repo=https://download.docker.com/linux/"${DISTRIB_ID}"
        local gpgkey="${repo}"/gpg
        local dockerversion="${DOCKER_CE_PACKAGE_DEBIAN}${DISTRIB_ID}"
        local prereq_pkgs="apt-transport-https ca-certificates curl gnupg2 software-properties-common"
    elif [ "$PACKAGER" == "yum" ]; then
        local repo=https://download.docker.com/linux/centos/docker-ce.repo
        local dockerversion="${DOCKER_CE_PACKAGE_CENTOS}"
        local prereq_pkgs="yum-utils device-mapper-persistent-data lvm2"
    elif [ "$PACKAGER" == "zypper" ]; then
        if [[ "$DISTRIB_RELEASE" == 12-sp3* ]]; then
            local repodir=SLE_12_SP3
        fi
        local repo="http://download.opensuse.org/repositories/Virtualization:containers/${repodir}/Virtualization:containers.repo"
        local dockerversion="${DOCKER_CE_PACKAGE_SLES}"
    fi
    # refresh package index
    refresh_package_index
    # install required software first
    # shellcheck disable=SC2086
    install_packages $prereq_pkgs
    if [ "$PACKAGER" == "apt" ]; then
        # add gpgkey for repo
        add_repo "$gpgkey"
        # add repo
        add-apt-repository "deb [arch=amd64] $repo $(lsb_release -cs) stable"
    else
        add_repo "$repo"
    fi
    # refresh index
    refresh_package_index
    # install docker engine
    install_packages "$dockerversion"
    # disable docker from auto-start due to temp disk issues
    $srvstop
    $srvdisable
    # ensure docker daemon modifications are idempotent
    rm -rf /var/lib/docker
    mkdir -p /etc/docker
    if [ "$PACKAGER" == "apt" ]; then
        echo "{ \"data-root\": \"$USER_MOUNTPOINT/docker\", \"hosts\": [ \"fd://\", \"unix:///var/run/docker.sock\", \"tcp://127.0.0.1:2375\" ] }" > /etc/docker/daemon.json
    else
        echo "{ \"data-root\": \"$USER_MOUNTPOINT/docker\", \"hosts\": [ \"unix:///var/run/docker.sock\", \"tcp://127.0.0.1:2375\" ] }" > /etc/docker/daemon.json
    fi
    # ensure no options are specified after dockerd
    sed -i 's|^ExecStart=/usr/bin/dockerd.*|ExecStart=/usr/bin/dockerd|' "${SYSTEMD_PATH}"/docker.service
    systemctl daemon-reload
    $srvstart
    $srvstatus
    docker info
    log INFO "Docker Host Engine installed"
}

check_for_glusterfs_on_compute() {
    set +e
    if ! gluster; then
        log ERROR "gluster client not installed"
        exit 1
    fi
    if ! glusterfs -V; then
        log ERROR "gluster server not installed"
        exit 1
    fi
    set -e
}

install_glusterfs_on_compute() {
    local gfsstart="systemctl start glusterd"
    local gfsenable="systemctl enable glusterd"
    if [ "$PACKAGER" == "apt" ]; then
        if [[ "$DISTRIB_RELEASE" == 16.04* ]] || [[ "$DISTRIB_RELEASE" == 8* ]]; then
            gfsstart="systemctl start glusterfs-server"
            gfsenable="systemctl enable glusterfs-server"
        fi
    elif [ "$PACKAGER" == "zypper" ]; then
        if [[ "$DISTRIB_RELEASE" == 12-sp3* ]]; then
            local repodir=SLE_12_SP3
        fi
        local repo="http://download.opensuse.org/repositories/filesystems/${repodir}/filesystems.repo"
    fi
    if [ "$PACKAGER" == "apt" ]; then
        install_packages glusterfs-server
    elif [ "$PACKAGER" == "yum" ]; then
        install_packages epel-release centos-release-gluster38
        sed -i -e "s/enabled=1/enabled=0/g" /etc/yum.repos.d/CentOS-Gluster-3.8.repo
        install_packages --enablerepo=centos-gluster38,epel glusterfs-server
    elif [ "$PACKAGER" == "zypper" ]; then
        add_repo "$repo"
        "$PACKAGER" -n --gpg-auto-import-keys ref
        install_packages glusterfs
    fi
    $gfsenable
    $gfsstart
    # create brick directory
    mkdir -p "${USER_MOUNTPOINT}"/gluster
}

check_for_storage_cluster_software() {
    local rc
    if [ ! -z "$sc_args" ]; then
        for sc_arg in "${sc_args[@]}"; do
            IFS=':' read -ra sc <<< "$sc_arg"
            local server_type=${sc[0]}
            if [ "$server_type" == "nfs" ]; then
                set +e
                mount.nfs4 -V
                rc=$?
                set -e
            elif [ "$server_type" == "glusterfs" ]; then
                set +e
                glusterfs -V
                rc=$?
                set -e
            else
                log ERROR "Unknown file server type ${sc[0]} for ${sc[1]}"
                exit 1
            fi
        done
    fi
    if [ $rc -ne 0 ]; then
        log ERROR "required storage cluster software to mount $sc_args not installed"
        exit 1
    fi
}

install_storage_cluster_dependencies() {
    if [ -z "$sc_args" ]; then
        return
    fi
    log DEBUG "Installing storage cluster dependencies"
    if [ "$PACKAGER" == "zypper" ]; then
        if [[ "$DISTRIB_RELEASE" == 12-sp3* ]]; then
            local repodir=SLE_12_SP3
        fi
        local repo="http://download.opensuse.org/repositories/filesystems/${repodir}/filesystems.repo"
    fi
    for sc_arg in "${sc_args[@]}"; do
        IFS=':' read -ra sc <<< "$sc_arg"
        server_type=${sc[0]}
        if [ "$server_type" == "nfs" ]; then
            if [ "$PACKAGER" == "apt" ]; then
                install_packages nfs-common nfs4-acl-tools
            elif [ "$PACKAGER" == "yum" ] ; then
                install_packages nfs-utils nfs4-acl-tools
                systemctl enable rpcbind
                systemctl start rpcbind
            elif [ "$PACKAGER" == "zypper" ]; then
                install_packages nfs-client nfs4-acl-tools
                systemctl enable rpcbind
                systemctl start rpcbind
            fi
        elif [ "$server_type" == "glusterfs" ]; then
            if [ "$PACKAGER" == "apt" ]; then
                install_packages glusterfs-client acl
            elif [ "$PACKAGER" == "yum" ] ; then
                install_packages epel-release centos-release-gluster38
                sed -i -e "s/enabled=1/enabled=0/g" /etc/yum.repos.d/CentOS-Gluster-3.8.repo
                install_packages --enablerepo=centos-gluster38,epel glusterfs-server acl
            elif [ "$PACKAGER" == "zypper" ]; then
                add_repo "$repo"
                "$PACKAGER" -n --gpg-auto-import-keys ref
                install_packages glusterfs acl
            fi
        else
            log ERROR "Unknown file server type ${sc[0]} for ${sc[1]}"
            exit 1
        fi
    done
    log INFO "Storage cluster dependencies installed"
}

install_cascade_dependencies() {
    if [ $cascadecontainer -ne 0 ]; then
        return
    fi
    log DEBUG "Installing dependencies for cascade on host"
    # install azure storage python dependency
    install_packages build-essential libssl-dev libffi-dev libpython3-dev python3-dev python3-pip
    pip3 install --no-cache-dir --upgrade pip
    pip3 install --no-cache-dir --upgrade wheel setuptools
    pip3 install --no-cache-dir azure-cosmosdb-table==1.0.2 azure-storage-blob==1.1.0
    # install cascade dependencies
    if [ $p2penabled -eq 1 ]; then
        install_packages python3-libtorrent pigz
    fi
    log INFO "Cascade on host dependencies installed"
}

install_intel_mpi() {
    if [ -e /dev/infiniband/uverbs0 ]; then
        log INFO "IB device found"
        if [[ "$DISTRIB_ID" == sles* ]]; then
            log DEBUG "Installing Intel MPI"
            install_packages lsb
            install_local_packages /opt/intelMPI/intel_mpi_packages/*.rpm
            mkdir -p /opt/intel/compilers_and_libraries/linux
            ln -sf /opt/intel/impi/5.0.3.048 /opt/intel/compilers_and_libraries/linux/mpi
            log INFO "Intel MPI installed"
        fi
    else
        log INFO "IB device not found"
    fi
}

spawn_cascade_process() {
    # touch cascade failed file, this will be removed once cascade is successful
    if [ $cascadecontainer -ne 0 ]; then
        touch "$cascadefailed"
    fi
    set +e
    local cascadepid
    local envfile
    if [ $cascadecontainer -eq 1 ]; then
        local detached
        if [ $p2penabled -eq 1 ]; then
            detached="-d"
        else
            detached="--rm"
        fi
        # store docker cascade start
        if command -v python3 > /dev/null 2>&1; then
            drpstart=$(python3 -c 'import datetime;print(datetime.datetime.utcnow().timestamp())')
        else
            drpstart=$(python -c 'import datetime;import time;print(time.mktime(datetime.datetime.utcnow().timetuple()))')
        fi
        # create env file
        envfile=.cascade_envfile
cat > $envfile << EOF
PYTHONASYNCIODEBUG=1
prefix=$prefix
ipaddress=$ipaddress
offer=$DISTRIB_ID
sku=$DISTRIB_RELEASE
npstart=$npstart
drpstart=$drpstart
p2p=$p2p
$(env | grep SHIPYARD_)
$(env | grep AZ_BATCH_)
$(env | grep DOCKER_LOGIN_)
$(env | grep SINGULARITY_)
EOF
        chmod 600 $envfile
        # pull image
        docker_pull_image alfpark/batch-shipyard:"${shipyardversion}"-cascade
        # set singularity options
        local singularity_binds
        if [ ! -z $singularity_basedir ]; then
            singularity_binds="\
                -v $singularity_basedir:$singularity_basedir \
                -v $singularity_basedir/mnt:/var/lib/singularity/mnt"
        fi
        # launch container
        log DEBUG "Starting Cascade"
        # shellcheck disable=SC2086
        docker run $detached --net=host --env-file $envfile \
            -v /var/run/docker.sock:/var/run/docker.sock \
            -v /etc/passwd:/etc/passwd:ro \
            -v /etc/group:/etc/group:ro \
            ${singularity_binds} \
            -v "$AZ_BATCH_NODE_ROOT_DIR":"$AZ_BATCH_NODE_ROOT_DIR" \
            -w "$AZ_BATCH_TASK_WORKING_DIR" \
            -p 6881-6891:6881-6891 -p 6881-6891:6881-6891/udp \
            alfpark/batch-shipyard:"${shipyardversion}"-cascade &
        cascadepid=$!
    else
        # add timings
        if [ ! -z ${SHIPYARD_TIMING+x} ]; then
            # backfill node prep start
            ./perf.py nodeprep start "$prefix" --ts "$npstart" --message "offer=$DISTRIB_ID,sku=$DISTRIB_RELEASE"
            # mark node prep finished
            ./perf.py nodeprep end "$prefix"
            # mark start cascade
            ./perf.py cascade start "$prefix"
        fi
        log DEBUG "Starting Cascade"
        PYTHONASYNCIODEBUG=1 ./cascade.py "$p2p" --ipaddress "$ipaddress" "$prefix" &
        cascadepid=$!
    fi

    # if not in p2p mode, then wait for cascade exit
    if [ $p2penabled -eq 0 ]; then
        local rc
        wait $cascadepid
        rc=$?
        if [ $rc -ne 0 ]; then
            log ERROR "cascade exited with non-zero exit code: $rc"
            rm -f "$nodeprepfinished"
            exit $rc
        fi
    fi
    set -e

    # remove cascade failed file
    rm -f "$cascadefailed"
}

block_for_container_images() {
    # wait for images via cascade
    "${AZ_BATCH_TASK_WORKING_DIR}"/wait_for_images.sh "$block"
    # clean up cascade env file if block
    if [ ! -z "$block" ]; then
        if [ $cascadecontainer -eq 1 ]; then
            rm -f $envfile
        fi
    fi
}

install_and_start_node_exporter() {
    if [ -z "${PROM_NODE_EXPORTER_PORT}" ]; then
        log INFO "Prometheus node exporter disabled."
        return
    else
        log DEBUG "Installing Prometheus node exporter"
    fi
    # install
    tar zxvpf node_exporter.tar.gz
    mv node_exporter-*.linux-amd64/node_exporter .
    rm -rf node_exporter-*.linux-amd64 node_exporter.tar.gz
    chmod +x node_exporter
    # start
    local ib
    local nfs
    ib="--no-collector.infiniband"
    nfs="--no-collector.nfs"
    if [ -e /dev/infiniband/uverbs0 ]; then
        ib="--collector.infiniband"
    fi
    if [ ! -z "$sc_args" ]; then
        for sc_arg in "${sc_args[@]}"; do
            IFS=':' read -ra sc <<< "$sc_arg"
            if [ "${sc[0]}" == "nfs" ]; then
                nfs="--collector.nfs"
                break
            fi
        done
    fi
    local pneo
    if [ ! -z "${PROM_NODE_EXPORTER_OPTIONS}" ]; then
        IFS=',' read -ra pneo <<< "$PROM_NODE_EXPORTER_OPTIONS"
    else
        pneo=
    fi
    "${AZ_BATCH_TASK_WORKING_DIR}"/node_exporter \
        "$ib" "$nfs" \
        --no-collector.textfile \
        --no-collector.mdadm \
        --no-collector.wifi \
        --no-collector.xfs \
        --no-collector.zfs \
        --web.listen-address=":${PROM_NODE_EXPORTER_PORT}" \
        --collector.filesystem.ignored-mount-points="${USER_MOUNTPOINT}/docker" \
        "${pneo[@]}" &
    log INFO "Prometheus node exporter enabled."
}

install_and_start_cadvisor() {
    if [ -z "${PROM_CADVISOR_PORT}" ]; then
        log INFO "Prometheus cAdvisor disabled."
        return
    else
        log INFO "Installing Prometheus cAdvisor"
    fi
    # install
    chmod +x cadvisor
    # start
    local pcao
    if [ ! -z "${PROM_CADVISOR_OPTIONS}" ]; then
        IFS=',' read -ra pcao <<< "$PROM_CADVISOR_OPTIONS"
    else
        pcao=
    fi
    "${AZ_BATCH_TASK_WORKING_DIR}"/cadvisor \
        -port "${PROM_CADVISOR_PORT}" \
        "${pcao[@]}" &
    log INFO "Prometheus cAdvisor enabled."
}

log INFO "Prep start"
echo "Configuration:"
echo "--------------"
echo "Custom image: $custom_image"
echo "Native mode: $native_mode"
echo "OS Distribution: $DISTRIB_ID $DISTRIB_RELEASE"
echo "Batch Shipyard version: $shipyardversion"
echo "Blobxfer version: $blobxferversion"
echo "Singularity version: $SINGULARITY_VERSION"
echo "User mountpoint: $USER_MOUNTPOINT"
echo "Mount path: $MOUNTS_PATH"
echo "Prometheus: NE=$PROM_NODE_EXPORTER_PORT,$PROM_NODE_EXPORTER_OPTIONS CA=$PROM_CADVISOR_PORT,$PROM_CADVISOR_OPTIONS"
echo "Network optimization: $networkopt"
echo "Encryption cert thumbprint: $encrypted"
echo "Storage cluster mount: ${sc_args[*]}"
echo "Custom mount: $SHIPYARD_CUSTOM_MOUNTS_FSTAB"
echo "Install LIS: $lis"
echo "GPU: $gpu"
echo "Azure Blob: $azureblob"
echo "Azure File: $azurefile"
echo "GlusterFS on compute: $gluster_on_compute"
echo "HPN-SSH: $hpnssh"
echo "Cascade via container: $cascadecontainer"
echo "P2P: $p2penabled"
echo "Block on images: $block"
echo ""

# set python env vars
export LC_ALL=en_US.UTF-8

# store node prep start
if command -v python3 > /dev/null 2>&1; then
    npstart=$(python3 -c 'import datetime;print(datetime.datetime.utcnow().timestamp())')
else
    npstart=$(python -c 'import datetime;import time;print(time.mktime(datetime.datetime.utcnow().timetuple()))')
fi

# check sdb1 mount
check_for_buggy_ntfs_mount

# save startup stderr/stdout
save_startup_to_volatile

# install LIS if required first (lspci won't work on certain distros without it)
install_lis

# create shared mount points
mkdir -p "$MOUNTS_PATH"

# decrypt encrypted creds
if [ ! -z "$encrypted" ]; then
    decrypt_encrypted_credentials
fi

# set iptables rules
if [ $p2penabled -eq 1 ]; then
    # disable DHT connection tracking
    iptables -t raw -I PREROUTING -p udp --dport 6881 -j CT --notrack
    iptables -t raw -I OUTPUT -p udp --sport 6881 -j CT --notrack
fi

# custom or native mode should have docker/nvidia installed
if [ $custom_image -eq 1 ] || [ $native_mode -eq 1 ]; then
    check_for_docker_host_engine
    check_docker_root_dir
    # check for nvidia card/driver/docker
    check_for_nvidia_on_custom_or_native
fi

# mount azure resources (this must be done every boot)
if [ $azurefile -eq 1 ]; then
    mount_azurefile_share
fi
if [ $azureblob -eq 1 ]; then
    mount_azureblob_container
fi

# check if we're coming up from a reboot
if [ -f "$cascadefailed" ]; then
    log ERROR "$cascadefailed file exists, assuming cascade failure during node prep"
    exit 1
elif [ -f "$nodeprepfinished" ]; then
    # start prometheus collectors
    install_and_start_node_exporter
    install_and_start_cadvisor
    # mount any storage clusters
    if [ ! -z "$sc_args" ]; then
        # eval and split fstab var to expand vars (this is ok since it is set by shipyard)
        fstab_mounts=$(eval echo "$SHIPYARD_STORAGE_CLUSTER_FSTAB")
        IFS='#' read -ra fstabs <<< "$fstab_mounts"
        i=0
        for sc_arg in "${sc_args[@]}"; do
            IFS=':' read -ra sc <<< "$sc_arg"
            mount "${MOUNTS_PATH}"/"${sc[1]}"
        done
    fi
    # mount any custom mounts
    if [ ! -z "$SHIPYARD_CUSTOM_MOUNTS_FSTAB" ]; then
        IFS='#' read -ra fstab_mounts <<< "$SHIPYARD_CUSTOM_MOUNTS_FSTAB"
        for fstab in "${fstab_mounts[@]}"; do
            # eval and split fstab var to expand vars
            fstab_entry=$(eval echo "$fstab")
            IFS=' ' read -ra parts <<< "$fstab_entry"
            mount "${parts[1]}"
        done
    fi
    # non-native mode checks
    if [ "$custom_image" -eq 0 ] && [ "$native_mode" -eq 0 ]; then
        # start docker engine
        check_for_docker_host_engine
        # ensure nvidia software has been installed
        if [ ! -z "$gpu" ]; then
            ensure_nvidia_driver_installed
        fi
    fi
    log INFO "$nodeprepfinished file exists, assuming successful completion of node prep"
    exit 0
fi

# get ip address of eth0
ipaddress=$(ip addr list eth0 | grep "inet " | cut -d' ' -f6 | cut -d/ -f1)

# network setup
set +e
optimize_tcp_network_settings $networkopt $hpnssh
set -e

# set sudoers to not require tty
sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

# install prometheus collectors
install_and_start_node_exporter
install_and_start_cadvisor

# install docker host engine on non-native
if [ $custom_image -eq 0 ] && [ $native_mode -eq 0 ]; then
    install_docker_host_engine
fi

# install gpu related items
if [ ! -z "$gpu" ] && ( [ "$DISTRIB_ID" == "ubuntu" ] || [ "$DISTRIB_ID" == "centos" ] ); then
    if [ $custom_image -eq 0 ] && [ $native_mode -eq 0 ]; then
        install_nvidia_software
    fi
fi

# check or set up glusterfs on compute
if [ $gluster_on_compute -eq 1 ]; then
    if [ $custom_image -eq 1 ]; then
        check_for_glusterfs_on_compute
    else
        install_glusterfs_on_compute
    fi
fi

# check or install dependencies for storage cluster mount
if [ ! -z "$sc_args" ]; then
    if [ $custom_image -eq 1 ]; then
        check_for_storage_cluster_software
    else
        install_storage_cluster_dependencies
    fi
fi

# install dependencies if not using cascade container
if [ $custom_image -eq 0 ] && [ $native_mode -eq 0 ]; then
    install_cascade_dependencies
fi

# install intel mpi if available
if [ $custom_image -eq 0 ] && [ $native_mode -eq 0 ]; then
    install_intel_mpi
fi

# retrieve required docker images
docker_pull_image alfpark/blobxfer:"${blobxferversion}"
docker_pull_image alfpark/batch-shipyard:"${shipyardversion}"-cargo

# login to registry servers (do not specify -e as creds have been decrypted)
./registry_login.sh

# set up singularity
if [ $native_mode -eq 0 ]; then
    singularity_setup
    if [ -f singularity-registry-login ]; then
        . singularity-registry-login
    fi
fi

# process and mount any storage clusters
process_storage_clusters

# process and mount any custom mounts
process_custom_fstab

# touch node prep finished file to preserve idempotency
touch "$nodeprepfinished"

# execute cascade
if [ $native_mode -eq 0 ]; then
    spawn_cascade_process
    # block for images if necessary
    block_for_container_images
fi

log INFO "Prep completed"
