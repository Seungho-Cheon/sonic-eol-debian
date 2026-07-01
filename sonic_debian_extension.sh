#!/bin/bash
## This script is to automate loading of vendor specific docker images
## and installation of configuration files and vendor specific packages
## to debian file system.
##
## USAGE:
##   ./sonic_debian_extension.sh FILESYSTEM_ROOT PLATFORM_DIR
## PARAMETERS:
##   FILESYSTEM_ROOT
##          Path to debian file system root directory

FILESYSTEM_ROOT=$1
[ -n "$FILESYSTEM_ROOT" ] || {
    echo "Error: no or empty FILESYSTEM_ROOT argument"
    exit 1
}

PLATFORM_DIR=$2
[ -n "$PLATFORM_DIR" ] || {
    echo "Error: no or empty PLATFORM_DIR argument"
    exit 1
}

IMAGE_DISTRO=$3
[ -n "$IMAGE_DISTRO" ] || {
    echo "Error: no or empty IMAGE_DISTRO argument"
    exit 1
}

## Enable debug output for script
set -x -e

CONFIGURED_ARCH=$([ -f .arch ] && cat .arch || echo amd64)

. functions.sh
BUILD_SCRIPTS_DIR=files/build_scripts
BUILD_TEMPLATES=files/build_templates
IMAGE_CONFIGS=files/image_config
SCRIPTS_DIR=files/scripts
DOCKER_SCRIPTS_DIR=files/docker

DOCKER_CTL_DIR=/usr/lib/docker/
DOCKER_CTL_SCRIPT="$DOCKER_CTL_DIR/docker.sh"

# Define target fold macro
FILESYSTEM_ROOT_USR="$FILESYSTEM_ROOT/usr"
FILESYSTEM_ROOT_USR_LIB="$FILESYSTEM_ROOT/usr/lib/"
FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM="$FILESYSTEM_ROOT_USR_LIB/systemd/system"
FILESYSTEM_ROOT_USR_SHARE="$FILESYSTEM_ROOT_USR/share"
FILESYSTEM_ROOT_USR_SHARE_SONIC="$FILESYSTEM_ROOT_USR_SHARE/sonic"
FILESYSTEM_ROOT_USR_SHARE_SONIC_SCRIPTS="$FILESYSTEM_ROOT_USR_SHARE_SONIC/scripts"
FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES="$FILESYSTEM_ROOT_USR_SHARE_SONIC/templates"
FILESYSTEM_ROOT_USR_SHARE_SONIC_FIRMWARE="$FILESYSTEM_ROOT_USR_SHARE_SONIC/firmware"
FILESYSTEM_ROOT_ETC="$FILESYSTEM_ROOT/etc"
FILESYSTEM_ROOT_ETC_SONIC="$FILESYSTEM_ROOT_ETC/sonic"

GENERATED_SERVICE_FILE="$FILESYSTEM_ROOT/etc/sonic/generated_services.conf"

clean_sys() {
    sudo chroot $FILESYSTEM_ROOT umount /sys/fs/cgroup/*            \
                                        /sys/fs/cgroup              \
                                        /sys || true
}
trap_push clean_sys
sudo LANG=C chroot $FILESYSTEM_ROOT mount sysfs /sys -t sysfs

sudo bash -c "echo \"DOCKER_OPTS=\"--storage-driver=overlay2\"\" >> $FILESYSTEM_ROOT/etc/default/docker"
# Copy docker start script to be able to start docker in chroot
sudo mkdir -p "$FILESYSTEM_ROOT/$DOCKER_CTL_DIR"
sudo cp $DOCKER_SCRIPTS_DIR/docker "$FILESYSTEM_ROOT/$DOCKER_CTL_SCRIPT"
if [[ $MULTIARCH_QEMU_ENVIRON == y  || $CROSS_BUILD_ENVIRON == y ]]; then
    DOCKER_HOST="unix:///dockerfs/var/run/docker.sock"
    SONIC_NATIVE_DOCKERD_FOR_DOCKERFS_PID="cat `pwd`/dockerfs/var/run/docker.pid"
else
    sudo chroot $FILESYSTEM_ROOT $DOCKER_CTL_SCRIPT start
fi

# Update apt's snapshot of its repos
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get update

# Install efitools to support secure upgrade
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install efitools
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install mokutil

# Apply environtment configuration files
sudo cp $IMAGE_CONFIGS/environment/environment $FILESYSTEM_ROOT/etc/
sudo cp $IMAGE_CONFIGS/environment/motd $FILESYSTEM_ROOT/etc/

# Create all needed directories
sudo mkdir -p $FILESYSTEM_ROOT/etc/sonic/
sudo mkdir -p $FILESYSTEM_ROOT/etc/modprobe.d/
sudo mkdir -p $FILESYSTEM_ROOT/var/cache/sonic/
sudo mkdir -p $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
sudo mkdir -p $FILESYSTEM_ROOT_USR_SHARE_SONIC_FIRMWARE/
# This is needed for Stretch and might not be needed for Buster where Linux create this directory by default.
# Keeping it generic. It should not harm anyways.
sudo mkdir -p $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

# Install a patched version of ifupdown2  (and its dependencies via 'apt-get -y install -f')
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/ifupdown2_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f

# Install a patched version of ntp  (and its dependencies via 'apt-get -y install -f')
sudo dpkg --root=$FILESYSTEM_ROOT --force-confdef --force-confold -i $debs_path/ntp_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y \
    -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" install -f

# Install dependencies for SONiC config engine
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install \
    python3-dev

# Install j2cli for handling jinja template
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install "j2cli==0.3.10"

# Install Python client for Redis
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install "redis==3.5.3"

# Install redis-dump-load Python 3 package
# Note: the scripts will be overwritten by corresponding Python 2 package
REDIS_DUMP_LOAD_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/redis_dump_load-1.1-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/redis_dump_load-1.1-py3-none-any.whl $FILESYSTEM_ROOT/$REDIS_DUMP_LOAD_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $REDIS_DUMP_LOAD_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$REDIS_DUMP_LOAD_PY3_WHEEL_NAME

# Install Python module for psutil
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install psutil

# Install Python module for ipaddr
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install ipaddr

# Install Python module for grpcio and grpcio-toole
if [[ $CONFIGURED_ARCH == amd64 ]]; then
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install "grpcio==1.39.0"
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install "grpcio-tools==1.39.0"
fi

# Install sonic-py-common Python 3 package
SONIC_PY_COMMON_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_py_common-1.0-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_py_common-1.0-py3-none-any.whl $FILESYSTEM_ROOT/$SONIC_PY_COMMON_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $SONIC_PY_COMMON_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$SONIC_PY_COMMON_PY3_WHEEL_NAME

# Install dependency pkgs for SONiC config engine Python 2 package
if [[ $CONFIGURED_ARCH == armhf || $CONFIGURED_ARCH == arm64 ]]; then
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install libxslt-dev libz-dev
fi

# Install sonic-yang-models Python 3 package, install dependencies
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libyang_*.deb
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libyang-cpp_*.deb
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/python3-yang_*.deb
SONIC_YANG_MODEL_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_yang_models-1.0-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_yang_models-1.0-py3-none-any.whl $FILESYSTEM_ROOT/$SONIC_YANG_MODEL_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $SONIC_YANG_MODEL_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$SONIC_YANG_MODEL_PY3_WHEEL_NAME

# Install sonic-yang-mgmt Python3 package
SONIC_YANG_MGMT_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_yang_mgmt-1.0-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_yang_mgmt-1.0-py3-none-any.whl $FILESYSTEM_ROOT/$SONIC_YANG_MGMT_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $SONIC_YANG_MGMT_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$SONIC_YANG_MGMT_PY3_WHEEL_NAME

# For sonic-config-engine Python 3 package
# Install pyangbind here, outside sonic-config-engine dependencies, as pyangbind causes enum34 to be installed.
# Then immediately uninstall enum34, as enum34 should not be installed for Python >= 3.4, as it causes a
# conflict with the new 'enum' module in the standard library
# https://github.com/robshakir/pyangbind/issues/232
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install pyangbind==0.8.1
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 uninstall -y enum34

# Install SONiC config engine Python 3 package
CONFIG_ENGINE_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_config_engine-1.0-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_config_engine-1.0-py3-none-any.whl $FILESYSTEM_ROOT/$CONFIG_ENGINE_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $CONFIG_ENGINE_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$CONFIG_ENGINE_PY3_WHEEL_NAME


# Install sonic-platform-common Python 3 package
PLATFORM_COMMON_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_platform_common-1.0-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_platform_common-1.0-py3-none-any.whl $FILESYSTEM_ROOT/$PLATFORM_COMMON_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $PLATFORM_COMMON_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$PLATFORM_COMMON_PY3_WHEEL_NAME


# Install pddf-platform-api-base Python 3 package
PLATFORM_PDDF_COMMON_PY3_WHEEL_NAME=$(basename "target/python-wheels/bullseye/sonic_platform_pddf_common-1.0-py3-none-any.whl")
sudo cp "target/python-wheels/bullseye/sonic_platform_pddf_common-1.0-py3-none-any.whl" $FILESYSTEM_ROOT/$PLATFORM_PDDF_COMMON_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $PLATFORM_PDDF_COMMON_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$PLATFORM_PDDF_COMMON_PY3_WHEEL_NAME





# Install system-health Python 3 package
SYSTEM_HEALTH_PY3_WHEEL_NAME=$(basename "target/python-wheels/bullseye/system_health-1.0-py3-none-any.whl")
sudo cp "target/python-wheels/bullseye/system_health-1.0-py3-none-any.whl" $FILESYSTEM_ROOT/$SYSTEM_HEALTH_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $SYSTEM_HEALTH_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$SYSTEM_HEALTH_PY3_WHEEL_NAME

# Install prerequisites needed for installing the Python m2crypto package, used by sonic-utilities
# These packages can be uninstalled after intallation
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install build-essential libssl-dev swig

# Install prerequisites needed for using the Python m2crypto package, used by sonic-utilities
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install openssl

# install libffi-dev to match utilities' dependency.
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install libffi-dev

# Install SONiC Utilities Python package
SONIC_UTILITIES_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_utilities-1.2-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_utilities-1.2-py3-none-any.whl $FILESYSTEM_ROOT/$SONIC_UTILITIES_PY3_WHEEL_NAME
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $SONIC_UTILITIES_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$SONIC_UTILITIES_PY3_WHEEL_NAME

# Install sonic-utilities data files (and any dependencies via 'apt-get -y install -f')
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/sonic-utilities-data_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f

# Install customized bash version to patch bash plugin support.
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/bash_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f

# sonic-utilities-data installs bash-completion as a dependency. However, it is disabled by default
# in bash.bashrc, so we copy a version of the file with it enabled here.
sudo cp -f $IMAGE_CONFIGS/bash/bash.bashrc $FILESYSTEM_ROOT/etc/

# Install readline's initialization file
sudo cp -f $IMAGE_CONFIGS/readline/inputrc $FILESYSTEM_ROOT/etc/

# Install prerequisites needed for installing the dependent Python packages of sonic-host-services
# These packages can be uninstalled after installation
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install libcairo2-dev libdbus-1-dev libgirepository1.0-dev libsystemd-dev pkg-config

# Mark runtime dependencies as manually installed to avoid them being auto-removed while uninstalling build dependencies
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-mark manual gir1.2-glib-2.0 libdbus-1-3 libgirepository-1.0-1 libsystemd0 python3-dbus

# Install systemd-python for SONiC host services
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install systemd-python

# Install SONiC host services package
SONIC_HOST_SERVICES_PY3_WHEEL_NAME=$(basename target/python-wheels/bullseye/sonic_host_services-1.0-py3-none-any.whl)
sudo cp target/python-wheels/bullseye/sonic_host_services-1.0-py3-none-any.whl $FILESYSTEM_ROOT/$SONIC_HOST_SERVICES_PY3_WHEEL_NAME
# Install bullseye-compatible PyGObject first (latest 3.54 needs girepository-2.0, bullseye has 1.0)
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install 'PyGObject==3.42.2'
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install $SONIC_HOST_SERVICES_PY3_WHEEL_NAME
sudo rm -rf $FILESYSTEM_ROOT/$SONIC_HOST_SERVICES_PY3_WHEEL_NAME

# Install SONiC host services data files (and any dependencies via 'apt-get -y install -f')
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/sonic-host-services-data_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f




if [[ -z "broadcom" || -n "broadcom" && $TARGET_MACHINE == "broadcom" ]]; then
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/opennsl-modules_10.1.0.0_amd64.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
fi

if [[ -z "broadcom-dnx" || -n "broadcom-dnx" && $TARGET_MACHINE == "broadcom-dnx" ]]; then
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/opennsl-modules-dnx_7.1.0.0_amd64.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
fi


# Install SONiC Device Data  (and its dependencies via 'apt-get -y install -f')
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/sonic-device-data_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f

# package for supporting password hardening
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install libpam-cracklib

# Install pam-tacplus and nss-tacplus
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libtac2_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libpam-tacplus_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libnss-tacplus_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
# Install bash-tacplus
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/bash-tacplus_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
# Install audisp-tacplus
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/audisp-tacplus_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
# Disable tacplus by default
sudo LANG=C chroot $FILESYSTEM_ROOT pam-auth-update --remove tacplus
sudo sed -i -e '/^passwd/s/ tacplus//' $FILESYSTEM_ROOT/etc/nsswitch.conf

# Install pam-radius-auth and nss-radius
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libpam-radius-auth_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/libnss-radius_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
# Disable radius by default
# radius does not have any profiles
#sudo LANG=C chroot $FILESYSTEM_ROOT pam-auth-update --remove radius tacplus
sudo sed -i -e '/^passwd/s/ radius//' $FILESYSTEM_ROOT/etc/nsswitch.conf

# Install a custom version of kdump-tools  (and its dependencies via 'apt-get -y install -f')
if [ "$TARGET_BOOTLOADER" != uboot ]; then
sudo DEBIAN_FRONTEND=noninteractive dpkg --root=$FILESYSTEM_ROOT -i $debs_path/kdump-tools_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true chroot $FILESYSTEM_ROOT apt-get -q --no-install-suggests --no-install-recommends install
    cat $IMAGE_CONFIGS/kdump/kdump-tools | sudo tee -a $FILESYSTEM_ROOT/etc/default/kdump-tools > /dev/null

for kernel_release in $(ls $FILESYSTEM_ROOT/lib/modules/); do
	sudo LANG=C chroot $FILESYSTEM_ROOT /etc/kernel/postinst.d/kdump-tools $kernel_release > /dev/null 2>&1
	sudo LANG=C chroot $FILESYSTEM_ROOT kdump-config symlinks $kernel_release
done
fi

# Install python-swss-common package and all its dependent packages
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libnl-3-200_3.5.0-1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libnl-genl-3-200_3.5.0-1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libnl-route-3-200_3.5.0-1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libnl-nf-3-200_3.5.0-1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libnl-cli-3-200_3.5.0-1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libyang_1.0.73_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/libswsscommon_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i  || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/python3-swsscommon_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f



# Install sonic-db-cli
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/sonic-db-cli_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f




# Install sonic-rsyslog-plugin
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/sonic-rsyslog-plugin_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f

# Generate host conf for rsyslog_plugin
j2 -f json $BUILD_TEMPLATES/rsyslog_plugin.conf.j2 $BUILD_TEMPLATES/events_info.json | sudo tee $FILESYSTEM_ROOT_ETC/rsyslog.d/host_events.conf
sudo cp $BUILD_TEMPLATES/monit_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/sshd_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/systemd_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/kernel_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/dockerd_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/seu_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/zebra_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/
sudo cp $BUILD_TEMPLATES/bgpd_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/


j2 -f json $BUILD_TEMPLATES/rsyslog_plugin.conf.j2 $BUILD_TEMPLATES/syncd_events_info.json | sudo tee $FILESYSTEM_ROOT_ETC/rsyslog.d/syncd_events.conf
sudo cp $BUILD_TEMPLATES/syncd_regex.json $FILESYSTEM_ROOT_ETC/rsyslog.d/




# Install custom-built monit package and SONiC configuration files
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/monit_*.deb || \
    sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo cp $IMAGE_CONFIGS/monit/monitrc $FILESYSTEM_ROOT/etc/monit/
sudo chmod 600 $FILESYSTEM_ROOT/etc/monit/monitrc
sudo cp $IMAGE_CONFIGS/monit/conf.d/* $FILESYSTEM_ROOT/etc/monit/conf.d/
sudo chmod 600 $FILESYSTEM_ROOT/etc/monit/conf.d/*
sudo cp $IMAGE_CONFIGS/monit/container_checker $FILESYSTEM_ROOT/usr/bin/
sudo chmod 755 $FILESYSTEM_ROOT/usr/bin/container_checker
sudo cp $IMAGE_CONFIGS/monit/memory_checker $FILESYSTEM_ROOT/usr/bin/
sudo chmod 755 $FILESYSTEM_ROOT/usr/bin/memory_checker
sudo cp $IMAGE_CONFIGS/monit/restart_service $FILESYSTEM_ROOT/usr/bin/
sudo chmod 755 $FILESYSTEM_ROOT/usr/bin/restart_service

# Installed smartmontools version should match installed smartmontools in docker-platform-monitor Dockerfile
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install smartmontools=7.2-1

# Install custom-built openssh sshd
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/openssh-server_${OPENSSH_VERSION}_*.deb $debs_path/openssh-client_${OPENSSH_VERSION}_*.deb $debs_path/openssh-sftp-server_${OPENSSH_VERSION}_*.deb


# Install custom-built flashrom
sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/flashrom_*.deb


# Copy crontabs
sudo cp -f $IMAGE_CONFIGS/cron.d/* $FILESYSTEM_ROOT/etc/cron.d/

# Copy NTP configuration files and templates
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT \
    apt-get -y install ntpdate
sudo cp $IMAGE_CONFIGS/ntp/ntp-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "ntp-config.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo cp $IMAGE_CONFIGS/ntp/ntp-config.sh $FILESYSTEM_ROOT/usr/bin/
sudo cp $IMAGE_CONFIGS/ntp/ntp.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
sudo cp $IMAGE_CONFIGS/ntp/ntp.keys.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
sudo cp $IMAGE_CONFIGS/ntp/ntp-systemd-wrapper $FILESYSTEM_ROOT/usr/lib/ntp/
sudo cp $IMAGE_CONFIGS/ntp/ntp.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "ntp.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy DNS templates
sudo cp $BUILD_TEMPLATES/dns.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/

# Copy warmboot-finalizer files
sudo LANG=C cp $IMAGE_CONFIGS/warmboot-finalizer/finalize-warmboot.sh $FILESYSTEM_ROOT/usr/local/bin/finalize-warmboot.sh
sudo LANG=C cp $IMAGE_CONFIGS/warmboot-finalizer/warmboot-finalizer.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "warmboot-finalizer.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy watchdog-control files
sudo LANG=C cp $IMAGE_CONFIGS/watchdog-control/watchdog-control.sh $FILESYSTEM_ROOT/usr/local/bin/watchdog-control.sh
sudo LANG=C cp $IMAGE_CONFIGS/watchdog-control/watchdog-control.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "watchdog-control.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy rsyslog configuration files and templates
sudo cp $IMAGE_CONFIGS/rsyslog/rsyslog-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo cp $IMAGE_CONFIGS/rsyslog/rsyslog-config.sh $FILESYSTEM_ROOT/usr/bin/
sudo cp $IMAGE_CONFIGS/rsyslog/rsyslog.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
sudo cp $IMAGE_CONFIGS/rsyslog/rsyslog-container.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
j2 $IMAGE_CONFIGS/rsyslog/rsyslog.d/00-sonic.conf.j2 | sudo tee $FILESYSTEM_ROOT/etc/rsyslog.d/00-sonic.conf
sudo cp $IMAGE_CONFIGS/rsyslog/rsyslog.d/*.conf $FILESYSTEM_ROOT/etc/rsyslog.d/
echo "rsyslog-config.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy containercfgd configuration files
sudo cp $IMAGE_CONFIGS/containercfgd/containercfgd.conf $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/

# Copy syslog override files
sudo mkdir -p $FILESYSTEM_ROOT/etc/systemd/system/syslog.socket.d
sudo cp $IMAGE_CONFIGS/syslog/override.conf $FILESYSTEM_ROOT/etc/systemd/system/syslog.socket.d/override.conf
sudo cp $IMAGE_CONFIGS/syslog/host_umount.sh $FILESYSTEM_ROOT/usr/bin/

# Copy system-health files
sudo LANG=C cp $IMAGE_CONFIGS/system-health/system-health.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "system-health.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy logrotate.d configuration files
sudo cp -f $IMAGE_CONFIGS/logrotate/logrotate.d/* $FILESYSTEM_ROOT/etc/logrotate.d/
sudo cp $IMAGE_CONFIGS/logrotate/rsyslog.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
sudo cp $IMAGE_CONFIGS/logrotate/logrotate-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo cp $IMAGE_CONFIGS/logrotate/logrotate-config.sh $FILESYSTEM_ROOT/usr/bin/
sudo mkdir -p $FILESYSTEM_ROOT/etc/systemd/system/logrotate.timer.d
sudo cp $IMAGE_CONFIGS/logrotate/timerOverride.conf $FILESYSTEM_ROOT/etc/systemd/system/logrotate.timer.d/
echo "logrotate-config.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy systemd-journald configuration files
sudo cp -f $IMAGE_CONFIGS/systemd/journald.conf $FILESYSTEM_ROOT/etc/systemd/

# Copy interfaces configuration files and templates
sudo cp $IMAGE_CONFIGS/interfaces/interfaces-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo cp $IMAGE_CONFIGS/interfaces/interfaces-config.sh $FILESYSTEM_ROOT/usr/bin/
sudo cp $IMAGE_CONFIGS/interfaces/*.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
echo "interfaces-config.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy CoPP configuration files and templates
sudo cp $IMAGE_CONFIGS/copp/copp-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo cp $IMAGE_CONFIGS/copp/copp-config.sh $FILESYSTEM_ROOT/usr/bin/
sudo cp $IMAGE_CONFIGS/copp/copp_cfg.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
echo "copp-config.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy dhcp client configuration template and create an initial configuration
sudo cp files/dhcp/dhclient.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
j2 files/dhcp/dhclient.conf.j2 | sudo tee $FILESYSTEM_ROOT/etc/dhcp/dhclient.conf
sudo cp files/dhcp/ifupdown2_policy.json $FILESYSTEM_ROOT/etc/network/ifupdown2/policy.d
sudo cp files/dhcp/90-dhcp6-systcl.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
sudo cp files/neighbor/91-gc-thresh-sysctl.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/

# Copy DNS configuration files and templates
sudo cp $IMAGE_CONFIGS/resolv-config/resolv-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo cp $IMAGE_CONFIGS/resolv-config/resolv-config.sh $FILESYSTEM_ROOT/usr/bin/
sudo cp $IMAGE_CONFIGS/resolv-config/resolv.conf.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/
echo "resolv-config.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo LANG=C chroot $FILESYSTEM_ROOT systemctl disable resolvconf.service
sudo mkdir -p $FILESYSTEM_ROOT/etc/resolvconf/update-libc.d/
sudo cp $IMAGE_CONFIGS/resolv-config/update-containers $FILESYSTEM_ROOT/etc/resolvconf/update-libc.d/

# Copy initial interfaces configuration file, will be overwritten on first boot
sudo cp $IMAGE_CONFIGS/interfaces/init_interfaces $FILESYSTEM_ROOT/etc/network/interfaces
sudo mkdir -p $FILESYSTEM_ROOT/etc/network/interfaces.d

# System'd network udev rules
sudo cp $IMAGE_CONFIGS/systemd/network/* $FILESYSTEM_ROOT_ETC/systemd/network/

# copy core file uploader files
sudo cp $IMAGE_CONFIGS/corefile_uploader/core_uploader.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo LANG=C chroot $FILESYSTEM_ROOT systemctl disable core_uploader.service
sudo cp $IMAGE_CONFIGS/corefile_uploader/core_uploader.py $FILESYSTEM_ROOT/usr/bin/
sudo cp $IMAGE_CONFIGS/corefile_uploader/core_analyzer.rc.json $FILESYSTEM_ROOT_ETC_SONIC/
sudo chmod og-rw $FILESYSTEM_ROOT_ETC_SONIC/core_analyzer.rc.json

# Rasdaemon service configuration. Use timer to start rasdaemon with a delay for better fast/warm boot performance
sudo cp $IMAGE_CONFIGS/rasdaemon/rasdaemon.timer $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT systemctl disable rasdaemon.service
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT systemctl enable rasdaemon.timer

sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install libffi-dev libssl-dev


sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install systemd-bootchart
sudo tee $FILESYSTEM_ROOT_ETC/systemd/bootchart.conf > /dev/null <<EOF
[Bootchart]
Samples=4500
Frequency=25
EOF



if [[ $CONFIGURED_ARCH == armhf ]]; then
    # The azure-storage package depends on the cryptography package. Newer
    # versions of cryptography require the rust compiler, the correct version
    # for which is not readily available in buster. Hence we pre-install an
    # older version here to satisfy the azure-storage dependency.
    # Note: This is not a problem for other architectures as pre-built versions
    # of cryptography are available for those. This sequence can be removed
    # after upgrading to debian bullseye.
    sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install cryptography==3.3.1
fi
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install azure-storage==0.36.0
sudo https_proxy=$https_proxy LANG=C chroot $FILESYSTEM_ROOT pip3 install watchdog==0.10.3


# container script for docker commands, which is required as
# all docker commands are replaced with container commands.
# So just copy that file only.
#
sudo cp ${files_path}/container $FILESYSTEM_ROOT/usr/local/bin/


# Copy the buffer configuration template
sudo cp $BUILD_TEMPLATES/buffers_config.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/

# Copy the qos configuration template
sudo cp $BUILD_TEMPLATES/qos_config.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/

# Copy the templates for dynamically buffer calculation


# Copy backend acl template
sudo cp $BUILD_TEMPLATES/backend_acl.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/

# Copy hostname configuration scripts
sudo cp $IMAGE_CONFIGS/hostname/hostname-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "hostname-config.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo cp $IMAGE_CONFIGS/hostname/hostname-config.sh $FILESYSTEM_ROOT/usr/bin/

# Copy miscellaneous scripts
sudo cp $IMAGE_CONFIGS/misc/docker-wait-any $FILESYSTEM_ROOT/usr/bin/

# Copy internal topology configuration scripts

# Copy platform topology configuration scripts
sudo cp $IMAGE_CONFIGS/config-topology/config-topology.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "config-topology.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo cp $IMAGE_CONFIGS/config-topology/config-topology.sh $FILESYSTEM_ROOT/usr/bin

# Copy updategraph script and service file
j2 files/build_templates/updategraph.service.j2 | sudo tee $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM/updategraph.service
sudo cp $IMAGE_CONFIGS/updategraph/updategraph $FILESYSTEM_ROOT/usr/bin/
echo "updategraph.service" | sudo tee -a $GENERATED_SERVICE_FILE

sudo bash -c "echo enabled=false > $FILESYSTEM_ROOT/etc/sonic/updategraph.conf"


# Generate initial SONiC configuration file
j2 files/build_templates/init_cfg.json.j2 | sudo tee $FILESYSTEM_ROOT/etc/sonic/init_cfg.json

# Copy config-setup script, conf file and service file
j2 files/build_templates/config-setup.service.j2 | sudo tee $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM/config-setup.service
sudo cp $IMAGE_CONFIGS/config-setup/config-setup $FILESYSTEM_ROOT/usr/bin/config-setup
sudo mkdir -p $FILESYSTEM_ROOT/etc/config-setup
sudo cp $IMAGE_CONFIGS/config-setup/config-setup.conf $FILESYSTEM_ROOT/etc/config-setup/config-setup.conf
echo "config-setup.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo LANG=C chroot $FILESYSTEM_ROOT systemctl enable config-setup.service

# Copy reset-factory script and service
sudo cp $IMAGE_CONFIGS/reset-factory/reset-factory $FILESYSTEM_ROOT/usr/bin/reset-factory

# Add delayed tacacs application service
sudo cp files/build_templates/tacacs-config.timer $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM/
echo "tacacs-config.timer" | sudo tee -a $GENERATED_SERVICE_FILE

sudo cp files/build_templates/tacacs-config.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM/
echo "tacacs-config.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy config-chassisdb script and service file
j2 files/build_templates/config-chassisdb.service.j2 | sudo tee $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM/config-chassisdb.service
sudo cp $IMAGE_CONFIGS/config-chassisdb/config-chassisdb $FILESYSTEM_ROOT/usr/bin/config-chassisdb
echo "config-chassisdb.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo LANG=C chroot $FILESYSTEM_ROOT systemctl enable config-chassisdb.service

# Copy backend-acl script and service file
sudo cp $IMAGE_CONFIGS/backend_acl/backend-acl.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM/backend-acl.service
sudo cp $IMAGE_CONFIGS/backend_acl/backend_acl.py $FILESYSTEM_ROOT/usr/bin/backend_acl.py
echo "backend-acl.service" | sudo tee -a $GENERATED_SERVICE_FILE

# Copy SNMP configuration files
sudo cp $IMAGE_CONFIGS/snmp/snmp.yml $FILESYSTEM_ROOT/etc/sonic/

# Copy ASN configuration files
sudo cp $IMAGE_CONFIGS/constants/constants.yml $FILESYSTEM_ROOT/etc/sonic/

# Copy sudoers configuration file
sudo cp $IMAGE_CONFIGS/sudoers/sudoers $FILESYSTEM_ROOT/etc/
sudo cp $IMAGE_CONFIGS/sudoers/sudoers.lecture $FILESYSTEM_ROOT/etc/

# Copy pcie-check service files
sudo cp $IMAGE_CONFIGS/pcie-check/pcie-check.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
echo "pcie-check.service" | sudo tee -a $GENERATED_SERVICE_FILE
sudo cp $IMAGE_CONFIGS/pcie-check/pcie-check.sh $FILESYSTEM_ROOT/usr/bin/

## Install package without starting service
## ref: https://wiki.debian.org/chroot
sudo tee -a $FILESYSTEM_ROOT/usr/sbin/policy-rc.d > /dev/null <<EOF
#!/bin/sh
exit 101
EOF
sudo chmod a+x $FILESYSTEM_ROOT/usr/sbin/policy-rc.d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-pddf_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/systemd-sonic-generator_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/flashrom_0.9.7_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f



## Run depmod command for target kernel modules
sudo LANG=C chroot $FILESYSTEM_ROOT depmod -a 5.10.0-23-2-amd64

## download all dependency packages for platform debian packages
sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s6000_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_s6000_s1220-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s6000_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s6000_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_s6000_s1220-r0/platform-modules-s6000_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_s6000_s1220-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s6000

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-z9264f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9264f_c3538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-z9264f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-z9264f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9264f_c3538-r0/platform-modules-z9264f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9264f_c3538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-z9264f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s5212f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5212f_c3538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s5212f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s5212f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5212f_c3538-r0/platform-modules-s5212f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5212f_c3538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s5212f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s5224f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5224f_c3538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s5224f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s5224f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5224f_c3538-r0/platform-modules-s5224f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5224f_c3538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s5224f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s5232f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5232f_c3538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s5232f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s5232f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5232f_c3538-r0/platform-modules-s5232f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5232f_c3538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s5232f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s5248f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5248f_c3538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s5248f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s5248f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5248f_c3538-r0/platform-modules-s5248f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5248f_c3538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s5248f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-z9332f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9332f_d1508-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-z9332f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-z9332f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9332f_d1508-r0/platform-modules-z9332f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9332f_d1508-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-z9332f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-z9432f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9432f_c3758-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-z9432f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-z9432f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9432f_c3758-r0/platform-modules-z9432f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_z9432f_c3758-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-z9432f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s5296f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5296f_c3538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s5296f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s5296f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5296f_c3538-r0/platform-modules-s5296f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_s5296f_c3538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s5296f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-z9100_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_z9100_c2538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-z9100_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-z9100_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_z9100_c2538-r0/platform-modules-z9100_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_z9100_c2538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-z9100

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-s6100_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_s6100_c2538-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-s6100_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-s6100_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_s6100_c2538-r0/platform-modules-s6100_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_s6100_c2538-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-s6100

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-n3248pxe_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_n3248pxe_c3338-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-n3248pxe_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-n3248pxe_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_n3248pxe_c3338-r0/platform-modules-n3248pxe_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_n3248pxe_c3338-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-n3248pxe

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-n3248te_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_n3248te_c3338-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-n3248te_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-n3248te_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_n3248te_c3338-r0/platform-modules-n3248te_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dellemc_n3248te_c3338-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-n3248te

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-e3224f_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_e3224f-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-e3224f_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-e3224f_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_e3224f-r0/platform-modules-e3224f_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-dell_e3224f-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-e3224f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7712-32x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7712_32x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7712-32x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7712-32x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7712_32x-r0/sonic-platform-accton-as7712-32x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7712_32x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7712-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as5712-54x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5712_54x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as5712-54x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as5712-54x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5712_54x-r0/sonic-platform-accton-as5712-54x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5712_54x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as5712-54x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7816-64x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7816_64x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7816-64x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7816-64x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7816_64x-r0/sonic-platform-accton-as7816-64x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7816_64x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7816-64x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7716-32x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7716_32x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7716-32x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7716-32x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7716_32x-r0/sonic-platform-accton-as7716-32x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7716_32x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7716-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7312-54x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7312_54x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7312-54x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7312-54x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7312_54x-r0/sonic-platform-accton-as7312-54x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7312_54x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7312-54x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7326-56x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7326_56x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7326-56x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7326-56x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7326_56x-r0/sonic-platform-accton-as7326-56x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7326_56x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7326-56x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7716-32xb_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7716_32xb-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7716-32xb_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7716-32xb_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7716_32xb-r0/sonic-platform-accton-as7716-32xb_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7716_32xb-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7716-32xb

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as6712-32x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as6712_32x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as6712-32x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as6712-32x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as6712_32x-r0/sonic-platform-accton-as6712-32x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as6712_32x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as6712-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7726-32x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7726_32x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7726-32x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7726-32x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7726_32x-r0/sonic-platform-accton-as7726-32x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7726_32x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7726-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as4630-54pe_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54pe-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as4630-54pe_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as4630-54pe_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54pe-r0/sonic-platform-accton-as4630-54pe_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54pe-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as4630-54pe

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as4630-54te_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54te-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as4630-54te_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as4630-54te_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54te-r0/sonic-platform-accton-as4630-54te_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54te-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as4630-54te

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as4630-54npe_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54npe-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as4630-54npe_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as4630-54npe_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54npe-r0/sonic-platform-accton-as4630-54npe_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4630_54npe-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as4630-54npe

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-minipack_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_minipack-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-minipack_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-minipack_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_minipack-r0/sonic-platform-accton-minipack_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_minipack-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-minipack

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as5812-54x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5812_54x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as5812-54x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as5812-54x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5812_54x-r0/sonic-platform-accton-as5812-54x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5812_54x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as5812-54x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as5812-54t_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5812_54t-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as5812-54t_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as5812-54t_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5812_54t-r0/sonic-platform-accton-as5812-54t_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5812_54t-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as5812-54t

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as5835-54x_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5835_54x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as5835-54x_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as5835-54x_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5835_54x-r0/sonic-platform-accton-as5835-54x_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5835_54x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as5835-54x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9716-32d_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9716_32d-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9716-32d_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9716-32d_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9716_32d-r0/sonic-platform-accton-as9716-32d_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9716_32d-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9716-32d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9726-32d_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9726_32d-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9726-32d_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9726-32d_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9726_32d-r0/sonic-platform-accton-as9726-32d_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9726_32d-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9726-32d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9736-64d_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9736_64d-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9736-64d_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9736-64d_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9736_64d-r0/sonic-platform-accton-as9736-64d_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9736_64d-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9736-64d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as5835-54t_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5835_54t-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as5835-54t_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as5835-54t_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5835_54t-r0/sonic-platform-accton-as5835-54t_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as5835_54t-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as5835-54t

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7312-54xs_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7312_54xs-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7312-54xs_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7312-54xs_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7312_54xs-r0/sonic-platform-accton-as7312-54xs_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7312_54xs-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7312-54xs

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as7315-27xb_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7315_27xb-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as7315-27xb_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as7315-27xb_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7315_27xb-r0/sonic-platform-accton-as7315-27xb_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as7315_27xb-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as7315-27xb

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as4625-54p_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4625_54p-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as4625-54p_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as4625-54p_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4625_54p-r0/sonic-platform-accton-as4625-54p_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4625_54p-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as4625-54p

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as4625-54t_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4625_54t-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as4625-54t_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as4625-54t_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4625_54t-r0/sonic-platform-accton-as4625-54t_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as4625_54t-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as4625-54t

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9737-32db_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9737_32db-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9737-32db_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9737-32db_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9737_32db-r0/sonic-platform-accton-as9737-32db_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9737_32db-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9737-32db

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9817-64o_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_64o-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9817-64o_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9817-64o_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_64o-r0/sonic-platform-accton-as9817-64o_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_64o-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9817-64o

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9817-64d_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_64d-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9817-64d_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9817-64d_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_64d-r0/sonic-platform-accton-as9817-64d_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_64d-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9817-64d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9817-32o_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_32o-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9817-32o_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9817-32o_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_32o-r0/sonic-platform-accton-as9817-32o_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_32o-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9817-32o

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-accton-as9817-32d_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_32d-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-accton-as9817-32d_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-accton-as9817-32d_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_32d-r0/sonic-platform-accton-as9817-32d_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-accton_as9817_32d-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-accton-as9817-32d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-dx010_0.9_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_seastone-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-dx010_0.9_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-dx010_0.9_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_seastone-r0/platform-modules-dx010_0.9_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_seastone-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-dx010

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-haliburton_0.9_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_e1031-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-haliburton_0.9_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-haliburton_0.9_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_e1031-r0/platform-modules-haliburton_0.9_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_e1031-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-haliburton

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-seastone2_0.9_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_seastone_2-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-seastone2_0.9_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-seastone2_0.9_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_seastone_2-r0/platform-modules-seastone2_0.9_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_seastone_2-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-seastone2

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-belgite_0.9_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_belgite-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-belgite_0.9_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-belgite_0.9_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_belgite-r0/platform-modules-belgite_0.9_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_belgite-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-belgite

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix1b-32x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix1b_rglbmc-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix1b-32x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix1b-32x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix1b_rglbmc-r0/sonic-platform-quanta-ix1b-32x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix1b_rglbmc-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix1b-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix7-32x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix7_rglbmc-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix7-32x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix7-32x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix7_rglbmc-r0/sonic-platform-quanta-ix7-32x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix7_rglbmc-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix7-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix7-bwde-32x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix7_bwde-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix7-bwde-32x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix7-bwde-32x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix7_bwde-r0/sonic-platform-quanta-ix7-bwde-32x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix7_bwde-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix7-bwde-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix8-56x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8_rglbmc-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix8-56x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix8-56x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8_rglbmc-r0/sonic-platform-quanta-ix8-56x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8_rglbmc-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix8-56x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix8a-bwde-56x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8a_bwde-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix8a-bwde-56x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix8a-bwde-56x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8a_bwde-r0/sonic-platform-quanta-ix8a-bwde-56x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8a_bwde-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix8a-bwde-56x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix8c-56x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8c_bwde-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix8c-56x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix8c-56x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8c_bwde-r0/sonic-platform-quanta-ix8c-56x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix8c_bwde-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix8c-56x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-quanta-ix9-32x_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix9_bwde-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-quanta-ix9-32x_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-quanta-ix9-32x_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix9_bwde-r0/sonic-platform-quanta-ix9-32x_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-quanta_ix9_bwde-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-quanta-ix9-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-alphanetworks-snh60a0-320fv2_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snh60a0_320fv2-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-alphanetworks-snh60a0-320fv2_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-alphanetworks-snh60a0-320fv2_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snh60a0_320fv2-r0/sonic-platform-alphanetworks-snh60a0-320fv2_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snh60a0_320fv2-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-alphanetworks-snh60a0-320fv2

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-alphanetworks-snh60b0-640f_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snh60b0_640f-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-alphanetworks-snh60b0-640f_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-alphanetworks-snh60b0-640f_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snh60b0_640f-r0/sonic-platform-alphanetworks-snh60b0-640f_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snh60b0_640f-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-alphanetworks-snh60b0-640f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-alphanetworks-snj60d0-320f_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snj60d0_320f-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-alphanetworks-snj60d0-320f_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-alphanetworks-snj60d0-320f_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snj60d0_320f-r0/sonic-platform-alphanetworks-snj60d0-320f_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_snj60d0_320f-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-alphanetworks-snj60d0-320f

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-alphanetworks-bes2348t_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_bes2348t-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-alphanetworks-bes2348t_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-alphanetworks-bes2348t_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_bes2348t-r0/sonic-platform-alphanetworks-bes2348t_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-alphanetworks_bes2348t-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-alphanetworks-bes2348t

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-juniper-qfx5210_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-juniper_qfx5210-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-juniper-qfx5210_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-juniper-qfx5210_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-juniper_qfx5210-r0/sonic-platform-juniper-qfx5210_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-juniper_qfx5210-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-juniper-qfx5210

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-silverstone_0.9_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_silverstone-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-silverstone_0.9_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-silverstone_0.9_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_silverstone-r0/platform-modules-silverstone_0.9_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-cel_silverstone-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-silverstone

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-juniper-qfx5200_1.1_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-juniper_qfx5200-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-juniper-qfx5200_1.1_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-juniper-qfx5200_1.1_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-juniper_qfx5200-r0/sonic-platform-juniper-qfx5200_1.1_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-juniper_qfx5200-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-juniper-qfx5200

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/platform-modules-ragile-ra-b6510-48v8c_1.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ragile_ra-b6510-48v8c-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/platform-modules-ragile-ra-b6510-48v8c_1.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/platform-modules-ragile-ra-b6510-48v8c_1.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ragile_ra-b6510-48v8c-r0/platform-modules-ragile-ra-b6510-48v8c_1.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ragile_ra-b6510-48v8c-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P platform-modules-ragile-ra-b6510-48v8c

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-ufispace-s9300-32d_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s9300_32d-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-ufispace-s9300-32d_1.0.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-ufispace-s9300-32d_1.0.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s9300_32d-r0/sonic-platform-ufispace-s9300-32d_1.0.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s9300_32d-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-ufispace-s9300-32d

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-ufispace-s9110-32x_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s9110_32x-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-ufispace-s9110-32x_1.0.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-ufispace-s9110-32x_1.0.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s9110_32x-r0/sonic-platform-ufispace-s9110-32x_1.0.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s9110_32x-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-ufispace-s9110-32x

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-ufispace-s8901-54xc_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s8901_54xc-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-ufispace-s8901-54xc_1.0.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-ufispace-s8901-54xc_1.0.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s8901_54xc-r0/sonic-platform-ufispace-s8901-54xc_1.0.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s8901_54xc-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-ufispace-s8901-54xc

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-ufispace-s7801-54xs_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s7801_54xs-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-ufispace-s7801-54xs_1.0.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-ufispace-s7801-54xs_1.0.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s7801_54xs-r0/sonic-platform-ufispace-s7801-54xs_1.0.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s7801_54xs-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-ufispace-s7801-54xs

sudo dpkg --root=$FILESYSTEM_ROOT -i target/debs/bullseye/sonic-platform-ufispace-s6301-56st_1.0.0_amd64.deb || sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f --download-only

sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s6301_56st-r0
sudo mkdir -p $FILESYSTEM_ROOT/$PLATFORM_DIR/common
sudo cp target/debs/bullseye/sonic-platform-ufispace-s6301-56st_1.0.0_amd64.deb $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
sudo ln -sf "../common/sonic-platform-ufispace-s6301-56st_1.0.0_amd64.deb" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s6301_56st-r0/sonic-platform-ufispace-s6301-56st_1.0.0_amd64.deb"
for f in $(find $FILESYSTEM_ROOT/var/cache/apt/archives -name "*.deb"); do
    sudo mv $f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/
    sudo ln -sf "../common/$(basename $f)" "$FILESYSTEM_ROOT/$PLATFORM_DIR/x86_64-ufispace_s6301_56st-r0/$(basename $f)"
done

sudo dpkg --root=$FILESYSTEM_ROOT -P sonic-platform-ufispace-s6301-56st


# create a trivial apt repo if any of the debs have dependencies, including between lazy debs
if [ $(for f in $FILESYSTEM_ROOT/$PLATFORM_DIR/common/*.deb; do \
           sudo dpkg -I $f | grep "Depends:\|Pre-Depends:"; done | wc -l) -gt 0 ]; then
    (cd $FILESYSTEM_ROOT/$PLATFORM_DIR/common && sudo dpkg-scanpackages . | \
         sudo gzip | sudo tee Packages.gz > /dev/null)
fi


# Remove sshd host keys, and will regenerate on first sshd start. This needs to be
# done again here because our custom version of sshd is being installed, which
# will regenerate the sshd host keys.
sudo rm -f $FILESYSTEM_ROOT/etc/ssh/ssh_host_*_key*

sudo rm -f $FILESYSTEM_ROOT/usr/sbin/policy-rc.d

# Copy fstrim service and timer file, enable fstrim timer
sudo cp $IMAGE_CONFIGS/fstrim/* $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo LANG=C chroot $FILESYSTEM_ROOT systemctl enable fstrim.timer

## copy platform rc.local
sudo cp $IMAGE_CONFIGS/platform/rc.local $FILESYSTEM_ROOT/etc/

## copy blacklist file
sudo cp $IMAGE_CONFIGS/platform/linux_kernel_bde.conf $FILESYSTEM_ROOT/etc/modprobe.d/

# Enable psample drivers to support sFlow on vs


## Bind docker path
if [[ $MULTIARCH_QEMU_ENVIRON == y || $CROSS_BUILD_ENVIRON == y ]]; then
    sudo mkdir -p $FILESYSTEM_ROOT/dockerfs
    sudo mount --bind dockerfs $FILESYSTEM_ROOT/dockerfs
fi

## ensure proc is mounted
sudo mount proc /proc -t proc || true
if [[ $CONFIGURED_ARCH == armhf ]]; then
    # A workaround to fix the armhf build hung issue, caused by sonic-platform-nokia-7215_1.0_armhf.deb post installation script
    ps -eo pid,cmd | grep python | grep "/etc/entropy.py" | awk '{print $1}' | xargs sudo kill -9 2>/dev/null || true
fi

sudo mkdir $FILESYSTEM_ROOT/target
sudo mount --bind target $FILESYSTEM_ROOT/target
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker info


if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-database.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-database:latest docker-database:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-database and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-database:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-database has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-eventd.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-eventd:latest docker-eventd:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-eventd and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-eventd:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-eventd has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-fpm-frr.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-fpm-frr:latest docker-fpm-frr:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-fpm-frr and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-fpm-frr:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-fpm-frr has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-sonic-gnmi.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-sonic-gnmi:latest docker-sonic-gnmi:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-sonic-gnmi and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-sonic-gnmi:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-sonic-gnmi has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-lldp.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-lldp:latest docker-lldp:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-lldp and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-lldp:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-lldp has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-mux.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-mux:latest docker-mux:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-mux and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-mux:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-mux has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-nat.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-nat:latest docker-nat:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-nat and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-nat:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-nat has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-orchagent.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-orchagent:latest docker-orchagent:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-orchagent and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-orchagent:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-orchagent has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-platform-monitor.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-platform-monitor:latest docker-platform-monitor:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-platform-monitor and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-platform-monitor:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-platform-monitor has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-router-advertiser.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-router-advertiser:latest docker-router-advertiser:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-router-advertiser and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-router-advertiser:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-router-advertiser has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-sflow.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-sflow:latest docker-sflow:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-sflow and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-sflow:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-sflow has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-snmp.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-snmp:latest docker-snmp:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-snmp and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-snmp:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-snmp has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-sonic-mgmt-framework.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-sonic-mgmt-framework:latest docker-sonic-mgmt-framework:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-sonic-mgmt-framework and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-sonic-mgmt-framework:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-sonic-mgmt-framework has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-teamd.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-teamd:latest docker-teamd:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-teamd and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-teamd:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-teamd has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "broadcom" || -n "broadcom" && $TARGET_MACHINE == "broadcom" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-syncd-brcm.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-syncd-brcm:latest docker-syncd-brcm:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-syncd-brcm and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-syncd-brcm:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-syncd-brcm has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "broadcom-dnx" || -n "broadcom-dnx" && $TARGET_MACHINE == "broadcom-dnx" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-syncd-brcm-dnx.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-syncd-brcm-dnx:latest docker-syncd-brcm-dnx:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-syncd-brcm-dnx and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-syncd-brcm-dnx:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-syncd-brcm-dnx has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-gbsyncd-credo.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-gbsyncd-credo:latest docker-gbsyncd-credo:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-gbsyncd-credo and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-gbsyncd-credo:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-gbsyncd-credo has no manifest or manifest is not a valid JSON"
    exit 1
}

fi

if [[ -z "" || -n "" && $TARGET_MACHINE == "" ]]; then
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker load -i target/docker-gbsyncd-broncos.gz
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker tag docker-gbsyncd-broncos:latest docker-gbsyncd-broncos:"${SONIC_IMAGE_VERSION}"
# Check if manifest exists for docker-gbsyncd-broncos and it is a valid JSON
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT docker inspect docker-gbsyncd-broncos:latest \
    | jq '.[0].Config.Labels["com.azure.sonic.manifest"]' -r > /tmp/manifest.json
jq -e . /tmp/manifest.json || {
    >&2 echo "docker image docker-gbsyncd-broncos has no manifest or manifest is not a valid JSON"
    exit 1
}

fi


SONIC_PACKAGE_MANAGER_FOLDER="/var/lib/sonic-package-manager/"
sudo mkdir -p $FILESYSTEM_ROOT/$SONIC_PACKAGE_MANAGER_FOLDER
target_machine="$TARGET_MACHINE" j2 $BUILD_TEMPLATES/packages.json.j2 | sudo tee $FILESYSTEM_ROOT/$SONIC_PACKAGE_MANAGER_FOLDER/packages.json
if [ "${PIPESTATUS[0]}" != "0" ]; then
    echo "Failed to generate packages.json" >&2
    exit 1
fi

# Copy docker_image_ctl.j2 for SONiC Package Manager
sudo cp $BUILD_TEMPLATES/docker_image_ctl.j2 $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/docker_image_ctl.j2

# Generate shutdown order
sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT /usr/local/bin/generate_shutdown_order.py





sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT sonic-package-manager install --from-tarball target/docker-dhcp-relay.gz -y -v DEBUG --enable

sudo LANG=C DOCKER_HOST="$DOCKER_HOST" chroot $FILESYSTEM_ROOT sonic-package-manager install --from-tarball target/docker-macsec.gz -y -v DEBUG --enable

sudo umount $FILESYSTEM_ROOT/target
sudo rm -r $FILESYSTEM_ROOT/target
if [[ $MULTIARCH_QEMU_ENVIRON == y || $CROSS_BUILD_ENVIRON == y ]]; then
    sudo umount $FILESYSTEM_ROOT/dockerfs
    sudo rm -fr $FILESYSTEM_ROOT/dockerfs
    sudo kill -9 `sudo $SONIC_NATIVE_DOCKERD_FOR_DOCKERFS_PID` || true
else
    sudo chroot $FILESYSTEM_ROOT $DOCKER_CTL_SCRIPT stop
fi

sudo bash -c "echo { > $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"




    sudo bash -c "echo -n -e \"\x22database\x22 : \x22docker-database\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22eventd\x22 : \x22docker-eventd\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22bgp\x22 : \x22docker-fpm-frr\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22gnmi\x22 : \x22docker-sonic-gnmi\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22lldp\x22 : \x22docker-lldp\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22mux\x22 : \x22docker-mux\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22nat\x22 : \x22docker-nat\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22swss\x22 : \x22docker-orchagent\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22pmon\x22 : \x22docker-platform-monitor\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22radv\x22 : \x22docker-router-advertiser\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22sflow\x22 : \x22docker-sflow\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22snmp\x22 : \x22docker-snmp\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22mgmt-framework\x22 : \x22docker-sonic-mgmt-framework\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22teamd\x22 : \x22docker-teamd\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22syncd\x22 : \x22docker-syncd-brcm\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22syncd\x22 : \x22docker-syncd-brcm-dnx\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22gbsyncd\x22 : \x22docker-gbsyncd-credo\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \",\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"






    sudo bash -c "echo -n -e \"\x22gbsyncd\x22 : \x22docker-gbsyncd-broncos\x22\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

    sudo bash -c "echo \"\" >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"



sudo bash -c "echo } >> $FILESYSTEM_ROOT_USR_SHARE_SONIC_TEMPLATES/ctr_image_names.json"

if [ -f $TARGET_MACHINE"_database.sh" ]; then
    sudo cp $TARGET_MACHINE"_database.sh" $FILESYSTEM_ROOT/usr/bin/database.sh
else
    sudo cp database.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_eventd.sh" ]; then
    sudo cp $TARGET_MACHINE"_eventd.sh" $FILESYSTEM_ROOT/usr/bin/eventd.sh
else
    sudo cp eventd.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_bgp.sh" ]; then
    sudo cp $TARGET_MACHINE"_bgp.sh" $FILESYSTEM_ROOT/usr/bin/bgp.sh
else
    sudo cp bgp.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_gnmi.sh" ]; then
    sudo cp $TARGET_MACHINE"_gnmi.sh" $FILESYSTEM_ROOT/usr/bin/gnmi.sh
else
    sudo cp gnmi.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_lldp.sh" ]; then
    sudo cp $TARGET_MACHINE"_lldp.sh" $FILESYSTEM_ROOT/usr/bin/lldp.sh
else
    sudo cp lldp.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_mux.sh" ]; then
    sudo cp $TARGET_MACHINE"_mux.sh" $FILESYSTEM_ROOT/usr/bin/mux.sh
else
    sudo cp mux.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_nat.sh" ]; then
    sudo cp $TARGET_MACHINE"_nat.sh" $FILESYSTEM_ROOT/usr/bin/nat.sh
else
    sudo cp nat.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_swss.sh" ]; then
    sudo cp $TARGET_MACHINE"_swss.sh" $FILESYSTEM_ROOT/usr/bin/swss.sh
else
    sudo cp swss.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_pmon.sh" ]; then
    sudo cp $TARGET_MACHINE"_pmon.sh" $FILESYSTEM_ROOT/usr/bin/pmon.sh
else
    sudo cp pmon.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_radv.sh" ]; then
    sudo cp $TARGET_MACHINE"_radv.sh" $FILESYSTEM_ROOT/usr/bin/radv.sh
else
    sudo cp radv.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_sflow.sh" ]; then
    sudo cp $TARGET_MACHINE"_sflow.sh" $FILESYSTEM_ROOT/usr/bin/sflow.sh
else
    sudo cp sflow.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_snmp.sh" ]; then
    sudo cp $TARGET_MACHINE"_snmp.sh" $FILESYSTEM_ROOT/usr/bin/snmp.sh
else
    sudo cp snmp.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_mgmt-framework.sh" ]; then
    sudo cp $TARGET_MACHINE"_mgmt-framework.sh" $FILESYSTEM_ROOT/usr/bin/mgmt-framework.sh
else
    sudo cp mgmt-framework.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_teamd.sh" ]; then
    sudo cp $TARGET_MACHINE"_teamd.sh" $FILESYSTEM_ROOT/usr/bin/teamd.sh
else
    sudo cp teamd.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_syncd.sh" ]; then
    sudo cp $TARGET_MACHINE"_syncd.sh" $FILESYSTEM_ROOT/usr/bin/syncd.sh
else
    sudo cp syncd.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_syncd.sh" ]; then
    sudo cp $TARGET_MACHINE"_syncd.sh" $FILESYSTEM_ROOT/usr/bin/syncd.sh
else
    sudo cp syncd.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_gbsyncd.sh" ]; then
    sudo cp $TARGET_MACHINE"_gbsyncd.sh" $FILESYSTEM_ROOT/usr/bin/gbsyncd.sh
else
    sudo cp gbsyncd.sh $FILESYSTEM_ROOT/usr/bin/
fi
if [ -f $TARGET_MACHINE"_gbsyncd.sh" ]; then
    sudo cp $TARGET_MACHINE"_gbsyncd.sh" $FILESYSTEM_ROOT/usr/bin/gbsyncd.sh
else
    sudo cp gbsyncd.sh $FILESYSTEM_ROOT/usr/bin/
fi

if [ -f database.service ]; then
    sudo cp database.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "database.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f database@.service ]; then
    sudo cp database@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="database@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "database@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f database-chassis.service ]; then
    sudo cp database-chassis.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "database-chassis.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f eventd.service ]; then
    sudo cp eventd.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "eventd.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f bgp@.service ]; then
    sudo cp bgp@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="bgp@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "bgp@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f gnmi.service ]; then
    sudo cp gnmi.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "gnmi.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f lldp.service ]; then
    sudo cp lldp.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "lldp.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f lldp@.service ]; then
    sudo cp lldp@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="lldp@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "lldp@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f mux.service ]; then
    sudo cp mux.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "mux.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f nat.service ]; then
    sudo cp nat.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "nat.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f swss@.service ]; then
    sudo cp swss@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="swss@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "swss@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f pmon.service ]; then
    sudo cp pmon.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "pmon.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f radv.service ]; then
    sudo cp radv.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "radv.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f sflow.service ]; then
    sudo cp sflow.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "sflow.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f snmp.service ]; then
    sudo cp snmp.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "snmp.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f mgmt-framework.service ]; then
    sudo cp mgmt-framework.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    

    echo "mgmt-framework.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f teamd@.service ]; then
    sudo cp teamd@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="teamd@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "teamd@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f syncd@.service ]; then
    sudo cp syncd@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="syncd@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "syncd@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f syncd@.service ]; then
    sudo cp syncd@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="syncd@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "syncd@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f gbsyncd@.service ]; then
    sudo cp gbsyncd@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="gbsyncd@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "gbsyncd@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi
if [ -f gbsyncd@.service ]; then
    sudo cp gbsyncd@.service $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM

    
    MULTI_INSTANCE="gbsyncd@.service"
    SINGLE_INSTANCE=${MULTI_INSTANCE/"@"}
    sudo cp $SINGLE_INSTANCE $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
    

    echo "gbsyncd@.service" | sudo tee -a $GENERATED_SERVICE_FILE
fi

if [ -f iccpd.service ]; then
    sudo LANG=C chroot $FILESYSTEM_ROOT systemctl disable iccpd.service
fi
sudo LANG=C chroot $FILESYSTEM_ROOT fuser -km /sys || true
sudo LANG=C chroot $FILESYSTEM_ROOT umount -lf /sys


# Copy service scripts (swss, syncd, bgp, teamd, lldp, radv)
sudo LANG=C cp $SCRIPTS_DIR/swss.sh $FILESYSTEM_ROOT/usr/local/bin/swss.sh
sudo LANG=C cp $SCRIPTS_DIR/syncd.sh $FILESYSTEM_ROOT/usr/local/bin/syncd.sh
sudo LANG=C cp $SCRIPTS_DIR/syncd_common.sh $FILESYSTEM_ROOT/usr/local/bin/syncd_common.sh
sudo LANG=C cp $SCRIPTS_DIR/gbsyncd.sh $FILESYSTEM_ROOT/usr/local/bin/gbsyncd.sh
sudo LANG=C cp $SCRIPTS_DIR/gbsyncd-platform.sh $FILESYSTEM_ROOT/usr/bin/gbsyncd-platform.sh
sudo LANG=C cp $SCRIPTS_DIR/bgp.sh $FILESYSTEM_ROOT/usr/local/bin/bgp.sh
sudo LANG=C cp $SCRIPTS_DIR/teamd.sh $FILESYSTEM_ROOT/usr/local/bin/teamd.sh
sudo LANG=C cp $SCRIPTS_DIR/lldp.sh $FILESYSTEM_ROOT/usr/local/bin/lldp.sh
sudo LANG=C cp $SCRIPTS_DIR/radv.sh $FILESYSTEM_ROOT/usr/local/bin/radv.sh
sudo LANG=C cp $SCRIPTS_DIR/database.sh $FILESYSTEM_ROOT/usr/local/bin/database.sh
sudo LANG=C cp $SCRIPTS_DIR/snmp.sh $FILESYSTEM_ROOT/usr/local/bin/snmp.sh
sudo LANG=C cp $SCRIPTS_DIR/telemetry.sh $FILESYSTEM_ROOT/usr/local/bin/telemetry.sh
sudo LANG=C cp $SCRIPTS_DIR/gnmi.sh $FILESYSTEM_ROOT/usr/local/bin/gnmi.sh
sudo LANG=C cp $SCRIPTS_DIR/mgmt-framework.sh $FILESYSTEM_ROOT/usr/local/bin/mgmt-framework.sh
sudo LANG=C cp $SCRIPTS_DIR/asic_status.sh $FILESYSTEM_ROOT/usr/local/bin/asic_status.sh
sudo LANG=C cp $SCRIPTS_DIR/asic_status.py $FILESYSTEM_ROOT/usr/local/bin/asic_status.py

# Copy sonic-netns-exec script
sudo LANG=C cp $SCRIPTS_DIR/sonic-netns-exec $FILESYSTEM_ROOT/usr/bin/sonic-netns-exec

# Copy write_standby script for mux state
sudo LANG=C cp $SCRIPTS_DIR/write_standby.py $FILESYSTEM_ROOT/usr/local/bin/write_standby.py

# Copy mark_dhcp_packet script
sudo LANG=C cp $SCRIPTS_DIR/mark_dhcp_packet.py $FILESYSTEM_ROOT/usr/local/bin/mark_dhcp_packet.py

sudo cp $BUILD_TEMPLATES/sonic.target $FILESYSTEM_ROOT_USR_LIB_SYSTEMD_SYSTEM
sudo LANG=C chroot $FILESYSTEM_ROOT systemctl enable sonic.target

sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get purge -y python3-dev
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get purge -y build-essential libssl-dev swig
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get purge -y libcairo2-dev libdbus-1-dev libgirepository1.0-dev libsystemd-dev pkg-config
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get clean -y
sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get autoremove -y

sudo cp dockers/docker-database/base_image_files/redis-cli $FILESYSTEM_ROOT//usr/bin/redis-cli
sudo cp dockers/docker-fpm-frr/base_image_files/vtysh $FILESYSTEM_ROOT//usr/bin/vtysh
sudo cp dockers/docker-fpm-frr/base_image_files/rvtysh $FILESYSTEM_ROOT//usr/bin/rvtysh
sudo cp dockers/docker-fpm-frr/base_image_files/TSA $FILESYSTEM_ROOT//usr/bin/TSA
sudo cp dockers/docker-fpm-frr/base_image_files/TSB $FILESYSTEM_ROOT//usr/bin/TSB
sudo cp dockers/docker-fpm-frr/base_image_files/TSC $FILESYSTEM_ROOT//usr/bin/TSC
sudo cp dockers/docker-fpm-frr/base_image_files/TS $FILESYSTEM_ROOT//usr/bin/TS
sudo cp dockers/docker-sonic-gnmi/base_image_files/monit_gnmi $FILESYSTEM_ROOT//etc/monit/conf.d
sudo cp dockers/docker-lldp/base_image_files/lldpctl $FILESYSTEM_ROOT//usr/bin/lldpctl
sudo cp dockers/docker-lldp/base_image_files/lldpcli $FILESYSTEM_ROOT//usr/bin/lldpcli
sudo cp dockers/docker-nat/base_image_files/natctl $FILESYSTEM_ROOT//usr/bin/natctl
sudo cp dockers/docker-orchagent/base_image_files/swssloglevel $FILESYSTEM_ROOT//usr/bin/swssloglevel
sudo cp dockers/docker-platform-monitor/base_image_files/cmd_wrapper $FILESYSTEM_ROOT//usr/bin/sensors
sudo cp dockers/docker-platform-monitor/base_image_files/cmd_wrapper $FILESYSTEM_ROOT//usr/sbin/iSmart
sudo cp dockers/docker-platform-monitor/base_image_files/cmd_wrapper $FILESYSTEM_ROOT//usr/sbin/SmartCmd
sudo cp dockers/docker-platform-monitor/base_image_files/cmd_wrapper $FILESYSTEM_ROOT//usr/bin/ethtool
sudo cp dockers/docker-sflow/base_image_files/psample $FILESYSTEM_ROOT//usr/bin/psample
sudo cp dockers/docker-sflow/base_image_files/sflowtool $FILESYSTEM_ROOT//usr/bin/sflowtool
sudo cp dockers/docker-snmp/base_image_files/monit_snmp $FILESYSTEM_ROOT//etc/monit/conf.d
sudo cp dockers/docker-sonic-mgmt-framework/base_image_files/sonic-cli $FILESYSTEM_ROOT//usr/bin/sonic-cli
sudo cp dockers/docker-teamd/base_image_files/teamdctl $FILESYSTEM_ROOT//usr/bin/teamdctl
sudo cp platform/broadcom/docker-syncd-brcm/base_image_files/bcmcmd $FILESYSTEM_ROOT//usr/bin/bcmcmd
sudo cp platform/broadcom/docker-syncd-brcm/base_image_files/bcmsh $FILESYSTEM_ROOT//usr/bin/bcmsh
sudo cp platform/broadcom/docker-syncd-brcm/base_image_files/bcm_common $FILESYSTEM_ROOT//usr/bin/bcm_common
sudo cp platform/broadcom/docker-syncd-brcm-dnx/base_image_files/bcmcmd $FILESYSTEM_ROOT//usr/bin/bcmcmd
sudo cp platform/broadcom/docker-syncd-brcm-dnx/base_image_files/bcmsh $FILESYSTEM_ROOT//usr/bin/bcmsh
sudo cp platform/broadcom/docker-syncd-brcm-dnx/base_image_files/bcm_common $FILESYSTEM_ROOT//usr/bin/bcm_common

sudo mkdir $FILESYSTEM_ROOT/etc/sonic/frr
sudo touch $FILESYSTEM_ROOT/etc/sonic/frr/frr.conf
sudo touch $FILESYSTEM_ROOT/etc/sonic/frr/vtysh.conf
sudo chown -R $FRR_USER_UID:$FRR_USER_GID $FILESYSTEM_ROOT/etc/sonic/frr
sudo chmod -R 640 $FILESYSTEM_ROOT/etc/sonic/frr/
sudo chmod 750 $FILESYSTEM_ROOT/etc/sonic/frr

# Mask services which are disabled by default
sudo cp $BUILD_SCRIPTS_DIR/mask_disabled_services.py $FILESYSTEM_ROOT/tmp/
sudo chmod a+x $FILESYSTEM_ROOT/tmp/mask_disabled_services.py
sudo LANG=C chroot $FILESYSTEM_ROOT /tmp/mask_disabled_services.py
sudo rm -rf $FILESYSTEM_ROOT/tmp/mask_disabled_services.py


sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install python3-dbus
