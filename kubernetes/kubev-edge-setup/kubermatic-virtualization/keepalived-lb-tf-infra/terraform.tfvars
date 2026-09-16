cluster_name         = "kubev-cluster"
api_vip              = "10.77.33.10"
#apiserver_alternative_names = ["kubev.demo.kubermatic.io"]
ssh_username         = "ubuntu"
ssh_private_key_file = "../../.local/id_rsa"

vrrp_interface = "enp2s0" #internal communication device
vrrp_router_id = 39 #uniqe per subnet

control_plane_hosts = [
  "10.77.33.196",
  # "10.0.2.44",
  # "10.0.2.43"
]