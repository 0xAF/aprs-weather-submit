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

## Home Assistant helper (ha.sh)

The script at [ha.sh](ha.sh) can pull weather sensor data from Home Assistant and build an `aprs-weather-submit` command with the converted values. It expects a [.env](.env) file in the repository root (same directory as the script) and uses `curl` and `jq`.

To get started, copy the sample file and fill in your values:

*   Copy [.env.sample](.env.sample) to [.env](.env).
*   Set `HA_API_TOKEN` (required) and optionally `HA_HOST`.
*   Configure sensor extraction with `HA_SENSOR_MATCH`, `HA_SENSOR_PREFIX`, and `HA_SENSOR_MAP`.
*   Provide your APRS settings (`APRS_CALLSIGN`, `APRS_LATITUDE`, `APRS_LONGITUDE`, `APRS_USERNAME`, `APRS_PASSWORD`).

Notes:

*   `APRS_ALTITUDE` is in meters; the script converts it to feet.
*   `LUX_EFFICACY` controls conversion from lux to W/m² (default 110).
*   `APRS_INTERVAL` controls APRS uploads (seconds, minimum 300).
*   `APRS_DRY_RUN` logs APRS output without sending (0/1).
*   `WINDY_ENABLED` toggles Windy uploads (0/1).
*   `WINDY_INTERVAL` controls Windy uploads (seconds, minimum 300).
*   The loop cadence is the GCD of APRS/Windy intervals, with a 30-second minimum.
*   `HA_SENSOR_MATCH` and `HA_SENSOR_PREFIX` control which Home Assistant entities are selected and how their IDs are trimmed.
*   `HA_SENSOR_MAP` maps script variable names to Home Assistant keys using `var_name:ha_key` pairs.
	Supported `var_name` values: `battery`, `temperature`, `humidity`, `wind_speed`, `wind_max_speed`, `wind_direction`, `rain_total`, `uv_index`, `outside_luminance`.
*   The script stores rain history in [.cache](.cache) for rolling calculations.
*   Windy uploads use metric units and omit missing fields. Set `WINDY_DRY_RUN=1` to log without sending.

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

Build and run the Home Assistant helper in a container with a persistent cache file:

1. Copy [.env.sample](.env.sample) to [.env](.env) and fill in required values.
2. Create an empty cache file so the bind mount is a file:

```bash
touch .cache
```

3. Start the service:

```bash
docker compose up -d --build
```

The container runs [ha.sh](ha.sh) in a loop; configure intervals with `APRS_INTERVAL` and `WINDY_INTERVAL` in [.env](.env). Windy uploads are limited to a minimum 300-second interval, and the loop cadence is the GCD of the configured intervals with a 30-second minimum. The cache is persisted by bind-mounting [.cache](.cache).


## Legal Notices

To use this app, you *must* be either:

1.  a licensed amateur radio operator, or
2.  a member of the [Citizen Weather Observer Program](http://wxqa.com/) in good standing.

[Getting your ham radio license is easy](https://hamstudy.org/), and [joining CWOP is even easier](http://wxqa.com/SIGN-UP.html).

Like it says in the license:  this app is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the [GNU Affero General Public License 3.0](https://www.gnu.org/licenses/agpl-3.0.html) for more details.  As such, you and you alone are solely responsible for using this app to submit complete and correct weather and/or location data.  Please do not use this app for evil.  Don't make me regret writing this app.

QTH. 73, W1DNS
