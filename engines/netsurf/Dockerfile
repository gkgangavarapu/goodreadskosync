# Build the NetSurf-backed offscreen renderer in a container.
#
#   docker build -t netsurf-render engines/netsurf
#   docker run --rm -v "$PWD/engines/netsurf/out:/out" netsurf-render
#
# Produces /out/netsurf_render (glibc/musl on the build platform).
FROM alpine:3.24

RUN apk add --no-cache \
	build-base git curl wget tar perl coreutils flex bison gperf pkgconf \
	linux-headers musl-dev curl-dev openssl-dev expat-dev libpng-dev \
	libjpeg-turbo-dev libwebp-dev giflib-dev zlib-dev freetype-dev \
	harfbuzz-dev fontconfig-dev libxml2-dev

WORKDIR /src
COPY . /src

RUN ./build-dev.sh && cp out/netsurf_render /netsurf_render

FROM alpine:3.24
RUN apk add --no-cache \
	curl libpng libjpeg-turbo libwebp giflib zlib freetype \
	harfbuzz fontconfig expat openssl
COPY --from=0 /netsurf_render /netsurf_render
ENTRYPOINT ["/netsurf_render"]
