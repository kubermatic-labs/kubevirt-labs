# Windows on KubeVirt

## Samples

### Windows 11 Minimal

> `kubevirt.new.vm.minimal.windows-11.yaml`

A minimal VM manifest for Windows 11, using the uploaded ISO as the disk source. You can customize this manifest further based on your requirements.
Enabled TPM for the Installation but without persistence, so you can't store keys (e.g., BitLocker) across reboots, but it allows you to complete the installation process without issues.
You can remove the TPM device from the manifest if you don't need it for the installation.

### Windows 11 Full

> `kubevirt.new.vm.full.windows-11.yaml`

A more complete VM manifest for Windows 11, with additional resources and features enabled.
This manifest includes a TPM device with persistence, allowing you to store keys across reboots (e.g., for BitLocker).

## How to use these samples

1. Choose the sample manifest that best fits your needs (minimal or full).
2. Customize the manifest as needed, especially the `dataVolume` reference to point to your uploaded ISO.
3. Apply the manifest to your KubeVirt cluster:

    ```bash
    kubectl apply -f windows-11.yaml
    ```
4. Monitor the VM creation and installation process:

    ```bash
    kubectl get vm win11 -n default -w
    ```

5. Once the VM is running, you can connect to it via VNC using `virtctl` to complete the Windows installation:

    ```bash
    # I recommend using the `--proxy-only` flag to avoid issues with VNC connections and to use your own favorite VNC client. This will forward the VNC connection to your local machine, and you can connect to it using a VNC client (e.g., TigerVNC, RealVNC).
    virtctl vnc win11 -n default --proxy-only
    ```

6. After the installation is complete, you can remove the Windows ISO from the VM's disk devices and volume list.

## Upload you windows ISO to KubeVirt

Only needed if you want to manually upload the ISO instead of storing it in an external registry and referencing it in the DataVolume manifest.
This method is useful if you have a local copy of the ISO and want to upload it directly to your KubeVirt cluster.

### Prerequisites

- A running KubeVirt cluster with CDI (Containerized Data Importer) installed.
- `virtctl` command-line tool installed on your local machine. Use the instructions from the [KubeVirt Documentatio](https://kubevirt.io/user-guide/user_workloads/virtctl_client_tool/) or just `kubectl krew install virt` (if you have `krew` installed).
- The CDI upload proxy service should be accessible from your local machine. Use a service of type `NodePort` or `LoadBalancer` to expose the CDI upload proxy permanently, or use `kubectl port-forward` to forward the service temporarily:

```bash
kubectl port-forward -n kubevirt-cdi svc/cdi-uploadproxy 8443:443
```

### Steps

1. Download the Windows ISO from Microsoft website.
2. Create a DataVolume as a target for the upload:

    ```yaml
    apiVersion: cdi.kubevirt.io/v1beta1
    kind: DataVolume
    metadata:
    name: win11-25h2-x64 # or any name you want
    namespace: default
    annotations:
        cdi.kubevirt.io/storage.bind.immediate.requested: ""
    spec:
    source:
        upload: {}
    pvc:
        accessModes:
        - ReadWriteMany # Recommended if you want to mount the same DataVolume to multiple VMs, otherwise you can use ReadWriteOnce
        resources:
        requests:
            storage: 8Gi # Based on the size of your ISO, you can adjust this value accordingly
        storageClassName: kubev-main # Adjust this to your storage class if needed
    ```

3. Apply the DataVolume manifest:

    ```bash
    kubectl apply -f datavolume.yaml
    ```

4. Upload the ISO using `virtctl`:

    ```bash
    virtctl image-upload dv win11-25h2-x64 \ # Use the same name as your DataVolume
        --namespace=default \ # Use the same namespace as your DataVolume
        --image-path="./Win11_25H2_x64.iso" \ # Path to your downloaded ISO
        --size="8Gi" \ # Size should match the storage request in your DataVolume
        --insecure \ # Use this flag if your upload proxy is using a self-signed certificate
        --uploadproxy-url=https://127.0.0.1:8443 # URL of your upload prox (including protocol and port), adjust if you are using a different method to expose it
    ```

5. Monitor the upload progress:

    ```bash
    kubectl get dv win11-25h2-x64 -n default -w
    ```

Once the upload is complete, the DataVolume will be ready to use as a source for creating a VM. You can create a VM that uses this DataVolume as its disk source, and then boot from it to install Windows.