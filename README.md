# VIRTGPU.R4D

Original Apache-2.0 modern Virtio-PCI 2D driver for R4OS, developed in 0.79.8.
The driver takes over a quiescent VGA-compatible Virtio GPU only when its BAR0
matches the saved boot framebuffer. Firmware-owned Virtio queues are rejected.
Unmatched devices and explicit software policy keep the common bootfb fallback.

The resident XRGB system BO, CPU-map arbitration, upload fences, exact output
identities and display ownership use shared platform contracts. The driver
negotiates VERSION_1 and optional EDID, configures a bounded split control
queue, attaches physical pages, and executes fenced create/transfer/scanout/
flush commands. Sparse frames upload their bounding rectangle. Configuration
interrupts schedule the existing retained graphics worker, including while
the display is idle; receiver changes invalidate old EDID identities.

The initial source surface retains its boot geometry. Host resize requests and
EDID modes are receiver facts, not implemented native modesets. Rendering is
CPU-based; completion denotes device execution, never visible VBlank, pageflip,
NVIDIA acceleration, 3D or VRR. The first stage uses one serialized shadow BO
and bounded synchronous control RPCs; later swapchain work can replace that
policy through the same ownership contracts.

`Build.bat` / `./Build.sh` builds the driver through shared PS7 logic and mapped
local SDK/Contract/Libraries checkouts. `unit-test` runs the two bounded wire,
feature, rectangle and completion-lifetime cases. The manifest owns version,
target and image scope. `IMAGE_SCOPE=none` deliberately keeps this test driver
out of normal images; the explicit graphics profile includes it.

With current Test artifacts built, run Distribution's `Build.bat graphics-test
Test` / `./Build.sh graphics-test Test`. It verifies native pixels, repeated
BO reuse, live host resize, injected timeout recovery and absent-device bootfb
using four vCPUs. Optional variants are `native`, `timeout`, `fallback`, `probe`.
`OPTION VIRTGPU mode=probe` performs transport/EDID discovery then teardown;
`mode=timeout` is an explicit failure fixture. Default `mode=native` never
injects a fault. Do not deploy the timeout fixture as a normal configuration.

Module 0.1.1 preserves the first failing shutdown boundary in its negative
DriverShutdown result. Codes -10 through -20 distinguish boot metadata,
display transition/retention, active scanout, reset, queue removal, IRQs,
attachment, buffer reference, transport and changed boot identity. A failed
hardware stop or release still retains ownership; these codes do not change
the reset or cleanup protocol. See the German documentation for the mapping.

See `DOCUMENTATION.de.txt`, `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES.md`.
The normative protocol is OASIS Virtio 1.3, sections 2, 4.1 and 5.7. Linux/QEMU
implementations remain external reference material and are not copied here.
