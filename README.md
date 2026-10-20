# VIRTRNG

Modern Virtio PCI entropy device (1af4:1044 or 1005 with modern capabilities).
Queue 0 contains device-writable buffers. Only validated used lengths are copied;
short completions continue within one 250 ms budget. No entropy pool or native
ISA requirement. The shared SDK retains source selection and failure policy.

The driver caches its exact entropy registration during init. Unregister closes
admission; reset-to-zero readback and disabled bus mastering acknowledge physical
DMA stop before buffer/MMIO release. An uncertain stop retains all resources.

`./Build.sh test` checks the actual queue and transport functions with deterministic
peers, including the MMIO API's success value 1 and reset/free acknowledgements.
It performs no host random instructions or physical device I/O. `./Build.sh` builds the module.
Windows uses `Build.bat`; both invoke the same PowerShell orchestration.

Protocol reference: [VIRTIO 1.3, entropy device](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html).
