# KubeVirt Labs

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