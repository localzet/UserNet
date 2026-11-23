FROM golang:1.27.4-alpine AS build

WORKDIR /src
COPY release-signer/go.mod ./go.mod
COPY release-signer/main.go ./main.go
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/usernet-release-signer .

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        aapt \
        ca-certificates \
        openjdk-17-jre-headless \
        python3 \
    && mkdir -p /tmp/android-signing-tools \
    && cd /tmp/android-signing-tools \
    && apt-get download apksigner libapksig-java \
    && mkdir unpacked \
    && for package in ./*.deb; do dpkg-deb -x "$package" unpacked; done \
    && install -D -m 0555 unpacked/usr/lib/android-sdk/build-tools/debian/apksigner /usr/local/bin/apksigner \
    && install -D -m 0444 unpacked/usr/share/java/apksigner.jar /usr/share/java/apksigner.jar \
    && install -D -m 0444 unpacked/usr/share/java/apksig.jar /usr/share/java/apksig.jar \
    && rm -rf /tmp/android-signing-tools /var/lib/apt/lists/*

COPY --from=build /out/usernet-release-signer /usr/local/bin/usernet-release-signer
COPY scripts/usernet_ota.py /opt/usernet_ota.py

RUN chmod 0555 /usr/local/bin/usernet-release-signer /opt/usernet_ota.py

USER 994:994
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/usernet-release-signer"]
