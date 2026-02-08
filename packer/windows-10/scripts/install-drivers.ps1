# Install VirtIO drivers (storage, network, balloon, etc.)
Start-Process msiexec -Wait -ArgumentList "/i E:\virtio-win-gt-x64.msi /qn /passive /norestart"

# Install QEMU Guest Agent
Start-Process msiexec -Wait -ArgumentList "/i E:\guest-agent\qemu-ga-x86_64.msi /qn /passive /norestart"

# Rename cached unattend.xml to prevent Sysprep from picking it up
Rename-Item -Path C:\Windows\Panther\unattend.xml -NewName unattend.install.xml -ErrorAction SilentlyContinue
