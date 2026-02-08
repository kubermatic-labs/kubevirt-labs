packer {
  required_plugins {
    kubevirt = {
      source  = "github.com/hashicorp/kubevirt"
      version = ">= 0.8.0"
    }
  }
}

variable "kube_config" {
  type    = string
  default = "${env("KUBECONFIG")}"
}

variable "namespace" {
  type    = string
  default = "build-vm-win10"
}

variable "name" {
  type    = string
  default = "windows-10-golden"
}

source "kubevirt-iso" "windows10" {
  # Kubernetes configuration
  kube_config = var.kube_config
  name        = var.name
  namespace   = var.namespace

  # ISO configuration — must match the DataVolume name from iso-datavolume.yaml
  iso_volume_name = "windows-10-x86-64-iso"

  # VM specifications
  disk_size     = "50Gi"
  instance_type = "u1.large"
  preference    = "windows.10.virtio"
  os_type       = "windows"

  # Network setup
  networks {
    name = "default"
    pod {}
  }

  # Files mounted as a secondary CD-ROM during installation.
  # autounattend.xml is auto-discovered by Windows Setup.
  # Scripts are referenced from F:\ drive in autounattend.xml auditUser pass.
  media_files = [
    "./autounattend.xml",
    "./scripts/install-drivers.ps1",
    "./scripts/set-network.ps1",
    "./scripts/enable-winrm.ps1",
  ]

  # Boot command sent over VNC — press spacebar to bypass "Press any key to boot from CD"
  boot_command = [
    "<spacebar><wait>",
  ]
  boot_wait                 = "5s"
  installation_wait_timeout = "45m"

  # WinRM communicator — connects after Windows install + auditUser scripts complete
  communicator       = "winrm"
  winrm_host         = "127.0.0.1"
  winrm_local_port   = 5000
  winrm_remote_port  = 5985
  winrm_username     = "admin"
  winrm_password     = "admin"
  winrm_wait_timeout = "40m"

  # Keep the VM after build for debugging (set to false for production)
  keep_vm = true
}

build {
  sources = ["source.kubevirt-iso.windows10"]

  # Install IIS and deploy the demo web page
  provisioner "powershell" {
    script = "./scripts/setup-iis.ps1"
  }

  # Bake RDP, privacy, and regional settings into the image
  provisioner "powershell" {
    script = "./scripts/configure-golden-image.ps1"
  }

  # Upload the OOBE answer file (handles user creation, locale, OOBE skip on cloned VMs)
  provisioner "file" {
    source      = "./unattend-oobe.xml"
    destination = "C:\\unattend-oobe.xml"
  }

  # Sysprep with the OOBE answer file — cloned VMs boot straight to desktop
  provisioner "windows-shell" {
    inline = [
      "C:\\Windows\\System32\\Sysprep\\sysprep.exe /generalize /oobe /shutdown /mode:vm /unattend:C:\\unattend-oobe.xml"
    ]
  }
}
