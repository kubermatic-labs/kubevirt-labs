# KubeVirt Labs

We presented a talk about Windows on Kubevirt at ContainerDays London 2026, you can [use this link to open the slides](https://docs.google.com/presentation/d/1hGCvJqT55tIRZRPwNfIibjv-Foo_l4GdT0FOTSEsWPM/edit?usp=sharing).

## Guides

- [Create a demo Ubuntu VM via the UI](linux/kubev-demo-vm-UI.md) - screenshot walkthrough of the Kubermatic Virtualization dashboard, including the two settings that most often break UI-created VMs (instance type and storage class).
- [Create a demo Windows 10 VM via the UI](windows/kubev-demo-vm-windows-UI.md) - screenshot walkthrough for deploying the Windows golden image, with the Windows-specific settings (`u1.large` + UEFI, and a `kubev-vms` Block/scsi disk).

## Data-center setup

[**KubeOne on the KubeVirt demo environment**](kubernetes/kubev-dc/kubeone/) - the
same KubeOne-on-KubeVirt cluster as the edge one below, but on the hosted demo
environment: KubeOne provisions the control-plane VMs itself through the
machine-controller KubeVirt provider, a kube-OVN gobetween VIP fronts the
kube-apiserver, and the whole thing comes up with `just up`.

## Edge setup

[**KubeV Edge Setup**](kubernetes/kubev-edge-setup/) - the full portable stack, three
layers deep: a MikroTik Chateau LTE7 that keeps a stable `10.77.33.0/24` lab LAN
whether the internet arrives by cable, foreign WiFi or LTE; Kubermatic
Virtualization running on a SNUC mini-PC; and a KubeOne Kubernetes cluster whose
nodes are KubeVirt VMs on top of it.

- [Edge network](kubernetes/kubev-edge-setup/edge-network/) - router config, uplink failover, `just` recipes
- [KubeV on the SNUC](kubernetes/kubev-edge-setup/kubermatic-virtualization/) - cluster config, keepalived VIP, storage
- [KubeOne on KubeVirt VMs](kubernetes/kubev-edge-setup/kubeone/) - a customer-shaped cluster built by KubeOne, reachable on the lab LAN through MetalLB

## Helper
```
#quick select VM name of current ns
alias vm="kubectl get --no-headers vm | fzf | awk '{print \$1}'"

#e.g.
virtctl vnc $(vm)
virtctl ssh root@vm/$(vm)
```

## Simple HTTP VM service

VM Creation Shell
```bash
# Create VM
kubectl apply -f linux/00_kubevirt-vm-ubuntu-kkp-like.yaml

# Check Schedule and Booting
watch kubectl get vm,vmi,po,pvc

# Test Connection VNC
virtctl vnc $(vm)
virtctl ssh root@vm/$(vm)

# Copy Example HTML Page
virtctl scp -r ./demo-page/ root@vm/$(vm):/

# Start Service (temporary)
virtctl ssh root@vm/$(vm)
python3 -m http.server 80 -d /demo-page
```

Helper shell
```bash
# Get VM / pod IP
kubectl get po,vm,vmi -o wide

# Create SVC for internal cluster access
kubectl apply -f linux/20_svc.yaml
# Create ING for external access
kubectl apply -f linux/30_ing.yaml

```

Testing Shell
```bash
#kdebugn opens a temp shell
kubectl run shell --pod-running-timeout 600s --rm -i --tty --image nicolaka/netshoot -- /bin/sh -c bash 

# ping
ping __VM_IP__

# test plain HTTP (if app is running or not)
curl __VM_IP__
curl demo-vm.vm-demo.svc.cluster.local
curl demo-vm
# test again after SVC Apply
curl demo-vm
curl demo-vm.vm-demo.svc.cluster.local

# apply ingress and check
curl http://demo-vm.kubev.kkp.demo.kubermatic.io 
curl https://demo-vm.kubev.kkp.demo.kubermatic.io 
```