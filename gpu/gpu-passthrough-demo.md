# GPU Passthrough sample config

This is a sample configuration for creating an Ubuntu Server 24.04 VM with four GPU devices passed through. The code specificly uses NVIDIA H100 GPUs in a SXM5 server.

## KubeVirt Config

The important settings are

- The GPU and MDEV feature gates have to be enabled
- The PCI (even though they are connected through SXM) host devices -> Selects which devices can be attached to a VM and won't be attached to the hypervisor host's OS

## Virtal Machine

You "just" have to select the devices according to the NVIDIA (GPU operator) labeling and give them unique names (we just went with GPU 1-4).
