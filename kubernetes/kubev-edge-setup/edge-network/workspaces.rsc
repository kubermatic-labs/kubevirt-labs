# ============================================================
#  Workspace + uplink switching for k8c-edge
#  Run with:  /system/script/run <name>       (takes NO arguments)
# ============================================================
#
# The SSID is NOT part of the security profile - it lives on the interface.
# Two steps, always:
#   1. /system/script/run wan-wifi24-on        (or wan-wifi5-on)
#   2. /interface/wireless/set wlan1 ssid="THEIR-SSID"
#      /interface/wireless/security-profiles/set wifi-uplink wpa2-pre-shared-key="THEIR-PASS"
#
# Guest and venue networks are very often 2.4 GHz only, so wan-wifi24-on is
# usually the one you want. Scan first if unsure:
#   /interface/wireless/scan wlan1 duration=10
#
# The -on scripts set default-authentication=yes on the uplink radio. The
# factory config ships it as "no", which in STATION mode means "join nothing
# unless a connect-list rule says otherwise" - the radio then sits at
# searching-for-network forever with no log entry explaining why.
#
# Whichever radio becomes the uplink, the OTHER one is forced back to being
# the local AP on SSID k8c_edge, so the lab never loses its own network.

/system/script/remove [find name~"^(ws-|wan-)"]

# ---- 2.4 GHz (wlan1) as the uplink, 5 GHz stays the local AP ----
/system/script/add name=wan-wifi24-on comment="2.4GHz wlan1 -> uplink; 5GHz wlan2 stays local AP" source={
  /interface/wireless/set wlan2 mode=ap-bridge security-profile=default ssid="k8c_edge" default-authentication=yes disabled=no
  :if ([:len [/interface/bridge/port/find interface=wlan2]] = 0) do={ /interface/bridge/port/add bridge=bridge interface=wlan2 }
  /interface/list/member/remove [find list=WAN interface=wlan2]
  :if ([:len [/interface/bridge/port/find interface=wlan1]] > 0) do={ /interface/bridge/port/remove [find interface=wlan1] }
  /interface/wireless/set wlan1 mode=station security-profile=wifi-uplink default-authentication=yes disabled=no
  /ip/dhcp-client/remove [find comment="WAN-wifi"]
  /ip/dhcp-client/add interface=wlan1 disabled=no use-peer-dns=no use-peer-ntp=no add-default-route=yes default-route-distance=2 comment="WAN-wifi"
  :if ([:len [/interface/list/member/find list=WAN interface=wlan1]] = 0) do={ /interface/list/member/add list=WAN interface=wlan1 }
  :log info "wan-wifi24-on: wlan1 is the uplink - now set its ssid and the wifi-uplink key"
}

# ---- 5 GHz (wlan2) as the uplink, 2.4 GHz stays the local AP ----
/system/script/add name=wan-wifi5-on comment="5GHz wlan2 -> uplink; 2.4GHz wlan1 stays local AP" source={
  /interface/wireless/set wlan1 mode=ap-bridge security-profile=default ssid="k8c_edge" default-authentication=yes disabled=no
  :if ([:len [/interface/bridge/port/find interface=wlan1]] = 0) do={ /interface/bridge/port/add bridge=bridge interface=wlan1 }
  /interface/list/member/remove [find list=WAN interface=wlan1]
  :if ([:len [/interface/bridge/port/find interface=wlan2]] > 0) do={ /interface/bridge/port/remove [find interface=wlan2] }
  /interface/wireless/set wlan2 mode=station security-profile=wifi-uplink default-authentication=yes disabled=no
  /ip/dhcp-client/remove [find comment="WAN-wifi"]
  /ip/dhcp-client/add interface=wlan2 disabled=no use-peer-dns=no use-peer-ntp=no add-default-route=yes default-route-distance=2 comment="WAN-wifi"
  :if ([:len [/interface/list/member/find list=WAN interface=wlan2]] = 0) do={ /interface/list/member/add list=WAN interface=wlan2 }
  :log info "wan-wifi5-on: wlan2 is the uplink - now set its ssid and the wifi-uplink key"
}

# ---- both radios back to being local APs ----
/system/script/add name=wan-wifi-off comment="both radios -> local AP on k8c_edge, no wifi uplink" source={
  /ip/dhcp-client/remove [find comment="WAN-wifi"]
  /interface/list/member/remove [find list=WAN interface=wlan1]
  /interface/list/member/remove [find list=WAN interface=wlan2]
  /interface/wireless/set wlan1 mode=ap-bridge security-profile=default ssid="k8c_edge" default-authentication=yes disabled=no
  /interface/wireless/set wlan2 mode=ap-bridge security-profile=default ssid="k8c_edge" default-authentication=yes disabled=no
  :if ([:len [/interface/bridge/port/find interface=wlan1]] = 0) do={ /interface/bridge/port/add bridge=bridge interface=wlan1 }
  :if ([:len [/interface/bridge/port/find interface=wlan2]] = 0) do={ /interface/bridge/port/add bridge=bridge interface=wlan2 }
  :log info "wan-wifi-off: both radios are local APs on k8c_edge"
}

# ---- workspace: snapshot current config as k8c-edge -------
/system/script/add name=ws-save comment="snapshot running config -> k8c-edge.backup + k8c-edge.rsc" source={
  /system/backup/save name=k8c-edge dont-encrypt=yes
  /export file=k8c-edge
  :log info "ws-save: k8c-edge.backup + k8c-edge.rsc written"
}

# ---- workspace: restore k8c-edge (REBOOTS) ----------------
/system/script/add name=ws-k8c-edge comment="restore the k8c-edge workspace - REBOOTS" source={
  :log warning "ws-k8c-edge: restoring, router will reboot"
  /system/backup/load name=k8c-edge
}

# ---- workspace: back to the pre-Claude stock config -------
/system/script/add name=ws-stock comment="restore the original factory-default config - REBOOTS" source={
  :log warning "ws-stock: restoring before-claude, router will reboot"
  /system/backup/load name=before-claude
}
