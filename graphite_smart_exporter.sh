#!/usr/bin/env bash

VERSION=1.1.0
DESTINATION=                                # The destination where the Graphite server is reachable
PORT=2003                                   # The port the Graphite server listens on for the plaintext protocol
FREQUENCY=300                               # The frequency data is gathered and sent to graphite in
VERBOSE=0                                   # Default verbosity level
QUIET=0                                     # Does not write any output if set
OMIT_DRIVES_IN_STANDBY=1                    # Does not send the last known metrics for drives that are in standby
DISABLE_DRIVE_DETECTION=0                   # Disable drive detection using smartctl. Only enabled if devices to monitor are supplied as arguments
declare -A DRIVES                           # Associative array for detected drives, mapping to device type
declare -A DRIVES_SERIALS                   # Associateive array mapping a drive to its serial number
declare -A DRIVE_COMMON_TAGS                # Associative array for storing common drive tags
declare -A METRICS                          # Associative array keeping track of the metrics for each drive
TEMP_FILE_PREIFX=smartctl_output            # Name prefix of the temporary file smartctl output is stored in. jq seems to be more efficient when reading from file vs. getting the input piped to
LOG_FILE=""                                 # Log file name. File logging is only enabled if not empty.
SMART_TEMP_FILE_NAME="smart_output.json"    # Name of the temp file SMART output is written to. jq is more efficient when reading input from a file instead of piping the output to it.
METRIC_NAME_VALUE_DELIMITER=">>"            # Delimiter used between metric name and value when building metrics
SMART_POWER_STATUS_METRIC_NAME="smart_power_status" # Metric name indicating the power status (active or standby/sleep)

##
# Prints the help/usage message
##
function print_usage() {
    cat << EOF
Graphite S.M.A.R.T. exporter version ${VERSION}
Usage:
  $0 [-h] -d [-p] -n <HOSTNAME> [-f <FREQUENCY>] [-c] [-m <DEVICE>] [-t <DEVICE=TYPE> ] [-v] [-q] [-l <LOG_FILE>] [-s <SMART_TEMP_FILE_NAME>]

Gathers S.M.A.R.T. data about all S.M.A.R.T. capable drives in the system
and sends them as metrics to a Graphite server.

Options:
  -d DESTINATION            : The destnation IP address or host name under which the Graphite
                              server is reachable.
  -p PORT                   : The port the Graphite server is listening on for the plaintext protocol.
  -n HOSTNAME               : The host name to set for the metrics' 'instance' tag.
  -f FREQUENCY              : Frequency metrics are gathered and sent to Graphite with in seconds
                              (default: 300)
  -l LOG_FILE               : Name of the log file to log into. File logging is only enabled if a file name is provided. (default: empty)
  -c                        : Continue sending last known/stale data if a drive is in standby/spun down. If a drive is spun down, S.M.A.R.T. attributes 
                              cannot be read without waking it up. If this option is set, the script continues to send the last known S.M.A.R.T. 
                              metrics for a drive that is spun down to prevent gaps in data.
                              Otherwise no metrics are sent until the drive is awake again.
  -m DEVICE                 : List devices to monitor using this argument, once per drive to minor, e.g. -m /dev/sda -m /dev/sdc
  -t DEVICE=TYPE            : Manually specify the device type for a device. Use this if smartctl device type autodetection does not work for your case. Does NOT disable device discovery. Example: -t /dev/sda=nvme
  -s SMART_TEMP_FILE_NAME   : Name of the temp file the S.M.A.R.T. output is written to during each cycle the script is running.
                              Explicitly set if you plan on running multiple instances of this script to prevent collisions. (default: smart_output.json)
  -q                        : Quiet mode. Outputs are suppressed set. Can not be set if -v is set.
  -v                        : Verbose mode. Prints additional information during execution. File logging is only enabled in verbose mode. Can not be set if -q is set.
  -h                        : Print this help message.
Example usage:
$0 -d graphite.mydomain.com -n myhost
$0 -d graphite.mydomain.com -p 9198 -n myhost -f 600
$0 -d graphite.mydomain.com -n myhost -f 600 -o -m /dev/sda -m /dev/sdc -t /dev/sdc=sat
EOF
}

##
# Writes argument $1 to stdout if $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout
##
function log() {
    if [[ $QUIET -eq 0 ]]; then
        echo "time=$(date --iso-8601=seconds) level=info msg=$1"
        if [[ ! -z "$LOG_FILE" ]]; then
            echo "time=$(date --iso-8601=seconds) level=info msg=$1" >> $LOG_FILE
        fi
    fi
}

##
# Writes argument $1 to stdout if $VERBOSE is set and $QUIET is not set
#
# Arguments:
#   $1 Message to write to stdout
##
function log_verbose() {
    if [[ $VERBOSE -eq 1 ]] && [[ $QUIET -eq 0 ]]; then
        echo "time=$(date --iso-8601=seconds) level=debug msg=$1"
        if [[ ! -z "$LOG_FILE" ]]; then
            echo "time=$(date --iso-8601=seconds) level=debug msg=$1" >> $LOG_FILE
        fi
    fi
}

##
# Writes argument $1 to $LOG_FILE, appending to the file
#
# Arguments:
#   $1 Message to write to the log file
##
function log_file() {
    if [[ $VERBOSE -eq 1 ]] && [[ $QUIET -eq 0 ]] && [[ ! -z "$LOG_FILE" ]]; then
        echo "time=$(date --iso-8601=seconds) level=debug msg=$1" >> $LOG_FILE
    fi
}

##
# Writes argument $1 to stderr. Ignores $QUIET.
#
# Arguments:
#   $1 Message to write to stderr
##
function log_error() {
    >&2 echo "time=$(date --iso-8601=seconds) level=error msg=$1"
    if [[ ! -z "$LOG_FILE" ]]; then
        echo "time=$(date --iso-8601=seconds) level=error msg=$1" >> $LOG_FILE
    fi
}

##
# Manually sets the device type for a specific device. Useful if
# smartctl auto-detection does not work correctly.
#
# Arguments:
#   $1 Drive device type specification string in the form of <device>=<type>, e.g. /dev/sda=sat
##
function set_manual_device_type() {
    local drive=$(cut -d'=' -f1 <<<"$1")
    local device_type=$(cut -d'=' -f2 <<<"$1")
    if [ -z "$drive" || -z "$device_type" ]; then
        print_usage
    fi
    DRIVES[$drive]=$device_type
}

##
# Registers a new drive in $DRIVES array and detects if it is an ATA or SCSI
# drive.
#
# Arguemnts:
#   $1 Device identifier (e.g. /dev/ada0)
##
function register_drive() {
    local drive="$1"
    if [ -z "$drive" ]; then
        log_error "Failed to register drive. Empty name received."
        return 1
    fi
    # Check if we need to use a manually provided device type for querying SMART initially
    local device_type_argument=""
    if [ ! -z "${DRIVES[$drive]}" ]; then
        device_type_argument="-d ${DRIVES[$drive]}"
    fi

    local smart_output=$(smartctl --json=c -a $device_type_argument $drive)
    local common_tags=$(echo "$smart_output" | jq -r --arg HOSTNAME $HOSTNAME '
                              (.model_family // "" | gsub(" "; "_")) as $model_family
                            | (.model_name // "" | gsub(" "; "_")) as $model_name
                            | (.serial_number | tostring) as $serial_number
                            | .firmware_version as $firmware_version
                            | (.user_capacity.bytes | tostring) as $user_capacity_bytes
                            | (.device.name | sub("/dev/"; "")) as $device_name
                            | .device.type as $device_type
                            | if $model_name != "" then "model_name=\($model_name);" else "" end 
                            + if $model_family != "" then "model_family=\($model_family);" else "" end
                            + "serial_number=\($serial_number);"
                            + "firmware_version=\($firmware_version);"
                            + "user_capacity_bytes=\($user_capacity_bytes);"
                            + "device_name=\($device_name);"
                            + "device_type=\($device_type);"
                            + "instance=\($HOSTNAME)"')
    DRIVE_COMMON_TAGS[$drive]="$common_tags"

    # detect device type if not provided by command line argument
    if [ -z "${DRIVES[$drive]}" ]; then
        local device_type=$(echo "$smart_output" | jq -r '.device.type')
        DRIVES[$drive]=$device_type
    fi

    # store drive serial separately
    local serial_number=$(echo "$smart_output" | jq -r '.serial_number')
    DRIVES_SERIALS[$drive]="$serial_number"
}

##
# Detects all connected drives using plain iostat method and whether they are
# ATA or SCSI drives. Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: This function populates the $DRIVES array directly.
##
function detect_drives_smart() {
    local DRIVE_DEVS=$(smartctl --json=c --scan-open | jq -r '.devices[].name')

    # Detect protocol type (ATA or SCSI) for each drive and populate $DRIVES array
    for drive in ${DRIVE_DEVS}; do
        register_drive "$drive"
    done
}

##
# Retrieves the list of identifiers (e.g. "ada0") for all monitored drives.
# Drives listed in $IGNORE_DRIVES will be excluded.
#
# Note: Must be run after detect_drives().
##
function get_drives() {
    echo "${!DRIVES[@]}"
}


##
# Gets all SMART attributes for the provided drive, named already as metrics.
#
# Arguments:
# $1 The drive device ID to get SMART attributes for, e.g. /dev/sda
# 
# Returns
# A list of delimiter-separated (refer to $METRIC_NAME_VALUE_DELIMITER) SMART metrics with name tags. The smart_disk_info and smart_power_status metrics are always returned (if 
# no smartctl error occurred). Example:
# smart_status_passed;serial_number=2JHXXXXX>>1 smart_power_status;serial_number=2JHXXXXX>>1 smart_disk_info;model_name=WDC__WUH721818ALE6L4;model_family=Western_Digital_Ultrastar_DC_HC550;serial_number=2JHXXXXX;firmware_version=PCGNW680;user_capacity_bytes=18000207937536;device_name=sda;device_type=sat;instance=myhost.mydomain.com>>1
# OR smart_power_status;serial_number=2JHXXXXX>>1 smart_disk_info;model_name=WDC__WUH721818ALE6L4;model_family=Western_Digital_Ultrastar_DC_HC550;serial_number=2JHXXXXX;firmware_version=PCGNW680;user_capacity_bytes=18000207937536;device_name=sda;device_type=sat;instance=myhost.mydomain.com>>1 if the device is in standy and attributes could not be retrieved
# OR "error" on any other error returned by smartctl
##
function get_smart_metrics() {
    local drive="$1"
    declare -A attributes
    # Determine device type
    local device_type=${DRIVES[$drive]}
    # Get common drive tags
    local common_tags=${DRIVE_COMMON_TAGS[$drive]}
    # Get drive serial
    local serial_number=${DRIVES_SERIALS[$drive]}
    local disk_metrics=""
    # Read SMART attributes
    smartctl --json=c -a -n standby -d $device_type $drive  > $SMART_TEMP_FILE_NAME
    # If 0 < exit_status <= 7, an error performing smartctl occurred. However, if messages contains a message that contains the keyword
    # STANDBY or SLEEP, the device is in sleep mode and was not queried.
    # The following filter accounts for the possibility that there are no messages at all
    local exit_code=$(jq -r '.smartctl.exit_status as $exit_status 
                                | try .smartctl.messages[].string catch "" 
                                | (contains("STANDBY") or contains("SLEEP")) as $sleep 
                                | if ($exit_status > 0 and $exit_status <= 7 and $sleep) then "standby" elif ($exit_status > 0 and $exit_status <= 7) then "error" else . end ' $SMART_TEMP_FILE_NAME) 

    # Create an Info Metric with all the device's static tags
    local info_metric=$(echo "smart_disk_info;${common_tags}${METRIC_NAME_VALUE_DELIMITER}1")
    disk_metrics="${info_metric} ${disk_metrics}"

    # Determine power status (drive active or in standby/sleep)
    local smart_power_status=1
    if [ "$exit_code" == "standby" ]; then
        smart_power_status=0
    fi
    local smart_power_status_metric=$(echo "${SMART_POWER_STATUS_METRIC_NAME};serial_number=${serial_number}${METRIC_NAME_VALUE_DELIMITER}${smart_power_status}")
    disk_metrics="${smart_power_status_metric} ${disk_metrics}"

    # Exit status between 1 and 7 indicate either Standby or an hard error
    if [ ! -z "$exit_code" ]; then
        if [ "$exit_code" == "error" ]; then
            echo "$exit_code"
        fi
        # If the exit code is not "error", it means the disk is in standby.
        # In that case, we're going to return the metrics we have gathered thus far, that is the info metric and the power status metric.
    # All other exit codes yield SMART attributes
    else
       
        # Get SMART attributes depending on drive type
        case $device_type in
            "nvme")
                local nvme_attributes=$(jq -r --arg serial_number "$serial_number" --arg delim $METRIC_NAME_VALUE_DELIMITER '
                                                .nvme_smart_health_information_log 
                                                | keys[] as $key 
                                                | "smart_nvme_attribute;serial_number=\($serial_number);value_type=raw;attribute_name=\($key)\($delim)\(.[$key]|numbers)"' $SMART_TEMP_FILE_NAME)
                local temperature_sensors=$(jq -r --arg serial_number "$serial_number" --arg delim $METRIC_NAME_VALUE_DELIMITER '
                                                .nvme_smart_health_information_log.temperature_sensors 
                                                | keys[] as $key 
                                                | "smart_nvme_attribute;serial_number=\($serial_number);value_type=raw;attribute_name=temperature_sensor_\($key)\($delim)\(.[$key]|numbers)"' $SMART_TEMP_FILE_NAME)
                
                # Special metrics: Temperature, Power Cycle Count, Power on Time, Smart Status
                local additional_metrics=$(jq -r --arg serial_number "$serial_number" --arg delim $METRIC_NAME_VALUE_DELIMITER '
                                                "smart_device_temperature;serial_number=\($serial_number)\($delim)\(.temperature.current)",
                                                "smart_power_cycle_count;serial_number=\($serial_number)\($delim)\(.power_cycle_count)",
                                                "smart_power_on_time_hours;serial_number=\($serial_number)\($delim)\(.power_on_time.hours)",
                                                "smart_status_passed;serial_number=\($serial_number)\($delim)\(if .smart_status.passed then "1" else "0" end)"' $SMART_TEMP_FILE_NAME)
                disk_metrics="${nvme_attributes} ${temperature_sensors} ${additional_metrics} ${disk_metrics}"
            ;;
            "sat")
                smart_attributes=$(jq -r --arg serial_number "$serial_number" --arg delim $METRIC_NAME_VALUE_DELIMITER '
                                                .ata_smart_attributes.table[] 
                                                | "smart_attribute;serial_number=\($serial_number);value_type=value;attribute_id=\(.id);attribute_name=\(.name)\($delim)\(.value)",
                                                "smart_attribute;serial_number=\($serial_number);value_type=raw;attribute_id=\(.id);attribute_name=\(.name)\($delim)\(.raw.value)",
                                                "smart_attribute;serial_number=\($serial_number);value_type=thresh;attribute_id=\(.id);attribute_name=\(.name)\($delim)\(.thresh)",
                                                "smart_attribute;serial_number=\($serial_number);value_type=worst;attribute_id=\(.id);attribute_name=\(.name)\($delim)\(.worst)"' $SMART_TEMP_FILE_NAME)
                # Special metric: Temperature
                local additional_metrics=$(jq -r --arg serial_number "$serial_number" --arg delim $METRIC_NAME_VALUE_DELIMITER '
                                                "smart_device_temperature;serial_number=\($serial_number)\($delim)\(.temperature.current)",
                                                "smart_power_cycle_count;serial_number=\($serial_number)\($delim)\(.power_cycle_count)",
                                                "smart_power_on_time_hours;serial_number=\($serial_number)\($delim)\(.power_on_time.hours)",
                                                "smart_status_passed;serial_number=\($serial_number)\($delim)\(if .smart_status.passed then "1" else "0" end)"' $SMART_TEMP_FILE_NAME)
                disk_metrics="${smart_attributes} ${additional_metrics} ${disk_metrics}"
            ;;
        esac
        for disk_metric in "${disk_metrics}"; do
            echo $disk_metric
        done
    fi
    rm $SMART_TEMP_FILE_NAME
}

##
# Sends the metrics for all drives currently stored in global array
# METRICS to the Graphite server at DESTINATION on port PORT
##
function send_metrics {
    # get current time in Unix timestamp format, save in $time
    time=$(/bin/date +%s)
    local verbose=""
    if [ $VERBOSE -eq 1 ]; then
        verbose="-v"
    fi

    # only send if there are actually any metrics available
    if [ ${#METRICS[@]} -gt 0 ]; then
        for drive in ${!METRICS[@]}; do
            local metrics_for_drive=${METRICS[$drive]}
            # Check if we actually have metrics for that drive (might be in standby)
            if [ ! -z "$metrics_for_drive" ]; then
                for metric in $metrics_for_drive; do
                    local formatted_metric=$(echo "$metric" | sed -E "s/($METRIC_NAME_VALUE_DELIMITER)/ /")
                    echo "${formatted_metric} ${time}"
                done
            fi
        done | nc "${DESTINATION}" "${PORT}" -w2 $verbose
    fi
}

##
# Main program loop
##
function main() {
    log_verbose "Running SMART Graphite Exporter $VERSION"

    # Verify mandatory arguments
    if [ -z $DESTINATION ] || [ -z $HOSTNAME ]; then
        print_usage
        exit 1
    fi
    if [ $VERBOSE -eq 1 ] && [ $QUIET -eq 1 ]; then
        echo "Either set -v OR -o, not both!"
        print_usage
        exit 1
    fi

    # Replace dots '.' in hostname with underscores
    HOSTNAME_METRIC=${HOSTNAME//./_}
    HOSTNAME_METRIC=$HOSTNAME
    log_verbose "Destination Server: $DESTINATION"
    log_verbose "Port: $PORT"
    log_verbose "Hostname: $HOSTNAME"
    log_verbose "Hostname in metrics: $HOSTNAME_METRIC"
    log_verbose "Frequency: $FREQUENCY"
    log_verbose "Verbose: $VERBOSE"
    log_verbose "Disable drive detection: $DISABLE_DRIVE_DETECTION"
    log_verbose "Manually specified drives: $(get_drives)"

    local smart_power_status_regex="$SMART_POWER_STATUS_METRIC_NAME(;\S+=\S+)+>>(0|1)"

    # Identify drives if no drives were provided as arguments
    if [ $DISABLE_DRIVE_DETECTION -eq 0 ]; then
        detect_drives_smart
    fi

    for drive in ${!DRIVES[@]}; do
        log_verbose "Using drive ${drive} as ${DRIVES[$drive]} device"
    done

    log "Starting to send S.M.A.R.T. metrics with a frequency ${FREQUENCY} seconds: $(get_drives)"

    # Drive SMART monitoring loop
    while true; do
        for drive in "${!DRIVES[@]}"; do
            local SMART_METRICS=$(get_smart_metrics $drive)
            local power_status_metric=$(echo ${SMART_METRICS} | grep -Eo "${smart_power_status_regex}")
            # If the power status metrics ends with 0, the device is in standby
            if [[ "${power_status_metric}" == *0 ]]; then
                if [ $OMIT_DRIVES_IN_STANDBY -eq 0 ]; then
                    log_verbose "Drive ${drive} is in standby, sending last known metrics"
                    # Update power status in existing metrics by replacing it via regex
                    METRICS[$drive]=$(sed --regexp-extended "s/${smart_power_status_regex}/${SMART_METRICS}/" <<< "${METRICS[$drive]}")
                else
                    log_verbose "Drive ${drive} is in standby, will not send any metrics this cycle"
                    # Sets metrics to only inlcude the power status, as returned by get_smart_metrics
                    METRICS[$drive]="${SMART_METRICS}"
                fi
            fi

            if [ "${SMART_METRICS}" == "error" ]; then
                log "Error querying SMART attributes for drive ${drive}!"
            fi

            # Store metrics (empty if the drive is in standby)
            if [ "${SMART_METRICS}" != "error" ] && [ "${SMART_METRICS}" != "standby" ]; then
                log_verbose "Metrics for drive ${drive}: ${SMART_METRICS}"
                METRICS[$drive]=$SMART_METRICS
            fi

        done
        # Send metrics to Graphite server
        send_metrics
        # Wait for next cycle
        sleep $FREQUENCY
    done
}

# Parse arguments
while getopts "hd:p:n:vqf:cm:t:l:s:" opt; do
  case ${opt} in
    d ) DESTINATION=${OPTARG}
      ;;
    f ) FREQUENCY=${OPTARG}
      ;;
    l ) LOG_FILE=${OPTARG}
      ;;
    m ) register_drive ${OPTARG}
        DISABLE_DRIVE_DETECTION=1
      ;;
    n ) HOSTNAME=${OPTARG}
      ;;
    p ) PORT=${OPTARG}
      ;;
    c ) OMIT_DRIVES_IN_STANDBY=0
      ;;
    s ) SMART_TEMP_FILE_NAME=${OPTARG}
      ;;
    t ) set_manual_device_type ${OPTARG}
      ;;
    q ) QUIET=1
      ;;
    v ) VERBOSE=1
      ;;
    h ) print_usage; exit
      ;;
    \? ) print_usage; exit
      ;;
  esac
done

main # Start main program
