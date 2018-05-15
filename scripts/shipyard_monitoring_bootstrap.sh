#!/usr/bin/env bash

# shellcheck disable=SC1091

set -e
set -o pipefail

# version consts
DOCKER_CE_VERSION_DEBIAN=18.05.0

# consts
# TODO switch version back to stable
DOCKER_CE_PACKAGE_DEBIAN="docker-ce=${DOCKER_CE_VERSION_DEBIAN}~ce~3-0~"
SHIPYARD_CONF_FILE=/etc/batch-shipyard.json

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
aad_cloud=
storage_account=
table_name=
shipyardversion=

# process command line options
while getopts "h?a:s:v:" opt; do
    case "$opt" in
        h|\?)
            echo "shipyard_monitoring_bootstrap.sh parameters"
            echo ""
            echo "-a [aad cloud type] AAD cloud type for MSI"
            echo "-s [storage account:table name] monitoring table"
            echo "-v [version] batch-shipyard version"
            echo ""
            exit 1
            ;;
        a)
            aad_cloud=${OPTARG,,}
            ;;
        s)
            IFS=':' read -ra ss <<< "${OPTARG,,}"
            storage_account=${ss[0]}
            table_name=${ss[1]}
            ;;
        v)
            shipyardversion=$OPTARG
            ;;
    esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift
# check required params
if [ -z "$aad_cloud" ]; then
    log ERROR "AAD cloud type not specified"
    exit 1
fi

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

install_docker_host_engine() {
    log DEBUG "Installing Docker Host Engine"
    # set vars
    local srvstop="systemctl stop docker.service"
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
        # TODO switch to stable once ready
        add-apt-repository "deb [arch=amd64] $repo $(lsb_release -cs) edge"
    else
        add_repo "$repo"
    fi
    # refresh index
    refresh_package_index
    # install docker engine
    install_packages "$dockerversion"
    systemctl start docker.service
    systemctl enable docker.service
    systemctl --no-pager status docker.service
    docker info
    log INFO "Docker Host Engine installed"
}

log INFO "Bootstrap start"

# check sdb1 mount
check_for_buggy_ntfs_mount

# set sudoers to not require tty
sed -i 's/^Defaults[ ]*requiretty/# Defaults requiretty/g' /etc/sudoers

# write shipyard config
cat > $SHIPYARD_CONF_FILE << EOF
{
    "aad_cloud": $aad_cloud,
    "storage": {
        "account": $storage_account,
        "table_name": $table_name,
    }
}
EOF

# install docker host engine
install_docker_host_engine

# TODO start docker image with auto restart (--rm -d --restart always -v $SHIPYARD_CONF_FILE:$SHIPYARD_CONF_FILE:ro)
# TODO use docker compose instead with prometheus/grafana, requires systemd unit file

log INFO "Bootstrap completed"
