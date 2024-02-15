#  docker build -t bfb_runtime_ubuntu22.04 -f Dockerfile .
FROM scratch
Add jammy-server-cloudimg-arm64-root.tar.xz /
ADD qemu-aarch64-static /usr/bin/
ADD mlxbf-scripts_arm64.deb /tmp
ADD mlxbf-bootctl_arm64.deb /tmp
ADD ubuntu-core-22-arm64.img.xz /
ADD COMMIT_HASH /

ARG BASE_URL
ARG DOCA_VERSION
ARG BSP_VERSION
ARG DISTRO
ARG DISTRO_VERSION
WORKDIR /root/workspace
ADD build_ubuntu_bfb .
ADD mlxbf-bootimages.deb .

ENV DEBIAN_FRONTEND=noninteractive
ENV FLASH_KERNEL_SKIP=yes
ENV RUN_FW_UPDATER=no

# Avoid running flash-kernel post install
RUN mkdir -p /run/systemd; echo docker > /run/systemd/container

RUN apt update
RUN dpkg -i --force-overwrite /root/workspace/mlxbf-bootimages*.deb
RUN dpkg -i /tmp/mlxbf-bootctl_arm64.deb
RUN dpkg -i /tmp/mlxbf-scripts_arm64.deb
RUN apt upgrade -y
RUN apt remove --purge -y snapd plymouth
RUN apt autoremove -y
RUN apt install -y grub-efi-arm64-signed grub-efi-arm64-bin shim-signed watchdog binutils

# RUN add-apt-repository ppa:canonical-kernel-bluefield/release -y
# RUN apt update
# RUN apt install -y linux-bluefield
RUN apt install -y wireless-regdb
RUN mkdir -p /tmp/kernel-debs
ADD kernel-debs /tmp/kernel-debs
RUN dpkg -i /tmp/kernel-debs/*.deb

# Copy boot bits from rootfs to EFI partition
RUN mkdir -p /boot/efi/EFI/ubuntu/; \
	cp /usr/lib/grub/arm64-efi-signed/grubaa64.efi.signed \
	/boot/efi/EFI/ubuntu/grubaa64.efi; \
	cp /usr/lib/grub/arm64-efi-signed/grubnetaa64.efi.signed \
	/boot/efi/EFI/ubuntu/grubnetaa64.efi; \
	cp /usr/lib/shim/shimaa64.efi.signed \
	/boot/efi/EFI/ubuntu/shimaa64.efi; \
	cp /usr/lib/shim/mmaa64.efi \
	   /usr/lib/shim/BOOTAA64.CSV \
	/boot/efi/EFI/ubuntu/; \
	mkdir -p /boot/efi/EFI/BOOT; \
	cp /usr/lib/shim/shimaa64.efi.signed \
	/boot/efi/EFI/BOOT/BOOTAA64.EFI; \
	cp /usr/lib/shim/mmaa64.efi \
	   /usr/lib/shim/fbaa64.efi \
	/boot/efi/EFI/BOOT/

ADD create_bfb .
ADD install.sh .

CMD ["bash", "-x", "/root/workspace/build_ubuntu_bfb"]
