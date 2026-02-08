FROM debian:bookworm AS build

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    build-essential \
    autoconf \
    automake \
    libtool \
    pkg-config \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src
COPY . .

RUN ./autogen.sh \
  && ./configure \
  && make

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /src/aprs-weather-submit /app/aprs-weather-submit
COPY --from=build /src/ha.sh /app/ha.sh
COPY --from=build /src/pws-report.sh /app/pws-report.sh
RUN chmod +x /app/ha.sh /app/pws-report.sh /app/aprs-weather-submit
CMD ["./ha.sh"]
