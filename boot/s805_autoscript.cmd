echo "== s805_autoscript: Armbian mainline (meson8b-xsr.dtb > meson8b-mxq.dtb > dtb.img) =="
setenv bootargs "root=UUID=ac42c4c1-fb62-4c78-aea7-21f896932776 rootfstype=ext4 rootwait rw rootflags=init_itable=0 console=ttyAML0,115200n8 console=tty1 no_console_suspend consoleblank=0 splash=verbose"
setenv kernel_addr 0x14000000
setenv initrd_addr 0x15000000
setenv dtb_addr 0x11800000
if fatload mmc 0 ${dtb_addr} dtb/meson8b-xsr.dtb; then echo "dtb: dtb/meson8b-xsr.dtb"; else if fatload mmc 0 ${dtb_addr} dtb/meson8b-mxq.dtb; then echo "dtb: dtb/meson8b-mxq.dtb"; else fatload mmc 0 ${dtb_addr} dtb.img; fi; fi
if fatload mmc 0 ${kernel_addr} uImage; then if fatload mmc 0 ${initrd_addr} uInitrd; then bootm ${kernel_addr} ${initrd_addr} ${dtb_addr}; fi; fi
echo "== s805_autoscript: boot failed, falling back to Android =="
