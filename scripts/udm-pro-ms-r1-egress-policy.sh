#!/bin/sh
set -eu

WAN_TABLE="201.eth8"
MS_R1_ADDRESS="172.16.80.240"

delete_pref() {
  while ip rule del pref "$1" 2>/dev/null; do :; done
}

attempt=0
until ip route show table "$WAN_TABLE" | grep -q '^default '; do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 60 ]; then
    logger -t ms-r1-egress "WAN table $WAN_TABLE has no default route"
    exit 1
  fi
  sleep 1
done

if ! ip rule show | grep -q '^32000:.*lookup main$'; then
  logger -t ms-r1-egress "expected UniFi main-table rule at priority 32000"
  exit 1
fi

for pref in 30000 30001 30002 30003 30004 30005 30006 30007 31000 31001 31500; do
  delete_pref "$pref"
done

ip rule add pref 30000 to 0.0.0.0/8 lookup main
ip rule add pref 30001 to 10.0.0.0/8 lookup main
ip rule add pref 30002 to 100.64.0.0/10 lookup main
ip rule add pref 30003 to 127.0.0.0/8 lookup main
ip rule add pref 30004 to 169.254.0.0/16 lookup main
ip rule add pref 30005 to 172.16.0.0/12 lookup main
ip rule add pref 30006 to 192.168.0.0/16 lookup main
ip rule add pref 30007 to 224.0.0.0/4 lookup main
ip rule add pref 31000 iif lo lookup "$WAN_TABLE"
ip rule add pref 31001 from "$MS_R1_ADDRESS" lookup "$WAN_TABLE"
ip rule add pref 31500 lookup 248.routegarage

logger -t ms-r1-egress "installed WAN bypass and OSPF route-garage rules"
