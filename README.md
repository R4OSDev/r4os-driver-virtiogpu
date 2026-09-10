# VIRTGPU.R4D

Independent modern Virtio-PCI 2D graphics driver for R4OS. Development for
roadmap 0.79.8 is in progress; the initial module performs no hardware work
and is excluded from normal images. Hardware support is not yet established.

The implementation belongs here. PCI/DMA access, shared BO/fence ownership,
display takeover and output publication use the platform's existing owners.
Rendering policy and desktop behavior remain independent of QEMU/NVIDIA.
Virtio command completion is not a physical VBlank or a 3D capability.

Build from an R4OS workspace using Build.bat (Windows) or ./Build.sh (Linux).
Both invoke shared PowerShell 7 logic through local Settings.R4S mappings.
The canonical manifest owns name, version, target and image scope. Workspace
builds require the current local SDK, Contract and Libraries checkouts;
dependency archive identities are inherited verified workspace fallbacks.

Original implementation: Apache-2.0; see LICENSE, NOTICE and
THIRD_PARTY_NOTICES.md. Technical German notes: DOCUMENTATION.de.txt.
