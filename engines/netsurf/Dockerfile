# Development build for the NetSurf engine helper (x86_64 Linux).
#
# Produces /out/netsurf_render. Run:
#   docker build -t netsurf-render .
#   docker run --rm -v "$PWD/out:/out" netsurf-render
#
# This downloads and builds NetSurf and its libraries from source. It is large
# and slow on purpose: NetSurf has no distribution "libnetsurf".

FROM debian:bookworm-slim AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates git pkg-config \
    libcurl4-openssl-dev libpng-dev libjpeg-dev \
    libssl-dev libexpat1-dev libxml2-dev \
    libharfbuzz-dev libfreetype-dev libfontconfig1-dev \
    libgif-dev libwebp-dev zlib1g-dev flex bison \
 && rm -rf /var/lib/apt/lists/*

# NetSurf toolchain (its "buildsystem" pulls the rest of the libraries).
WORKDIR /src
RUN git clone --depth 1 https://git.netsurf-browser.org/netsurf.git netsurf \
 && git clone --depth 1 https://git.netsurf-browser.org/buildsystem.git buildsystem \
 && git clone --depth 1 https://git.netsurf-browser.org/libnsfb.git libnsfb \
 && git clone --depth 1 https://git.netsurf-browser.org/libhubbub.git libhubbub \
 && git clone --depth 1 https://git.netsurf-browser.org/libcss.git libcss \
 && git clone --depth 1 https://git.netsurf-browser.org/libdom.git libdom \
 && git clone --depth 1 https://git.netsurf-browser.org/libwapcaplet.git libwapcaplet \
 && git clone --depth 1 https://git.netsurf-browser.org/libparserutils.git libparserutils \
 && git clone --depth 1 https://git.netsurf-browser.org/libnsutils.git libnsutils \
 && git clone --depth 1 https://git.netsurf-browser.org/libnsgif.git libnsgif \
 && git clone --depth 1 https://git.netsurf-browser.org/libnsbmp.git libnsbmp \
 && git clone --depth 1 https://git.netsurf-browser.org/libsvgtiny.git libsvgtiny

# Build the NetSurf core with the "monkey"-style minimal frontend path. The
# exact target names depend on the checkout revision; see engines/netsurf/README.md.
RUN cd netsurf && make TARGET=monkey -j"$(nproc)" || \
    (echo "See README: adjust the NetSurf build target for this revision" && false)

WORKDIR /src/netsurf
RUN make TARGET=monkey install || true

# Build the helper against the built core objects.
COPY . /helper
WORKDIR /helper
RUN make NETSURF_OBJDIR=/src/netsurf/build NETSURF_SRC=/src/netsurf \
         CFLAGS="-O2 -g -Wno-unused-parameter"

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 libpng16-16 libjpeg62-turbo libssl3 libexpat1 \
    libharfbuzz0b libfreetype6 libfontconfig1 libgif7 libwebp7 zlib1g \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /helper/out/netsurf_render /netsurf_render
COPY --from=build /usr/local/share/netsurf /usr/local/share/netsurf
ENTRYPOINT ["/netsurf_render"]
