#!/bin/bash
# Script to simplify deployment of new guests
# Currently this is designed only to work on a debian host and for debian guests
# ipcalc must also be installed as it is used to determine available IP pool given provided subnet
# and ip addresses assigned to system must be present in virsh metadata

# Set cwd of script
script_dir="$(dirname $0 | sed 's|^\./|/|')"
script_realpath="$(realpath "$script_dir")"

# Get cloudflare credentials
cf_creds=""$script_realpath"/cloudflare_creds.ini"
cf_email="$(awk '/cloudflare_email/{print $3}' "$cf_creds")"
cf_key="$(awk '/cloudflare_api_key/{print $3}' "$cf_creds")"
cf_zone="$(awk '/cloudflare_zone_id/{print $3}' "$cf_creds")"

# Basic input args
# Currently these are REQUIRED
hostname="$1"
domain="$2"
ipassignment="$3"

# TODO: More detailed case statement for better on the fly configuration
# TODO: check that required information was provided

# Create array from cloudflare json output for specified domain
readarray cf_domain_info < <(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/"$cf_zone"/dns_records?&type=A&name="$hostname"."$domain"" \
    -H "Content-Type:application/json" \
    -H "X-Auth-Key:"$cf_key"" \
    -H "X-Auth-Email:"$cf_email"" | json_pp)

# Check if A record already exists
if $(printf -- '%s\n' "${cf_domain_info[@]}" | grep -q '"name"'); then
        record_exists="1"
else
        record_exists="0"
fi

# Get network information based on supplied IP and netmask
readarray -t ipinfo < <( ipcalc $ipassignment -nb | awk '{print $2}' )
netmask="${ipinfo[1]}"
gateway="${ipinfo[5]}"
minip="$gateway"
maxip="${ipinfo[6]}"
# Generate usable IP range
readarray -t totalips < <( seq -f ""$( echo $minip | cut -d"." -f1-3)".%g" "$( echo $minip | cut -d"." -f4)" "$( echo $maxip | cut -d"." -f4)" )
# Parse kvm guest metadata for ips in use and add to array
readarray -t usedips < <( for vm in $(virsh list --all --name); do
    virsh metadata --config $vm custom.libvirt.metadata network |\
    xmllint --format --xpath "//ipConfig/ipAddress/text()" -
    printf '%s\n'
done )
# Add host machines IPs and gateway IP to usedips array
# TODO: change this mapfile to array+= and tr '\r\n' ' ' everything to space delimit
mapfile -t -O "${#usedips[@]}" usedips < <( ip addr show dev br0 | grep "inet " | awk '{print $2}' | cut -d"/" -f 1 ; echo "$gateway" )
# Compare totalips to usedips and create array of available ips to use
assignedip=$(comm <( printf '%s\n' "${usedips[@]}" | sort ) <( printf '%s\n' "${totalips[@]}" | sort ) -13 | sort -t"." -k4h | head -n1)

# Third Section
# Create logical volumes
# TODO: figure out what you want to do if a lv already exists
# TODO: make the lvcreate more portable instead of hardcoded
lvcreate -ay -L 10G -n "$hostname"-root hostssd
lvcreate -ay -L 1G -n "$hostname"-swap hostssd
swap_uuid="$(mkswap /dev/hostssd/"$hostname"-swap | grep UUID | cut -d"=" -f2)"

# print some details
echo "Installation beginning"
echo "System "$hostname" will be assigned "$assignedip""

# Begin install
virt-builder debian-10 \
    --hostname "$hostname" \
    --network \
    --update \
    --install "htop,vim,sudo,curl,nfs-common,git,rsync" \
    --copy-in "/sharedfs/vm_config_files/debian/etc:/" \
    --copy-in "/sharedfs/vm_config_files/debian/root:/" \
    --copy-in "/sharedfs/vm_config_files/debian/opt:/" \
    --copy-in "/sharedfs/vm_config_files/debian/home:/" \
    --copy-in "/sharedfs/letsencrypt:/etc/ssl/certs/" \
    --run-command "sed -i -e \"s/ADDRESS/"$assignedip"/\" -e \"s/GATEWAY/"$gateway"/\" -e \"s/NETMASK/"$netmask"/\" /etc/network/interfaces" \
    --run-command "echo -e \"nameserver 1.1.1.1\" > /etc/resolv.conf" \
    --run-command "printf \"# swap\nUUID=\"$swap_uuid\"\tnone\tswap\tsw\t0\t0\n\" >> /etc/fstab" \
    --firstboot-command "dpkg-reconfigure openssh-server && systemctl restart sshd" \
    --firstboot-command "bash /root/postinstall.sh" \
    -o /dev/hostssd/"$hostname"-root

virt-install \
    --import \
    --os-variant=debian10 \
    --hvm \
    --virt-type=kvm \
    --autostart \
    --name="$hostname" \
    --ram=2048 \
    --vcpus=2 \
    --cpu=host-passthrough \
    --disk path=/dev/hostssd/"$hostname"-root \
    --disk path=/dev/hostssd/"$hostname"-swap \
    --network bridge=br0 \
    --graphics spice \
    --video qxl \
    --arch=x86_64 \
    --boot hd \
    --quiet \
    --noautoconsole \

# Create dns record for new subdomain with cloudflare
if [ "$record_exists" = "0" ] ; then
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/"$cf_zone"/dns_records" \
    -H "Content-Type:application/json" \
    -H "X-Auth-Key:"$cf_key"" \
    -H "X-Auth-Email:"$cf_email"" \
    --data "{\"type\":\"A\",\"name\":\""$hostname"."$domain"\",\"content\":\""$assignedip"\",\"ttl\":1,\"proxied\":false}"
fi

# Add assigned ip to guest metadata
virsh metadata "$hostname" custom.libvirt.metadata --config --key network --set "<ipConfig><ipAddress>"$assignedip"</ipAddress></ipConfig>"

# Cleanup
