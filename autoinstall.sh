#!/bin/bash
# Script to simplify deployment of new guests
# Currently this is designed only to work on a debian host and for debian guests
# ipcalc must also be installed as it is used to determine available IP pool given provided subnet
# and ip addresses assigned to system must be present in virsh metadata

# Set cwd of script
script_dir="$(dirname $0 | sed 's|^\./|/|')"
script_realpath="$(realpath "$script_dir")"
script_tmp=""$script_realpath"/tmp"

# Get cloudflare credentials
cf_creds=""$script_realpath"/cloudflare_creds.ini"
cf_email="$(awk '/cloudflare_email/{print $3}' "$cf_creds")"
cf_key="$(awk '/cloudflare_api_key/{print $3}' "$cf_creds")"
cf_zone="$(awk '/cloudflare_zone_id/{print $3}' "$cf_creds")"

# Create postinstall file archive
mkdir "$script_tmp"
cd "$script_realpath"/postinstallfiles
tar -czf postinstall.tar.gz ./*
mv ./postinstall.tar.gz "$script_tmp"
cd "$script_realpath"
#cp -f "$script_realpath"/preseed.cfg "$script_tmp"/

# Location of preseed, postinstall files
preseed=""$script_tmp"/preseed.cfg"
postinstallfiles=""$script_tmp"/postinstall.tar.gz"

# TODO: Add flag to specify custom preseed and postinstall files.
# TODO: Configuration a file to pull Cloudflare credentials from.

# Basic input args
# Currently these are REQUIRED
hostname="$1"
domain="$2"
ipassignment="$3"

# TODO: More detailed case statement for better on the fly configuration
# TODO: check that required information was provided

# Create array from cloudflare json output for specified domain
readarray -t cf_domain_info < <(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/"$cf_zone"/dns_records?&type=A&name="$hostname"."$domain"" \
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

# Prep Debian preseed file
# TODO: check that network information exists, else quit as install won't proceed automatically
sed -e 's/IPADDRESS/'"$assignedip"'/
        s/NETMASK/'"$netmask"'/
        s/GATEWAY/'"$gateway"'/
        s/HOSTNAME/'"$hostname"'/'  "$script_realpath"/preseed.cfg > "$script_tmp"/preseed.cfg
# Third Section
# Create logical volumes
# TODO: figure out what you want to do if a lv already exists
# TODO: make the lvcreate more portable instead of hardcoded
lvcreate -ay -L 10G -n "$hostname"-root hostssd
lvcreate -ay -L 1G -n "$hostname"-swap hostssd

# print some details
echo "Installation beginning"
echo "System "$hostname" will be assigned "$assignedip""

# Fourth Section
# Perform virt-install
virt-install \
    --name="$hostname" \
    --autostart \
    --ram=2048 \
    --vcpus=2 \
    --cpu=host-passthrough \
    --os-variant=debian10 \
    --disk path=/dev/hostssd/"$hostname"-root \
    --disk path=/dev/hostssd/"$hostname"-swap \
    --network bridge=br0 \
    --graphics spice \
    --video qxl \
    --hvm \
    --virt-type=kvm \
    --arch=x86_64 \
    --boot hd \
    --quiet \
    --noautoconsole \
    --wait=-1 \
    --location  http://deb.debian.org/debian/dists/buster/main/installer-amd64/ \
    --initrd-inject "$preseed" \
    --initrd-inject "$postinstallfiles" \
    --extra-args="auto priority=critical"

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
#rm -r "$script_tmp"
