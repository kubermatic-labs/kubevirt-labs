NAMESPACE ?= build-vm-win10
VM_NAME ?= windows-10-golden
ISO_DV_NAME = windows-10-x86-64-iso
TIMEOUT ?= 10m
INSTANCE_TYPE ?= u1.large
PREFERENCE ?= windows.10.virtio

DEMO_NS ?= win10-golden
OUTPUT_DIR ?= ./generated

# Image export settings
REGISTRY_IMAGE ?= quay.io/toschneck/kvirt-disks-windows-10-golden:latest

.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  Build Phase (create the golden image on the build cluster):"
	@grep -E '^(check-prereqs|setup|iso-wait|init|build|all|clean|status|vnc|vm-yaml):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Verify Phase (test the golden image boots correctly):"
	@grep -E '^(verify|verify-stop):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Export Phase (transfer the golden image to another cluster):"
	@grep -E '^(image-download|image-upload|image-upload-cluster|image-export):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Deploy Phase (run VMs from the golden image):"
	@grep -E '^(deploy|deploy-registry|deploy-upload|deploy-status|deploy-vnc|deploy-destroy|generate):.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---------------------------------------------------------------------------
# Build Phase: create the golden image on the build cluster
# ---------------------------------------------------------------------------

.PHONY: check-prereqs setup iso-wait init build all clean status vnc vm-yaml

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

# ---------------------------------------------------------------------------
# Verify Phase: test the golden image boots correctly
# ---------------------------------------------------------------------------

.PHONY: verify verify-stop

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
	@echo "=== Ensuring sysprep ConfigMap exists (Packer build leftover, needs unattend.xml key) ==="
	kubectl -n $(NAMESPACE) create configmap $(VM_NAME) \
		--from-literal='unattend.xml=<?xml version="1.0" encoding="utf-8"?><unattend xmlns="urn:schemas-microsoft-com:unattend"/>' \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo ""
	@echo "=== Creating RDP Service ==="
	kubectl apply -n $(NAMESPACE) -f verify-rdp-service.yaml
	@echo ""
	@echo "=== Starting golden image VM ==="
	virtctl -n $(NAMESPACE) start $(VM_NAME) || true
	@echo "Waiting for VMI to be ready..."
	kubectl -n $(NAMESPACE) wait --for=condition=Ready vmi/$(VM_NAME) --timeout=5m
	@echo ""
	@echo "=== VM is running! ==="
	kubectl -n $(NAMESPACE) get vmi $(VM_NAME)
	@echo ""
	@echo "=== RDP Service ==="
	kubectl -n $(NAMESPACE) get svc $(VM_NAME)-rdp
	@echo ""
	@echo "Connect via VNC:  make vnc"
	@echo "Connect via RDP:  kubectl -n $(NAMESPACE) get svc $(VM_NAME)-rdp"
	@echo "Stop after test:  make verify-stop"

verify-stop: ## Stop the golden image VM and clean up RDP service
	virtctl -n $(NAMESPACE) stop $(VM_NAME)
	kubectl -n $(NAMESPACE) delete -f verify-rdp-service.yaml --ignore-not-found

# ---------------------------------------------------------------------------
# Export Phase: transfer the golden image to a container registry
# ---------------------------------------------------------------------------

.PHONY: image-download upload-to-oci upload-to-kubev image-export

image-download: ## Download golden image from build cluster to .disks/
	bash image-export/download-golden-image.sh

upload-to-oci: ## Upload golden image from .disks/ to OCI container registry
	REGISTRY_IMAGE=$(REGISTRY_IMAGE) bash image-export/upload-to-oci.sh

upload-to-kubev: ## Upload golden image from .disks/ directly to a KubeVirt cluster
	bash image-export/upload-to-kubev.sh

image-export: image-download upload-to-oci ## Full export: download from cluster + upload to OCI registry

# ---------------------------------------------------------------------------
# Deploy Phase: run VMs from the golden image
# ---------------------------------------------------------------------------

.PHONY: deploy deploy-registry deploy-upload deploy-status deploy-vnc deploy-destroy generate

deploy: ## Deploy a VM cloned from the on-cluster golden image (DEMO_NS=<name>)
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

deploy-upload: ## Deploy a VM after direct upload (DST_KUBECONFIG required)
	kubectl --kubeconfig=$(DST_KUBECONFIG) apply -f image-export/vm-from-upload.yaml
	@echo ""
	@echo "Waiting for VM to be ready..."
	kubectl --kubeconfig=$(DST_KUBECONFIG) -n $(DEMO_NS) wait --for=condition=Ready vmi/win10-golden --timeout=10m
	@echo ""
	@echo "=== VM is running! ==="
	kubectl --kubeconfig=$(DST_KUBECONFIG) -n $(DEMO_NS) get vmi

deploy-registry: ## Deploy a VM from the registry image (for clusters without the golden image)
	kubectl apply -f image-export/vm-from-registry-image.yaml
	@echo ""
	@echo "Waiting for DataVolume import..."
	kubectl -n $(DEMO_NS) wait --for=condition=Ready dv/windows-10-golden --timeout=30m
	@echo ""
	@echo "Waiting for VM to be ready..."
	kubectl -n $(DEMO_NS) wait --for=condition=Ready vmi/$(DEMO_NS) --timeout=10m
	@echo ""
	@echo "=== VM is running! ==="
	kubectl -n $(DEMO_NS) get vmi

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

generate: ## Generate manifest to OUTPUT_DIR (DEMO_NS=<name> OUTPUT_DIR=<path>)
	@mkdir -p $(OUTPUT_DIR)
	sed 's/win10-demo/$(DEMO_NS)/g' vm-from-golden-image.yaml > $(OUTPUT_DIR)/vm-$(DEMO_NS).yaml
	@echo "Generated: $(OUTPUT_DIR)/vm-$(DEMO_NS).yaml"
	@echo ""
	@echo "Apply with:   kubectl apply -f $(OUTPUT_DIR)/vm-$(DEMO_NS).yaml"
	@echo "Delete with:  kubectl delete -f $(OUTPUT_DIR)/vm-$(DEMO_NS).yaml"