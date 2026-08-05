FROM ubuntu:22.04
RUN apt-get update && apt-get dist-upgrade -y && apt-get -y install \
    build-essential \
    diffutils \
    git \
    python3 \
    wget \
    cmake \
    libfdt-dev \
    squashfs-tools \
    && apt-get autoclean && apt-get autoremove

RUN git clone https://github.com/andros-ua/owrt-ubi-installer.git -b cf-wa933 /build
WORKDIR /build
RUN ./build_installer.sh
