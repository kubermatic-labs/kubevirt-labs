# 2026-09-17 01:04:49 by RouterOS 7.24.4
# software id = <redacted>
#
# model = D53G-5HacD2HnD
# serial number = <redacted>
/interface bridge
add admin-mac=04:F4:1C:F7:28:4C auto-mac=no comment=defconf name=bridge
/interface lte
set [ find default-name=lte1 ] allow-roaming=yes band=""
/interface wireless
set [ find default-name=wlan1 ] band=2ghz-b/g/n channel-width=20/40mhz-XX \
    disabled=no distance=indoors frequency=auto mode=ap-bridge ssid=k8c_edge \
    wireless-protocol=802.11
set [ find default-name=wlan2 ] band=5ghz-a/n/ac channel-width=\
    20/40/80mhz-XXXX disabled=no distance=indoors frequency=auto mode=\
    ap-bridge ssid=k8c_edge wireless-protocol=802.11
/interface list
add comment=defconf name=WAN
add comment=defconf name=LAN
/interface lte apn
set [ find default=yes ] default-route-distance=3 use-peer-dns=no
/interface wireless security-profiles
set [ find default=yes ] authentication-types=wpa-psk,wpa2-psk comment=\
    defconf disable-pmkid=yes mode=dynamic-keys supplicant-identity=MikroTik
add authentication-types=wpa-psk,wpa2-psk group-ciphers=tkip,aes-ccm \
    management-protection=allowed mode=dynamic-keys name=wifi-uplink \
    supplicant-identity=MikroTik unicast-ciphers=tkip,aes-ccm
/ip pool
add name=default-dhcp ranges=10.77.33.100-10.77.33.199
/ip dhcp-server
add address-pool=default-dhcp interface=bridge lease-time=10m name=defconf
/queue type
add fq-codel-ecn=no kind=fq-codel name=fq-codel-ethernet-default
/queue interface
set ether1 queue=fq-codel-ethernet-default
set ether2 queue=fq-codel-ethernet-default
set ether3 queue=fq-codel-ethernet-default
set ether4 queue=fq-codel-ethernet-default
set ether5 queue=fq-codel-ethernet-default
/system script
add comment=defconf dont-require-permissions=no name=dark-mode owner=*sys \
    policy=ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon \
    source="\r\
    \n   :if ([system leds settings get all-leds-off] = \"never\") do={\r\
    \n     /system leds settings set all-leds-off=immediate \r\
    \n   } else={\r\
    \n     /system leds settings set all-leds-off=never \r\
    \n   }\r\
    \n "
add comment="2.4GHz wlan1 -> uplink; 5GHz wlan2 stays local AP" \
    dont-require-permissions=no name=wan-wifi24-on owner=admin policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \r\
    \n  /interface/wireless/set wlan2 mode=ap-bridge security-profile=default \
    ssid=\"k8c_edge\" default-authentication=yes disabled=no\r\
    \n  :if ([:len [/interface/bridge/port/find interface=wlan2]] = 0) do={ /i\
    nterface/bridge/port/add bridge=bridge interface=wlan2 }\r\
    \n  /interface/list/member/remove [find list=WAN interface=wlan2]\r\
    \n  :if ([:len [/interface/bridge/port/find interface=wlan1]] > 0) do={ /i\
    nterface/bridge/port/remove [find interface=wlan1] }\r\
    \n  /interface/wireless/set wlan1 mode=station security-profile=wifi-uplin\
    k default-authentication=yes disabled=no\r\
    \n  /ip/dhcp-client/remove [find comment=\"WAN-wifi\"]\r\
    \n  /ip/dhcp-client/add interface=wlan1 disabled=no use-peer-dns=no use-pe\
    er-ntp=no add-default-route=yes default-route-distance=2 comment=\"WAN-wif\
    i\"\r\
    \n  :if ([:len [/interface/list/member/find list=WAN interface=wlan1]] = 0\
    ) do={ /interface/list/member/add list=WAN interface=wlan1 }\r\
    \n  :log info \"wan-wifi24-on: wlan1 is the uplink - now set its ssid and \
    the wifi-uplink key\"\r\
    \n"
add comment="5GHz wlan2 -> uplink; 2.4GHz wlan1 stays local AP" \
    dont-require-permissions=no name=wan-wifi5-on owner=admin policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \r\
    \n  /interface/wireless/set wlan1 mode=ap-bridge security-profile=default \
    ssid=\"k8c_edge\" default-authentication=yes disabled=no\r\
    \n  :if ([:len [/interface/bridge/port/find interface=wlan1]] = 0) do={ /i\
    nterface/bridge/port/add bridge=bridge interface=wlan1 }\r\
    \n  /interface/list/member/remove [find list=WAN interface=wlan1]\r\
    \n  :if ([:len [/interface/bridge/port/find interface=wlan2]] > 0) do={ /i\
    nterface/bridge/port/remove [find interface=wlan2] }\r\
    \n  /interface/wireless/set wlan2 mode=station security-profile=wifi-uplin\
    k default-authentication=yes disabled=no\r\
    \n  /ip/dhcp-client/remove [find comment=\"WAN-wifi\"]\r\
    \n  /ip/dhcp-client/add interface=wlan2 disabled=no use-peer-dns=no use-pe\
    er-ntp=no add-default-route=yes default-route-distance=2 comment=\"WAN-wif\
    i\"\r\
    \n  :if ([:len [/interface/list/member/find list=WAN interface=wlan2]] = 0\
    ) do={ /interface/list/member/add list=WAN interface=wlan2 }\r\
    \n  :log info \"wan-wifi5-on: wlan2 is the uplink - now set its ssid and t\
    he wifi-uplink key\"\r\
    \n"
add comment="both radios -> local AP on k8c_edge, no wifi uplink" \
    dont-require-permissions=no name=wan-wifi-off owner=admin policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \r\
    \n  /ip/dhcp-client/remove [find comment=\"WAN-wifi\"]\r\
    \n  /interface/list/member/remove [find list=WAN interface=wlan1]\r\
    \n  /interface/list/member/remove [find list=WAN interface=wlan2]\r\
    \n  /interface/wireless/set wlan1 mode=ap-bridge security-profile=default \
    ssid=\"k8c_edge\" default-authentication=yes disabled=no\r\
    \n  /interface/wireless/set wlan2 mode=ap-bridge security-profile=default \
    ssid=\"k8c_edge\" default-authentication=yes disabled=no\r\
    \n  :if ([:len [/interface/bridge/port/find interface=wlan1]] = 0) do={ /i\
    nterface/bridge/port/add bridge=bridge interface=wlan1 }\r\
    \n  :if ([:len [/interface/bridge/port/find interface=wlan2]] = 0) do={ /i\
    nterface/bridge/port/add bridge=bridge interface=wlan2 }\r\
    \n  :log info \"wan-wifi-off: both radios are local APs on k8c_edge\"\r\
    \n"
add comment="snapshot running config -> k8c-edge.backup + k8c-edge.rsc" \
    dont-require-permissions=no name=ws-save owner=admin policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \r\
    \n  /system/backup/save name=k8c-edge dont-encrypt=yes\r\
    \n  /export file=k8c-edge\r\
    \n  :log info \"ws-save: k8c-edge.backup + k8c-edge.rsc written\"\r\
    \n"
add comment="restore the k8c-edge workspace - REBOOTS" \
    dont-require-permissions=no name=ws-k8c-edge owner=admin policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \r\
    \n  :log warning \"ws-k8c-edge: restoring, router will reboot\"\r\
    \n  /system/backup/load name=k8c-edge\r\
    \n"
add comment="restore the original factory-default config - REBOOTS" \
    dont-require-permissions=no name=ws-stock owner=admin policy=\
    ftp,reboot,read,write,policy,test,password,sniff,sensitive,romon source="\
    \r\
    \n  :log warning \"ws-stock: restoring before-claude, router will reboot\"\
    \r\
    \n  /system/backup/load name=before-claude\r\
    \n"
/disk settings
set auto-media-interface=bridge auto-media-sharing=yes auto-smb-sharing=yes
/interface bridge port
add bridge=bridge comment=defconf interface=ether2
add bridge=bridge comment=defconf interface=ether3
add bridge=bridge comment=defconf interface=ether4
add bridge=bridge comment=defconf interface=ether5
add bridge=bridge interface=wlan2
add bridge=bridge interface=wlan1
/ip neighbor discovery-settings
set discover-interface-list=LAN
/interface detect-internet
set detect-interface-list=all
/interface list member
add comment=defconf interface=bridge list=LAN
add comment=defconf interface=lte1 list=WAN
add interface=ether1 list=WAN
/ip address
add address=10.77.33.1/24 comment=defconf interface=bridge network=10.77.33.0
/ip arp
add address=10.77.33.196 interface=bridge mac-address=00:00:01:03:0B:10
add address=10.77.33.199 interface=bridge mac-address=00:00:01:05:27:D6
/ip dhcp-client
# Interface not active
add comment=WAN-wired interface=ether1 name=client1 use-peer-dns=no \
    use-peer-ntp=no
/ip dhcp-server network
add address=10.77.33.0/24 comment=defconf dns-server=10.77.33.1 gateway=\
    10.77.33.1
/ip dns
set allow-remote-requests=yes servers=1.1.1.1,9.9.9.9
/ip dns static
add address=192.168.88.1 comment=defconf name=router.lan type=A
/ip firewall filter
add action=accept chain=input comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=\
    invalid
add action=accept chain=input comment="defconf: accept ICMP" protocol=icmp
add action=accept chain=input comment=\
    "defconf: accept to local loopback (for CAPsMAN)" dst-address=127.0.0.1
add action=drop chain=input comment="defconf: drop all not coming from LAN" \
    in-interface-list=!LAN
add action=accept chain=forward comment="defconf: accept in ipsec policy" \
    ipsec-policy=in,ipsec
add action=accept chain=forward comment="defconf: accept out ipsec policy" \
    ipsec-policy=out,ipsec
add action=fasttrack-connection chain=forward comment="defconf: fasttrack" \
    connection-state=established,related
add action=accept chain=forward comment=\
    "defconf: accept established,related, untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "defconf: drop all from WAN not DSTNATed" connection-nat-state=!dstnat \
    connection-state=new in-interface-list=WAN
/ip firewall nat
add action=masquerade chain=srcnat comment="defconf: masquerade" \
    ipsec-policy=out,none out-interface-list=WAN
/ipv6 firewall address-list
add address=::/128 comment="defconf: unspecified address" list=bad_ipv6
add address=::1/128 comment="defconf: lo" list=bad_ipv6
add address=fec0::/10 comment="defconf: site-local" list=bad_ipv6
add address=::ffff:0.0.0.0/96 comment="defconf: ipv4-mapped" list=bad_ipv6
add address=::/96 comment="defconf: ipv4 compat" list=bad_ipv6
add address=100::/64 comment="defconf: discard only " list=bad_ipv6
add address=2001:db8::/32 comment="defconf: documentation" list=bad_ipv6
add address=2001:10::/28 comment="defconf: ORCHID" list=bad_ipv6
add address=3ffe::/16 comment="defconf: 6bone" list=bad_ipv6
/ipv6 firewall filter
add action=accept chain=input comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=\
    invalid
add action=accept chain=input comment="defconf: accept ICMPv6" protocol=\
    icmpv6
add action=accept chain=input comment="defconf: accept UDP traceroute" \
    dst-port=33434-33534 protocol=udp
add action=accept chain=input comment=\
    "defconf: accept DHCPv6-Client prefix delegation." dst-port=546 protocol=\
    udp src-address=fe80::/10
add action=accept chain=input comment="defconf: accept IKE" dst-port=500,4500 \
    protocol=udp
add action=accept chain=input comment="defconf: accept ipsec AH" protocol=\
    ipsec-ah
add action=accept chain=input comment="defconf: accept ipsec ESP" protocol=\
    ipsec-esp
add action=accept chain=input comment=\
    "defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=input comment=\
    "defconf: drop everything else not coming from LAN" in-interface-list=\
    !LAN
add action=fasttrack-connection chain=forward comment="defconf: fasttrack6" \
    connection-state=established,related
add action=accept chain=forward comment=\
    "defconf: accept established,related,untracked" connection-state=\
    established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" \
    connection-state=invalid
add action=drop chain=forward comment=\
    "defconf: drop packets with bad src ipv6" src-address-list=bad_ipv6
add action=drop chain=forward comment=\
    "defconf: drop packets with bad dst ipv6" dst-address-list=bad_ipv6
add action=drop chain=forward comment="defconf: rfc4890 drop hop-limit=1" \
    hop-limit=equal:1 protocol=icmpv6
add action=accept chain=forward comment="defconf: accept ICMPv6" protocol=\
    icmpv6
add action=accept chain=forward comment="defconf: accept HIP" protocol=139
add action=accept chain=forward comment="defconf: accept IKE" dst-port=\
    500,4500 protocol=udp
add action=accept chain=forward comment="defconf: accept ipsec AH" protocol=\
    ipsec-ah
add action=accept chain=forward comment="defconf: accept ipsec ESP" protocol=\
    ipsec-esp
add action=accept chain=forward comment=\
    "defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=forward comment=\
    "defconf: drop everything else not coming from LAN" in-interface-list=\
    !LAN
/ipv6 nd
# automatic dns option advertising is not started, re-apply dns config
set [ find default=yes ] advertise-dns=yes
/system clock
set time-zone-name=Europe/Berlin
/system identity
set name=k8c-edge
/system ntp client
set enabled=yes
/system ntp client servers
add address=de.pool.ntp.org
add address=pool.ntp.org
/system routerboard mode-button
set enabled=yes on-event=dark-mode
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
