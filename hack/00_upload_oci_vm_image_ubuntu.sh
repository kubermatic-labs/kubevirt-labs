#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(dirname $0)"


# --- Configuration ---
# Official Ubuntu Cloud Image (QCOW2 format)
UBUNTU_VERSION="24.04"
UBUNTU_URL="https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-${UBUNTU_VERSION}-server-cloudimg-amd64.img"
DOWNLOAD_FILENAME="ubuntu-${UBUNTU_VERSION}.qcow2"

# Target Registry (Change this to your own repo if you don't own kubermatic-virt-disks)
REGISTRY_REPO="quay.io/kubermatic-virt-disks/ubuntu"
TAG="${UBUNTU_VERSION}-amd64"
PLATFORM=linux/amd64

echo "--- Starting KubeVirt Disk Build ---"

# 1. Download the Ubuntu Cloud Image
echo "1. Downloading Ubuntu ${UBUNTU_VERSION} image..."
if [ ! -f "$DOWNLOAD_FILENAME" ]; then
    wget -O "$DOWNLOAD_FILENAME" "$UBUNTU_URL"
else
    echo "   File already exists, skipping download."
fi

# 2. Create a temporary Dockerfile
# KubeVirt requires the disk image to be placed in the /disk/ directory.
echo "2. Creating Dockerfile..."
cat <<EOF > Dockerfile
FROM scratch
COPY $DOWNLOAD_FILENAME /disk/disk.img
EOF

# 3. Build the Container Image
echo "3. Building Docker image: ${REGISTRY_REPO}:${TAG}..."
docker buildx build --push --platform ${PLATFORM}  -t "${REGISTRY_REPO}:${TAG}" .
#
## 4. Push to Quay
#echo "4. Pushing image to registry..."
#docker push "${REGISTRY_REPO}:${TAG}"

# 5. Cleanup
echo "5. Cleaning up temporary files..."
rm Dockerfile
# Uncomment the next line if you want to delete the downloaded qcow2 file after pushing
rm "$DOWNLOAD_FILENAME"

echo "--- Done! ---"
echo "You can now reference this image in your VirtualMachine spec:"
echo "url: docker://${REGISTRY_REPO}:${TAG}"