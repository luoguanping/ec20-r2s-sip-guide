# Build for linux/arm64. Asterisk and its development headers share one package version.
FROM debian:bullseye-slim AS runtime
RUN printf '%s\n' \
    'deb http://archive.debian.org/debian bullseye main' \
    'deb http://archive.debian.org/debian-security bullseye-security main' \
    > /etc/apt/sources.list \
 && rm -f /etc/apt/sources.list.d/* \
 && apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends asterisk libasound2 libsqlite3-0 ca-certificates \
 && rm -rf /var/lib/apt/lists/*

FROM runtime AS build
RUN apt-get -o Acquire::Check-Valid-Until=false update \
 && apt-get install -y --no-install-recommends asterisk-dev build-essential patch autoconf automake pkg-config libasound2-dev libsqlite3-dev curl
ARG QUECTEL_REV=3d45c7f072131296a7e3c1a4faf5bb18751dbd87
WORKDIR /src
COPY patches/chan-quectel-ec20-uac.patch /tmp/driver.patch
RUN curl -fsSL "https://codeload.github.com/IchthysMaranatha/asterisk-chan-quectel/tar.gz/${QUECTEL_REV}" -o /tmp/driver.tar.gz \
 && tar xzf /tmp/driver.tar.gz --strip-components=1 \
 && sed -i 's/\r$//' at_response.c chan_quectel.c channel.c \
 && patch -p1 < /tmp/driver.patch \
 && ./bootstrap \
 && ./configure --with-astversion=16 DESTDIR=/usr/lib/asterisk/modules \
 && make -j1

FROM runtime
COPY --from=build /src/chan_quectel.so /usr/lib/asterisk/modules/chan_quectel.so
CMD ["/usr/sbin/asterisk", "-f", "-vvv"]
