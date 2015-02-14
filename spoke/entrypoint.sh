#!/bin/bash
set -e

# Tunable settings
REFRESH_IMAGES=${REFRESH_IMAGES:-"True"}
CACHE_IMAGES=${CACHE_IMAGES:-"True"}
RELEASE=${RELEASE:-stable}
SRV_DIR=${SRV_DIR:-/data/tftpboot}
CONF_FILE=${CONF_FILE:-/config/dnsmasq.conf}
DNS_CHECK=${DNS_CHECK:-"False"}
AMEND_IMAGE=${AMEND_IMAGE:-''}
COREOS_SOURCE=${COREOS_SOURCE:-"http://${RELEASE}.release.core-os.net/amd64-usr/current"}

# Networking
PRIVATE_IP=${PRIVATE_IP:-"192.168.0.1"}
ROUTE_TRAFFIC=${ROUTE_TRAFFIC:-"False"}

# DNS
DNS_SERVICE=${DNS_SERVICE:-"False"}

# DHCP
DHCP_SERVICE=${DHCP_SERVICE:-"True"}
DHCP_RANGE_START=${DHCP_RANGE_START:-100}
DHCP_RANGE_END=${DHCP_RANGE_END:-200}
DHCP_DOMAIN=${DHCP_DOMAIN:-""}
DHCP_NTP_SERVER=${DHCP_NTP_SERVER:-"0.0.0.0"}
DHCP_DNS_SERVER_1=${DHCP_DNS_SERVER_1:-"8.8.8.8"}
DHCP_DNS_SERVER_2=${DHCP_DNS_SERVER_2:-"8.8.4.4"}
DHCP_LEASE_TIME=${DHCP_LEASE_TIME:-"24h"}
DHCP_GATEWAY=${DHCP_GATEWAY:-$PRIVATE_IP}

# TFTP
TFTP_SERVICE=${TFTP_SERVICE:-"True"}

# CoreOS
COREOS_SSH_KEY=${COREOS_SSH_KEY:-""}
COREOS_CLOUD_CONFIG=${COREOS_CLOUD_CONFIG:-""}
COREOS_AUTO_LOGIN=${COREOS_AUTO_LOGIN:-"True"}
COREOS_KERNEL_CMDLINE=${COREOS_KERNEL_CMDLINE:-"rootfstype=btrfs"}

# Misc settings
ERR_LOG=/log/$HOSTNAME/pxe_stderr.log
CACHE_DIR=/data/cache/$RELEASE

restart_message() {
    echo "Container restart on $(date)."
    echo -e "\nContainer restart on $(date)." | tee -a $ERR_LOG
}

get_signing_key() {
    if [ ! -e /data/cache/CoreOS_Image_Signing_Key.pem ]; then
        wget -P /data/cache http://coreos.com/security/image-signing-key/CoreOS_Image_Signing_Key.pem
    else
        echo "Signing key already downloaded." | tee -a $ERR_LOG
    fi
}

prep_dirs() {
    mkdir -p $SRV_DIR
    cp /usr/lib/syslinux/pxelinux.0 $SRV_DIR
    mkdir -p /data/cache
}

copy_config() {
    SRC=$1
    DST=$2

    echo "Config: Copying $SRC"
    cp $1 $2
}

configure_file() {
    FILE=$1
    KEY=$2

    echo "Config: $FILE $KEY=${!KEY}"
    sed -i "s/#$KEY#/${!KEY}/g" $FILE
}

# Generates /data/config
prep_configs() {

    # dnsmasq
    rm -rf /data/config/dnsmasq.d
    mkdir -p /data/config/dnsmasq.d

    # Net
    copy_config /config/dnsmasq.tmpl/dnsmasq-net.conf /data/config/dnsmasq.d

    if [ -n "$DHCP_DOMAIN" ]; then
        echo "domain=$DHCP_DOMAIN" >> /data/config/dnsmasq.d/dnsmasq-net.conf
    fi

    echo "listen-address=$PRIVATE_IP" >> /data/config/dnsmasq.d/dnsmasq-net.conf

    # DNS
    if [[ "$DNS_SERVICE" == "True" ]]; then
        copy_config /config/dnsmasq.tmpl/dnsmasq-dns.conf /data/config/dnsmasq.d
    else
        copy_config /config/dnsmasq.tmpl/dnsmasq-dns-off.conf /data/config/dnsmasq.d
    fi

    # DHCP
    if [[ "$DHCP_SERVICE" == "True" ]]; then
        copy_config /config/dnsmasq.tmpl/dnsmasq-dhcp.conf /data/config/dnsmasq.d

        DHCP_IP_RANGE_START=$(echo $PRIVATE_IP | sed "s/\.[0-9]*$/.$DHCP_RANGE_START/g")
        DHCP_IP_RANGE_END=$(echo $PRIVATE_IP | sed "s/\.[0-9]*$/.$DHCP_RANGE_END/g")

        # Configure
        configure_file /data/config/dnsmasq.d/dnsmasq-dhcp.conf DHCP_IP_RANGE_START
        configure_file /data/config/dnsmasq.d/dnsmasq-dhcp.conf DHCP_IP_RANGE_END
        configure_file /data/config/dnsmasq.d/dnsmasq-dhcp.conf DHCP_LEASE_TIME
        configure_file /data/config/dnsmasq.d/dnsmasq-dhcp.conf DHCP_GATEWAY
        configure_file /data/config/dnsmasq.d/dnsmasq-dhcp.conf DHCP_DNS_SERVER_1
        configure_file /data/config/dnsmasq.d/dnsmasq-dhcp.conf DHCP_DNS_SERVER_2

        if [ -n "$DHCP_DOMAIN" ]; then
            echo "dhcp-option=119,$DHCP_DOMAIN" >> /data/config/dnsmasq.d/dnsmasq-dhcp.conf
        fi

        if [ -n "$DHCP_NTP_SERVER" ]; then
            echo "dhcp-option=42,$DHCP_NTP_SERVER" >> /data/config/dnsmasq.d/dnsmasq-dhcp.conf
        fi
    fi

    # TFTP
    if [[ "$TFTP_SERVICE" == "True" ]]; then
        copy_config /config/dnsmasq.tmpl/dnsmasq-tftp.conf /data/config/dnsmasq.d
    fi

    # PXE boot
    CMDLINE=$COREOS_KERNEL_CMDLINE
    if [[ "$COREOS_AUTO_LOGIN" == "True" ]]; then
        CMDLINE="$CMDLINE coreos.autologin"
    fi
    if [ -n "$COREOS_CLOUD_CONFIG" ]; then
        CMDLINE="$CMDLINE cloud-config-url=$COREOS_CLOUD_CONFIG"
    fi
    if [ -n "$COREOS_SSH_KEY" ]; then
        CMDLINE="$CMDLINE sshkey=\"$COREOS_SSH_KEY\""
    fi

    echo "PXE kernel command line: '$CMDLINE'"
    rm -rf $SRV_DIR/pxelinux.cfg
    mkdir -p $SRV_DIR/pxelinux.cfg
    copy_config /config/pxelinux.cfg/default $SRV_DIR/pxelinux.cfg
    sed -i "s^gz^gz $CMDLINE^g" $SRV_DIR/pxelinux.cfg/default
}

prep_network() {
    if [[ "$ROUTE_TRAFFIC" == "True" ]]; then
        IP_SUBNET="$(echo $PRIVATE_IP | sed "s/\.[0-9]*$/.0/g")/24"
        sudo /sbin/iptables -t nat -A POSTROUTING -s $IP_SUBNET -j MASQUERADE
    fi
}

get_images() {
    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    cd "$CACHE_DIR"
    echo -n "Downloading \"$RELEASE\" channel pxe files..." | tee -a $ERR_LOG
    wget -nv $COREOS_SOURCE/coreos_production_pxe.vmlinuz
    wget -nv $COREOS_SOURCE/coreos_production_pxe.vmlinuz.sig
    wget -nv $COREOS_SOURCE/coreos_production_pxe_image.cpio.gz
    wget -nv $COREOS_SOURCE/coreos_production_pxe_image.cpio.gz.sig
    echo "done" | tee -a $ERR_LOG

    gpg --import /data/cache/CoreOS_Image_Signing_Key.pem
    if ! $(gpg --verify coreos_production_pxe.vmlinuz.sig && gpg --verify coreos_production_pxe_image.cpio.gz.sig); then
        echo "Image verification failed. Aborting container start." | tee -a $ERR_LOG
        exit 1
    fi
}

apply_permissions() {
    chmod -R 777 $SRV_DIR $CACHE_DIR
    chown -R nobody: $SRV_DIR $CACHE_DIR
}

select_image() {
    ln -sf $CACHE_DIR/coreos_production_pxe.vmlinuz $SRV_DIR/coreos_production_pxe.vmlinuz
    ln -sf $CACHE_DIR/coreos_production_pxe_image.cpio.gz $SRV_DIR/coreos_production_pxe_image.cpio.gz
}

cache_check() {
    if [[ "$CACHE_IMAGES" == "True" ]]; then
        if [[ ! -d "$CACHE_DIR" ]]; then
            get_images
            amend_image
        else
            echo "Using cached files for \"$RELEASE\" release." | tee -a $ERR_LOG
        fi
    elif [ "$REFRESH_IMAGES" = "False" ]; then
        echo "Using original files for \"$RELEASE\" release." | tee -a $ERR_LOG
    else
        echo "Refresh files is set." | tee -a $ERR_LOG
        get_images
        amend_image
    fi
}

dns_check() {
    if [[ "$DNS_CHECK" == "True" ]]; then
        echo -n "Waiting for DNS to come online..." | tee -a $ERR_LOG
        while ! $(host ubuntu.com 2>&1 > /dev/null); do
            sleep 1s
        done
        echo "done" | tee -a $ERR_LOG
    fi
}

amend_image() {
    ex() {
        if [[ -f $1 ]]; then
            case $1 in
                *.tar.bz2) tar -C $2 -xvjf $1;;
                *.tar.gz) tar -C $2 -xvzf $1;;
                *.tar.xz) tar -C $2 -xvJf $1;;
                *.tar.lzma) tar --lzma xvf $1;;
                *.tar) tar -C $2 -xvf $1;;
                *.tbz2) tar -C $2 -xvjf $1;;
                *.tgz) tar -C $2 -xvzf $1;;
                *) echo "'$1' cannot be extracted via >ex<";;
            esac
        else
            echo "'$1' is not a valid file"
        fi
    }

    merge() {
        echo "Amending $RELEASE image..." | tee -a $ERR_LOG
        mkdir -p /tmp/amend
        cd /tmp/amend
        ex "$AMEND_IMAGE" /tmp/amend
        gzip -d $CACHE_DIR/coreos_production_pxe_image.cpio.gz
        find . | cpio -o -A -H newc -O $CACHE_DIR/coreos_production_pxe_image.cpio
        gzip $CACHE_DIR/coreos_production_pxe_image.cpio
        rm -rf /tmp/amend
    }

    if [ ! "$AMEND_IMAGE" = '' ]; then
        merge
    fi
}

dns_check

if [ ! -e /tmp/pxe_first_run ]; then
    touch /tmp/pxe_first_run
    prep_dirs
    get_signing_key
    cache_check
elif [ "$REFRESH_IMAGES" = "True" ]; then
    restart_message
    echo "Refresh files is set." | tee -a $ERR_LOG
    get_images
    amend_image
else
    restart_message
    cache_check
fi

prep_configs
prep_network
select_image
apply_permissions
echo Starting DHCP+TFTP server... | tee -a $ERR_LOG
exec dnsmasq \
    --conf-file=$CONF_FILE \
    --no-daemon

