# aprs-weather-submit

[![Codacy Badge](https://api.codacy.com/project/badge/Grade/a5e5337dd57b486089391aabd2f5429b)](https://app.codacy.com/gh/rhymeswithmogul/aprs-weather-submit?utm_source=github.com\&utm_medium=referral\&utm_content=rhymeswithmogul/aprs-weather-submit\&utm_campaign=Badge_Grade_Settings)

Not everyone has a fancy weather station with APRS connectivity built in.  Maybe you're like me, and have an old-school thermometer and CoCoRaHS-approved rain gauge.  This command-line app, written in C99, can compile on most Linux toolchains (Windows support is in the works) and will manually submit APRS 1.2.1-compliant weather information to the APRS-IS network.

## Help

Anyone can use this app to create [an APRS packet](http://www.aprs.org/doc/APRS101.PDF).  However, to send it to the APRS-IS network, you must have an account on an APRS-IS IGate server, as well as an amateur radio license or CWOP identifier (more on that below).

## Examples

At the bare minimum, you can submit your weather station's position with a command line like this:

```console
$ ./aprs-weather-submit --callsign W1AW-13 --latitude 41.714692 --longitude -72.728514 --altitude 240 --server example-igate-server.foo --port 12345 --username hiram --password percymaxim
```

If you'd like to report a temperature of 68°F, you can use a command like this:

```console
$ ./aprs-weather-submit -k W1AW-13 -n 41.714692 -e -72.728514 -I example-igate-server.foo -o 12345 -u hiram -d percymaxim -t 68
```

Or, if you just want the raw packet for your own use, don't specify server information:

```console
$ ./aprs-weather-submit -k W1AW-13 -n 41.714692 -e -72.728514 -t 68
W1AW-13>APRS,TCPIP*:@090247z4142.88N/07243.71W_.../...t068aprs-weather-submit/1.5.2
```

## Home Assistant collector (ha.sh)

The script at [ha.sh](ha.sh) collects weather sensor data from Home Assistant and calls the sender at [pws-report.sh](pws-report.sh) with `key=value` parameters. It expects a [.env](.env) file in the repository root (same directory as the script) and uses `curl` and `jq`.

In this setup, Home Assistant receives weather station data over the air via rtl_433, and [ha.sh](ha.sh) simply reads the resulting Home Assistant sensor states. A common approach is to use the rtl_433 Home Assistant add-on from [pbkhrv/rtl_433-hass-addons](https://github.com/pbkhrv/rtl_433-hass-addons) to ingest the radio data.

To get started, copy the sample file and fill in your values:

*   Copy [.env.sample](.env.sample) to [.env](.env).
*   Set `HA_API_TOKEN` (required) and optionally `HA_HOST`.
*   Configure sensor extraction with `HA_ENTITY_MATCH`, `HA_ENTITY_PREFIX`, and `HA_ENTITY_MAP`.
*   Enable destinations and configure credentials with `APRS_ENABLE`, `WINDY_ENABLE`, and the corresponding settings.

Notes:

*   `HA_ENTITY_MAP` maps sender parameters to Home Assistant keys using `param:ha_key` pairs. The `ha_key` is the matched entity ID after `HA_ENTITY_PREFIX` is removed.
*   `DEBUG=1` enables debug logs and reports unused HA entities at the collector.
*   The collector loop cadence uses `REPORT_INTERVAL` (minimum 300 seconds).
*   The rain cache is maintained by [pws-report.sh](pws-report.sh), not the collector.

Example mapping:

```dotenv
HA_ENTITY_MAP="temperatureC:temperature humidity:humidity windSpeedKph:wind_speed windGustKph:wind_max_speed windDirDeg:wind_direction rainTotalMm:rain_total uvIndex:uv_index outsideLuminanceLux:outside_luminance"
```

## Sender (pws-report.sh)

The script at [pws-report.sh](pws-report.sh) reads [.env](.env), converts units, computes rain deltas from its cache, and sends observations to APRS and/or Windy based on `APRS_ENABLE` and `WINDY_ENABLE`. It crafts payloads using only the fields you provide and warns when recommended fields are missing.

Manual example:

```console
$ ./pws-report.sh temperatureC=12.3 humidity=45 windSpeedKph=10 windDirDeg=180 rainTotalMm=12.7
```

HA-driven example (from [ha.sh](ha.sh)):

```console
$ ./pws-report.sh temperatureC=7.2 humidity=97 windSpeedKph=1.9 windGustKph=3.3 windDirDeg=168 rainTotalMm=36.81 uvIndex=0 outsideLuminanceLux=0
```

Options:

*   `--dry-run` logs the outgoing requests without sending.
*   `--log-fields` prints only the parameter keys (no values).
*   `--force-send` bypasses interval checks for this invocation.

Supported input keys (explicit unit suffixes):

*   `temperatureC`, `temperatureF`
*   `dewpointC`, `dewpointF`
*   `humidity`
*   `windSpeedKph`, `windSpeedMps`, `windSpeedMph`
*   `windGustKph`, `windGustMps`, `windGustMph`
*   `windDirDeg`
*   `rainTotalMm`
*   `pressureHpa`, `pressurePa`
*   `uvIndex`
*   `outsideLuminanceLux`

Notes:

*   `APRS_ENABLE` and `WINDY_ENABLE` control destinations (0/1).
*   `APRS_DRY_RUN` and `WINDY_DRY_RUN` log without sending.
*   `REPORT_INTERVAL` controls how often APRS/Windy sends are attempted (minimum 300).
*   `APRS_ALTITUDE_M` is in meters; it is converted to feet for APRS.
*   `LUX_EFFICACY` controls conversion from lux to W/m² (default 110).
*   `PWS_CACHE_FILE` stores rain history and last-send timestamps (default .pws-report.cache).
*   `--dry-run` overrides both destination dry-run flags.
*   Exit code is 2 when no outputs are generated.

This app supports all of the parameters defined in APRS versions up to and including version 1.2.1:

*   Altitude (`-A`, `--altitude`)
*   Barometric pressure (`-b`, `--pressure`) in mbar/hPa
*   Device type identifier (`-Z`, `--device-type`)
*   Icon (`-i`, `--icon`)
*   Luminosity (`-L`, `--luminosity`)
*   Radiation (`-X`, `--radiation`)
*   Rainfall in the past 24 hours (`-p`, `--rainfall-last-24-hours`) in inches
*   Rainfall since midnight (`-P`, `--rainfall-since-midnight`) in inches
*   Rainfall in the past hour (`-r`, `--rainfall-last-hour`) in inches
*   Relative humidity (`-h`,`  --humidity `)
*   Snowfall in the past 24 hours (`-s`, `--snowfall-last-24-hours`)
*   Temperature (°F) (`-t`, `--temperature`)
*   Temperature (°C) (`-T`, `--temperature-celsius`)
*   Water level above flood stage or mean tide (`-F`, `--water-level-above-stage`)
*   Weather station battery voltage (`-V`, `--voltage`)
*   Wind direction (`-c`, `--wind-direction`)
*   Wind speed, peak in the last five minutes (`-g`, `--gust`) in mph
*   Wind speed, sustained over the last minute (`-S`, `--wind-speed`) in mph


## Installing

### Ubuntu Linux and Debian-based distributions
If your distribution supports <abbr title="Personal Package Archive">PPA</abbr>s, [I just learned how to make a PPA!](https://launchpad.net/~signofzeta/+archive/ubuntu/aprs-weather-submit)  You can install this with APT:

```bash
sudo add-apt-repository ppa:signofzeta/aprs-weather-submit
sudo apt update
sudo apt install aprs-weather-submit
```

If not, follow the instructions in `INSTALL.md` to configure it normally:
```bash
./autogen.sh
./configure [--enable-windows] [--disable-aprs-is] [--disable-debugging]
make
sudo make install
```

## MS-DOS and compatibles
Yeah, why not?  Install OpenWatcom and run `MAKE.BAT`.

## Windows
This app can be compiled using MinGW.  If other compilers work, please open an issue to let me know!

## Docker

Build and run the Home Assistant collector in a container with a persistent cache file:

1. Copy [.env.sample](.env.sample) to [.env](.env) and fill in required values.
2. Create an empty cache file so the bind mount is a file:

```bash
touch .pws-report.cache
```

3. Start the service:

```bash
docker compose up -d --build
```

The container runs [ha.sh](ha.sh) in a loop; configure the interval with `REPORT_INTERVAL` in [.env](.env). Windy uploads are limited to a minimum 300-second interval, and the loop cadence is derived from the configured interval with a 300-second minimum. The cache is persisted by bind-mounting [.pws-report.cache](.pws-report.cache).


## Legal Notices

To use this app, you *must* be either:

1.  a licensed amateur radio operator, or
2.  a member of the [Citizen Weather Observer Program](http://wxqa.com/) in good standing.

[Getting your ham radio license is easy](https://hamstudy.org/), and [joining CWOP is even easier](http://wxqa.com/SIGN-UP.html).

Like it says in the license:  this app is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the [GNU Affero General Public License 3.0](https://www.gnu.org/licenses/agpl-3.0.html) for more details.  As such, you and you alone are solely responsible for using this app to submit complete and correct weather and/or location data.  Please do not use this app for evil.  Don't make me regret writing this app.

QTH. 73, W1DNS
