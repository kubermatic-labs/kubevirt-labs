NAMESPACE ?= build-vm-win10
VM_NAME ?= windows-10-golden
ISO_DV_NAME = windows-10-x86-64-iso
TIMEOUT ?= 10m
INSTANCE_TYPE ?= u1.large
PREFERENCE ?= windows.10.virtio

DEMO_NS ?= win10-golden

.PHONY: help setup iso-wait init build all clean status check-prereqs vnc vm-yaml verify verify-stop deploy deploy-status deploy-vnc deploy-destroy

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

check-prereqs: ## Verify instance type, preference, and ISO DataVolume exist
	@echo "=== Checking VirtualMachineClusterInstanceType: $(INSTANCE_TYPE) ==="
	@kubectl get virtualmachineclusterinstancetype $(INSTANCE_TYPE) -o name 2>/dev/null \
		|| (echo "ERROR: Instance type '$(INSTANCE_TYPE)' not found. Run: kubectl get virtualmachineclusterinstancetype" && false)
	@echo ""
	@echo "=== Checking VirtualMachineClusterPreference: $(PREFERENCE) ==="
	@kubectl get virtualmachineclusterpreference $(PREFERENCE) -o name 2>/dev/null \
		|| (echo "ERROR: Preference '$(PREFERENCE)' not found. Run: kubectl get virtualmachineclusterpreference | grep -i windows" && false)
	@echo ""
	@echo "=== Checking ISO DataVolume: $(ISO_DV_NAME) ==="
	@kubectl -n $(NAMESPACE) get dv $(ISO_DV_NAME) -o jsonpath='{.status.phase}' 2>/dev/null \
		|| (echo "ERROR: ISO DataVolume not found. Run: make setup" && false)
	@echo ""
	@echo "All prerequisites OK."

setup: ## Create namespace and apply the ISO DataVolume
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n $(NAMESPACE) -f iso-datavolume.yaml

iso-wait: ## Wait for the ISO DataVolume to be ready
	kubectl -n $(NAMESPACE) wait --for=condition=Ready dv/$(ISO_DV_NAME) --timeout=$(TIMEOUT)

init: ## Initialize Packer plugins
	packer init windows-10.pkr.hcl

build: ## Run the Packer build (with verbose logging)
	PACKER_LOG=1 packer build windows-10.pkr.hcl

all: setup iso-wait init check-prereqs build ## Full pipeline: setup + wait + init + check + build

clean: ## Delete the ISO DataVolume and namespace
	kubectl delete -n $(NAMESPACE) dv/$(ISO_DV_NAME) --ignore-not-found
	kubectl delete namespace $(NAMESPACE) --ignore-not-found

status: ## Show DataVolume, VM, and Pod status
	@echo "=== DataVolumes ==="
	kubectl -n $(NAMESPACE) get dv
	@echo ""
	@echo "=== VirtualMachines ==="
	kubectl -n $(NAMESPACE) get vm
	@echo ""
	@echo "=== VirtualMachineInstances ==="
	kubectl -n $(NAMESPACE) get vmi
	@echo ""
	@echo "=== Pods ==="
	kubectl -n $(NAMESPACE) get pods

vnc: ## Open VNC console to the build VM
	virtctl vnc -n $(NAMESPACE) $(VM_NAME)

vm-yaml: ## Dump the full VM spec (for debugging boot order, disks, firmware)
	kubectl -n $(NAMESPACE) get vm $(VM_NAME) -o yaml

verify: ## Start the golden image VM and verify it boots
	@echo "=== Checking golden image DataSource ==="
	@kubectl -n $(NAMESPACE) get datasource $(VM_NAME) -o jsonpath='{.metadata.name}' 2>/dev/null \
		&& echo " OK" \
		|| (echo "ERROR: DataSource '$(VM_NAME)' not found. Run: make build" && false)
	@echo ""
	@echo "=== Checking golden image DataVolume ==="
	@kubectl -n $(NAMESPACE) get dv $(VM_NAME) -o jsonpath='Phase: {.status.phase}{"\n"}' 2>/dev/null \
		|| (echo "ERROR: DataVolume '$(VM_NAME)' not found." && false)
	@echo ""
	@echo "=== Starting golden image VM ==="
	virtctl -n $(NAMESPACE) start $(VM_NAME) || true
	@echo "Waiting for VMI to be ready..."
	kubectl -n $(NAMESPACE) wait --for=condition=Ready vmi/$(VM_NAME) --timeout=5m
	@echo ""
	@echo "=== VM is running! ==="
	kubectl -n $(NAMESPACE) get vmi $(VM_NAME)
	@echo ""
	@echo "Connect via VNC:  make vnc"
	@echo "Stop after test:  make verify-stop"

verify-stop: ## Stop the golden image VM after verification
	virtctl -n $(NAMESPACE) stop $(VM_NAME)

deploy: ## Deploy a VM from the golden image (DEMO_NS=<name> to override)
	sed 's/win10-demo/$(DEMO_NS)/g' vm-from-golden-image.yaml | kubectl apply -f -
	@echo ""
	@echo "Waiting for VM to be ready..."
	kubectl -n $(DEMO_NS) wait --for=condition=Ready vmi/$(DEMO_NS) --timeout=10m
	@echo ""
	@echo "=== VM is running! ==="
	kubectl -n $(DEMO_NS) get vmi $(DEMO_NS)
	@echo ""
	@echo "Connect via VNC:   make deploy-vnc"
	@echo "Check status:      make deploy-status"
	@echo "Destroy:           make deploy-destroy"

deploy-status: ## Show status of the deployed demo VM
	@echo "=== VirtualMachine ==="
	kubectl -n $(DEMO_NS) get vm $(DEMO_NS)
	@echo ""
	@echo "=== VirtualMachineInstance ==="
	kubectl -n $(DEMO_NS) get vmi $(DEMO_NS)
	@echo ""
	@echo "=== DataVolumes ==="
	kubectl -n $(DEMO_NS) get dv
	@echo ""
	@echo "=== Service ==="
	kubectl -n $(DEMO_NS) get svc $(DEMO_NS)
	@echo ""
	@echo "=== Pods ==="
	kubectl -n $(DEMO_NS) get pods

deploy-vnc: ## Open VNC console to the deployed demo VM
	virtctl vnc -n $(DEMO_NS) $(DEMO_NS)

deploy-destroy: ## Delete the deployed demo VM and namespace
	sed 's/win10-demo/$(DEMO_NS)/g' vm-from-golden-image.yaml | kubectl delete -f - --ignore-not-found
