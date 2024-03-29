#!/bin/bash

# The WABAC Machine.
#
# This script creates incremental backups with a smart retention strategy.
# It's obviously inspired by Apple's Time Machine.
# All credits to rsync devs.
# Copyright François KUBLER, 2009-2021.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.


#
#-------------------------------------------------------------------------------
#
# WELCOME TO THE SOURCE.
#
# You shouldn't need to edit anything. But you are free to do so :)
#
# Feedback, bugreports, patches and pull requests are welcome :
# https://github.com/Frzk/WABACMachine
#
# Remember that the WABAC Machine has a configuration file where you can set a
# few preferences.
#
# Also remember that the WABAC Machine supports preflight and postflight
# scripts. These might help you suit your needs.
#
# EDIT CAREFULLY BEHIND THIS LINE.
#
#-------------------------------------------------------------------------------
#


# # #   FUNCTIONS   # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

main()
{
    local exit_code
    local excl

    # Loaded from conf file :
    local source                # What we want to backup.
    local destination           # Where we want to store the backups.
    local opts                  # rsync options.
    local nb_hours              #
    local nb_days               #
    local nb_weeks              #
    local nb_months             #
    local exclude_file          # rsync exclusion file.
    local preflight             # pre-flight script.
    local postflight            # post-flight script.
    local rsync_path            # Custom rsync path.

    # Some defaults values :
    exit_code=0
    nb_hours="1"
    nb_days="31"
    nb_weeks="52"
    nb_months="24"
    exclude_file=""
    preflight=""
    postflight=""
    rsync_path=""

    CONFIG="${PROGDIR}/WABACMachine.conf"   # Default config file -- Use the '-c' option to change the value.

    # Read arguments.
    read_args "${@}" \
        || exit $?

    # Usage ?
    [ "${ACTION}" = "usage" ] \
        && display_usage

    # Help ?
    [ "${ACTION}" = "help" ] \
        && display_help


    # After this line, we have to be root.

    # Check if root.
    check_root \
        || exit $?

    # Setup traps.
    setup_traps

    # Load conf.
    if [ "${ACTION}" != "init" ]
    then
        load_config "${CONFIG}" \
            || exit $?
    fi

    # Do we have an exclude file ? If so, we probably have to modify opts.
    if excl=$(check_exclude_file "${exclude_file}")
    then
        if [ -n "${excl}" ]
        then
            opts+=("${excl}")
        else
            exclude_file="None"
        fi
    else
        exit $?
    fi


    # Now we can make all config var readonly :
    readonly source
    readonly destination
    readonly opts
    readonly nb_hours
    readonly nb_days
    readonly nb_weeks
    readonly nb_months
    readonly exclude_file
    readonly preflight
    readonly postflight
    readonly rsync_path
    readonly CONFIG


    # Run preflight.
    run_preflight "${preflight}" \
        || exit $?

    # Backup, remove expired, output info, init, ...
    if [ "${ACTION}" = "init" ]
    then
        init "${CLI_SOURCE}" "${CLI_DESTINATION}" "${CONFIG}"
        exit_code=$?
    else
        # Dry run.
        contains "--dry-run" "${opts[@]}"
        readonly DRYRUN=$?

        # Starting...
        printf -- "Starting the WABAC Machine"
        if [ "${DRYRUN}" -eq 0 ]
        then
            printf -- " in DRY RUN MODE"
        fi
        printf -- " with:\n  Action: %s\n  Config: %s\n  Source: %s\n  Destination: %s\n" "${ACTION}" "${CONFIG}" "${source}" "${destination}"

        # Check source.
        check_source "${source}" \
            || exit $?

        # Check destination.
        check_destination "${destination}" \
            || exit $?

        # Lock.
        lock \
            || exit $?

        # Backup ?
        if [ "${ACTION}" = "backup" ]
        then
            backup "${source}" "${destination}" "${exclude_file}" "${opts[*]}"
            exit_code=$?
        fi

        # Remove expired ?
        if { [ "${ACTION}" = "backup" ] && [ "${exit_code}" -eq 0 ] && [ -z "${KEEP_EXPIRED}" ]; } || [ "${ACTION}" = "remove-expired" ]
        then
            remove_expired "${destination}" "${nb_hours}" "${nb_days}" "${nb_weeks}" "${nb_months}"
        fi

        # Info.
        info_destination "${destination}"

        # Unlock.
        unlock
    fi

    # Run postflight.
    run_postflight "${postflight}"

    # Exits (actually, this is trapped and `handle_exit` will do the job).
    exit ${exit_code}
}



read_args()
{
    # Reads the arguments

    local exit_code=0

    while :
    do
        case "${1}" in
            backup|info|remove-expired)
                readonly ACTION="${1}"
                shift
                ;;

            help)
                readonly ACTION="help"
                break
                ;;

            init)
                if [ $# -lt 3 ]
                then
                    printf -- "Usage: %s init <source> <destination> [-c | --config <filename>]\n" "${PROGNAME}" 1>&2
                    exit 1
                else
                    readonly ACTION="init"
                    readonly CLI_SOURCE="${2}"
                    readonly CLI_DESTINATION="${3}"
                    shift 3
                fi
                ;;

            -k|--keep-expired)
                readonly KEEP_EXPIRED=1
                shift
                ;;

            -c|--config)
                CONFIG="${2}"
                shift 2
                ;;

            --) # End of all options
                shift
                break
                ;;

            -*) # Unsupported option
                printf -- "Error: Unsupported option (%s).\n" "${1}" 1>&2
                exit_code=1
                break
                ;;

            *)  # No more options
                break
                ;;
        esac
    done

    return ${exit_code}
}



load_config()
{
    # Checks if the config file exists.
    # When no config file has been specified, falls back to the default one.
    # Then, loads it.

    local -r cnf="${1}"; shift

    # shellcheck source=/dev/null
    source "${cnf}" 2>/dev/null
    local -r exit_code=$?

    if [ "${exit_code}" -ne 0 ]
    then
        printf -- "Config file (%s) could not be read. Does it exist ?\n" "${cnf}" 1>&2
    fi

    return ${exit_code}
}



check_exclude_file()
{
    # Checks if the provided exclusion file exists and is readable.

    local exit_code=0
    local -r exclude_file="${1}"; shift

    if [ -n "${exclude_file}" ]     # Checks that exclude_file is set AND not empty.
    then
        if [ -f "${exclude_file}" ]     # Readable file ?
        then
            printf -- "--exclude-from=%s" "${exclude_file}"
        else
            printf -- "The given exclude file does not exist (%s). Please fix your config file.\n" "${exclude_file}" 1>&2
            exit_code=1
        fi
    fi

    return ${exit_code}
}



check_source()
{
    # Checks if the source is readable.

    local exit_code=1
    local -r src="${1}"; shift

    if [ -n "${src}" ]
    then
        if [ -r "${src}" ]
        then
            exit_code=0
        else
            printf -- "The provided source (%s) is not readable !\n" "${src}" 1>&2
        fi
    else
        printf -- "Source is not defined. Please fix your config file.\n" 1>&2
    fi

    return ${exit_code}
}



check_destination()
{
    # Checks if the destination is explicitly marked as being a destination for the WABAC Machine.
    # Also checks if it is writeable.

    local exit_code=1
    local -r dst="${1}"; shift

    if [ -n "${dst}" ]
    then
        if [ -f "${dst}/.wabac_machine_is_present" ]
        then
            if [ -w "${dst}" ]
            then
                exit_code=0
            else
                printf -- "The provided destination (%s) is not writeable !\n" "${dst}" 1>&2
            fi
        else
            printf -- "The provided destination (%s) is not marked as being a destination for the WABAC Machine.\n" "${dst}" 1>&2
        fi
    else
        printf -- "Destination is not defined. Please fix your config file.\n" 1>&2
    fi

    return ${exit_code}
}



init()
{
    # Initializes a new WABAC Machine :
    #     - Marks the given directory as a destination for the WABAC Machine.
    #     - Creates a new default configuration file with the given source and destination.

    local exit_code=0
    local -r src="${1}"; shift
    local -r dst="${1}"; shift
    local -r cnf="${1}"; shift

    if [ "${exit_code}" -eq 0 ]
    then
        # Create a default config file :
        if [ ! -f "${cnf}" ]
        then
            create_conf "${cnf}" "${src}" "${dst}"
            exit_code=$?

            if [ "${exit_code}" -eq 0 ]
            then
                chmod 600 "${cnf}"
                exit_code=$?
            fi

            if [ "${exit_code}" -ne 0 ]
            then
                printf -- "An error occured while creating the config file (%s). Please check that it is complete and 'chmod 600' it.\n" "${cnf}" 1>&2
            fi
        else
            exit_code=1
            printf -- "The provided configuration file (%s) already exists. I am NOT going to overwrite it. Please chose another file or remove this one.\n" "${cnf}" 1>&2
        fi
    fi

    # Mark destination as being ready for the WABAC Machine :
    if [ "${exit_code}" -eq 0 ]
    then
        touch -- "${dst}/.wabac_machine_is_present"
        exit_code=$?
    fi

    if [ "${exit_code}" -eq 0 ]
    then
        printf -- "The WABAC Machine has been successfully initialized.\n"

        if [ "${PLATFORM}" = "OSX" ]
        then
            printf -- "\nCAUTION:\nThe WABAC Machine detected that you are running OSX.\n"
            printf -- "If you are backing up data stored on an HFS+ volume, you might need a custom version of rsync.\n"
            printf -- "You might also need to enable a few options in your config file (%s).\n" "${cnf}"
            printf -- "See instructions here : https://github.com/Frzk/WABACMachine/wiki/Running-on-OSX\n\n"
        fi

        if [ "${cnf}" != "{PROGDIR}/WABACMachine.conf" ]
        then
            printf -- "Run 'WABACMachine.sh backup -c %s' as root to create a new backup.\n" "${cnf}"
        else
            printf -- "Run 'WABACMachine.sh backup' as root to create a new backup.\n"
        fi
        printf -- "Run 'WABACMachine.sh help' to get some help.\n"
    fi

    return ${exit_code}
}



run_preflight()
{
    # Runs the given script.

    local exit_code=0
    local -r script="${1}"; shift

    if [ -n "${script}" ]       # Do we have a pre-flight script to run ?
    then
        if [ -x "${script}" ]   # Is it executable ?
        then
            # shellcheck source=/dev/null
            source "${script}"  # Run it !
            exit_code=$?
        else
            printf -- "The preflight script (%s) does not exist or cannot be executed. Please fix your config file.\n" "${script}" 1>&2
            exit_code=1
        fi
    fi

    return ${exit_code}
}



run_postflight()
{
    # Runs the given script.

    local exit_code=0
    local -r script="${1}"; shift

    if [ -n "${script}" ]       # Do we have a postflight script to run ?
    then
        if [ -x "${script}" ]   # Is it executable ?
        then
            # shellcheck source=/dev/null
            source "${script}"  # Run it !
            exit_code=$?
        else
            printf -- "The postflight script (%s) does not exist or cannot be executed. Please fix your config file.\n" "${script}" 1>&2
            exit_code=1
        fi
    fi

    return ${exit_code}
}



backup()
{
    # Creates a new backup.
    # It's a basic call to rsync <3

    local exit_code=0

    # Source:
    local -r src="${1}"; shift
    # Destination:
    local -r dst="${1}"; shift
    # Exclude file:
    local -r exclude_file="${1}"; shift
    # Now-datetime:
    local -r now=$(date "+%Y-%m-%d-%H%M%S")
    # Now-datetime (timestamp format)
    local -r now_t=$(date "+%Y%m%d%H%M.%S")

    # rsync options:
    local opts=("${@}")
    # Reference backup:
    local ref
    # 0 if rsync ran successfully, allows us to restart the backup process when destination volume is full:
    local completed=1
    # Path to rsync binary
    local rsync_cmd
    # rsync output (will be parsed later):
    local rsync_output
    # Latest successful backup:
    local latest

    printf -- "  Exclude file: %s\n" "${exclude_file}"

    # See if we can take advantage of an existing backup and use the --link-dest option.
    if [ -h "${dst}/latest" ]
    then
        ref=$(readlink "${dst}/latest")
        opts+=(--link-dest="${dst}/latest")
    else
        ref="None (new backup)"
    fi
    printf -- "  Reference: %s\n" "${ref}"


    # Backup.

    # Get rsync path :
    rsync_cmd=$(get_rsync "${rsync_path}" 2>&1)
    exit_code=$?

    if [ "${exit_code}" -eq 0 ]
    then
        # Start the backup process.
        while [ "${completed}" -gt 0 ]
        do
            rsync_output=$($rsync_cmd ${opts[@]} -- "${src}" "${dst}/inProgress" 2>&1)
            exit_code=$?

            completed=$(grep -c "No space left on device (28)\|Result too large (34)" <<< "${rsync_output}")

            if [ "${completed}" -gt 0 ]
            then
                if ! remove_oldest "${dst}"
                then
                    completed=0     # Ends the while loop.
                    rsync_output=$(printf -- "No more space available on %s.\n" "${dst}")  # Will be printed later.
                    exit_code=1
                fi
            fi
        done
    else
        rsync_output="${rsync_cmd}"
    fi

    # Handle exit codes. We have 4 cases :
    #     0  : Everything is OK, we just have to rotate the backups and purge them.
    #     24 : Some files have vanished during the backup. We still consider the backup as OK.
    #     23 : Some files/attrs were not transferred (in most cases, this is an ACL issue). We still consider the backup as OK but a message is printed on STDERR.
    #     *  : Something went wrong ! We keep everything in the current state.
    case "${exit_code}" in
        0|23|24)
            if [ "${DRYRUN}" -gt 0 ]
            then
                # Rename the "inProgress" backup :
                touch -a -m -c -t "${now_t}" -- "${dst}/inProgress"
                mv -- "${dst}/inProgress" "${dst}/${now}"

                # Build the `latest` link :
                latest=$(get_latest_snapshot "${dst}")
                ln -sfn -- "${latest}" "${dst}/latest"
            fi

            # Print some information :
            info_backup "${rsync_output}"

            if [ "${exit_code}" -eq 23 ]
            then
                printf -- "Warning: there might be an ACL issue :\n%s" "${rsync_output}" 1>&2
            fi

            exit_code=0     # Reset `exit_code` to zero since we consider the backup as OK.
            ;;

        *)
            printf -- "Error: An error occured while backing up (%s). The backup might be incomplete or corrupt ! Details :\n%s\n" "${exit_code}" "${rsync_output}" 1>&2
            ;;
    esac

    return ${exit_code}
}



get_snapshots()
{
    local -r dst="${1}"; shift

    find "${dst}" -maxdepth 1 -type d \
        | grep -E "${DATE_REGEXP}" \
        | sort
}



count_snapshots()
{
    local -r dst="${1}"; shift

    get_snapshots "${dst}" \
        | wc -l \
        | tr -d " "
}



get_oldest_snapshot()
{
    local -r dst="${1}"; shift

    get_snapshots "${dst}" \
        | head -n 1
}



get_latest_snapshot()
{
    local -r dst="${1}"; shift

    get_snapshots "${dst}" \
        | tail -n 1
}



date_latest_snapshot()
{
    # Retrieves the date of the latest successful snapshot.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r dst="${1}"; shift
    local -r latest=$(get_latest_snapshot "${dst}")
    local -r tstamp=$(date_timestamp "${latest}")

    date_timestamp_to_hr "${tstamp}"
}



date_oldest_snapshot()
{
    # Retrieves the date of the latest successful snapshot.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r dst="${1}"; shift
    local -r oldest=$(get_oldest_snapshot "${dst}")
    local -r tstamp=$(date_timestamp "${oldest}")

    date_timestamp_to_hr "${tstamp}"
}



date_timestamp()
{
    # Retrieves the date of creation of the given directory.
    # Output format is "+%s" (UNIX timestamp).

    local -r directory="${1}"; shift

    case "${PLATFORM}" in
        OSX|BSD)
            stat -f "%m" "${directory}"
            ;;
        Linux)
            stat -c %y "${directory}" \
                | cut -f 1 -d" "
            ;;
        *)
            printf -- "FIXME: date_timestamp isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_timestamp_to_hr()
{
    # Given a timestamp date, returns it in a human readable format (+%F, YYYY-MM-DD).

    local -r tstamp="${1}"; shift

    case "${PLATFORM}" in
        OSX|BSD)
            date -jf "%s" "${tstamp}" "+%F"
            ;;
        Linux)
            date --date "${tstamp}" "+%F"
            ;;
        *)
            printf -- "FIXME: date_timestamp_to_hr isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_year_of()
{
    # Returns the year of the given date.
    # Output format is "+%Y" (YYYY).

    local -r d="${1}"; shift

    case "${PLATFORM}" in
        OSX|BSD)
            date -jf "%F" "${d}" "+%Y"
            ;;
        Linux)
            date --date "${d}" "+%Y"
            ;;
        *)
            printf -- "FIXME: date_year_of isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_build()
{
    # Build a date.

    local -r y="${1}"; shift
    local -r m="${1}"; shift
    local -r d="${1}"; shift

    case "${PLATFORM}" in
        OSX|BSD)
            date -jf "%F" "${y}-${m}-${d}" "+%F"
            ;;
        Linux)
            date --date "${y}-${m}-${d}" "+%F"
            ;;
        *)
            printf -- "FIXME: date_build isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_start_of_week()
{
    # Given a date, computes the date of the first day of the week.
    # Weeks start on Sundays.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r d="${1}"; shift

    case "${PLATFORM}" in
        OSX|BSD)
            date -v-sun -jf "%F" "${d}" "+%F"
            ;;
        Linux)
            date --date "${d}" -d "last sunday" "+%F"
            ;;
        *)
            printf -- "FIXME: date_start_of_week isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_start_of_month()
{
    # Given a date, computes the date of the first day of the month.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r d="${1}"; shift
    local cur_month
    local cur_year

    case "${PLATFORM}" in
        OSX|BSD)
            cur_month=$(date -jf "%F" "${d}" "+%m")
            cur_year=$(date -jf "%F" "${d}" "+%Y")
            date_build "${cur_year}" "${cur_month}" "01"
            ;;
        Linux)
            cur_month=$(date --date "${d}" "+%m")
            cur_year=$(date --date "${d}" "+%Y")
            date_build "${cur_year}" "${cur_month}" "01"
            ;;
        *)
            printf -- "FIXME: date_start_of_month isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_add_day()
{
    # Returns the given date + n days.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r d="${1}"; shift
    local -r n="${1}"; shift    # Number of days to add. Has to be prepend by '+' or '-'.

    case "${PLATFORM}" in
        OSX|BSD)
            date -v"${n}"d -jf "%F" "${d}" "+%F"
            ;;
        Linux)
            date --date "${d} ${n}day" "+%F"
            ;;
        *)
            printf -- "FIXME: date_add_day isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_add_week()
{
    # Returns the given date + n weeks.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r d="${1}"; shift
    local -r n="${1}"; shift    # Number of weeks to add. Has to be prepend by '+' or '-'.

    case "${PLATFORM}" in
        OSX|BSD)
            date -v"${n}"w -jf "%F" "${d}" "+%F"
            ;;
        Linux)
            date --date "${d} ${n}week" "+%F"
            ;;
        *)
            printf -- "FIXME: date_add_week isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_add_month()
{
    # Returns the given date + n months.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r d="${1}"; shift
    local -r n="${1}"; shift    # Number of months to add. Has to be prepend by '+' or '-'.

    case "${PLATFORM}" in
        OSX|BSD)
            date -v"${n}"m -jf "%F" "${d}" "+%F"
            ;;
        Linux)
            date --date "${d} ${n}month" "+%F"
            ;;
        *)
            printf -- "FIXME: date_add_month isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



date_add_year()
{
    # Returns the given date + n years.
    # Output format is "+%F" (YYYY-MM-DD).

    local -r d="${1}"; shift
    local -r n="${1}"; shift    # Number of years to add. Has to be prepend by '+' or '-'.

    case "${PLATFORM}" in
        OSX|BSD)
            date -v"${n}"y -jf "%F" "${d}" "+%F"
            ;;
        Linux)
            date --date "${d} ${n}year" "+%F"
            ;;
        *)
            printf -- "FIXME: date_add_year isn't supported on this platform (%s).\n" "${PLATFORM}" 1>&2
            ;;
    esac
}



info_backup()
{
    # Prints out some information about the just-ending backup process.
    # Requires rsync to run with the "--stats" and "--human-readable" options.

    local -r rsync_output="${1}"; shift                                 # rsync output to parse
    local -r total_nb_files=$(parse_total_nb_files "${rsync_output}")   # Total number of backed up files
    local -r total_size=$(parse_total_size "${rsync_output}")           # Total size of backed up data
    local -r nb_files=$(parse_nb_files "${rsync_output}")               # Number of files actually copied
    local -r size=$(parse_size "${rsync_output}")                       # Size of data actually copied
    local -r speedup=$(parse_speedup "${rsync_output}")                 # rsync speedup
    local -r duration=$(compute_time_spent "${rsync_output}")           # Duration

    printf -- "Successfully backed up %s files (%s) in %s seconds.\n" "${total_nb_files}" "${total_size}" "${duration}"
    printf -- "Actually copied %s files (%s) - Speedup : %s.\n" "${nb_files}" "${size}" "${speedup}"
}



parse_total_nb_files()
{
    local -r rsync_output="${1}"; shift

    grep "Number of files:" \
        <<< "${rsync_output}" \
        | cut -d " " -f 4
}



parse_total_size()
{
    local -r rsync_output="${1}"; shift

    grep "Total file size:" \
        <<< "${rsync_output}" \
        | cut -d " " -f 4
}



parse_nb_files()
{
    local -r rsync_output="${1}"; shift

    grep -E "Number of (regular )?files transferred:" \
        <<< "${rsync_output}" \
        | grep -oE "[^ ]+$"
}



parse_size()
{
    local -r rsync_output="${1}"; shift

    grep "Total transferred file size:" \
        <<< "${rsync_output}" \
        | cut -d " " -f 5
}



parse_speedup()
{
    local -r rsync_output="${1}"; shift

    grep "speedup" \
        <<< "${rsync_output}" \
        | cut -d " " -f 8
}



parse_file_list_generation_time()
{
    local -r rsync_output="${1}"; shift

    grep "File list generation time" \
        <<< "${rsync_output}" \
        | cut -d " " -f 5
}



parse_file_list_transfer_time()
{
    local -r rsync_output="${1}"; shift

    grep "File list transfer time" \
        <<< "${rsync_output}" \
        | cut -d " " -f 5
}



calc()
{
    awk "BEGIN { print $*}";
}



compute_time_spent()
{
    local -r rsync_output="${1}"; shift

    local -r flgt=$(parse_file_list_generation_time "${rsync_output}")
    local -r fltt=$(parse_file_list_transfer_time "${rsync_output}")

    local -r sum="${flgt} + ${fltt}"

    calc "${sum}"
}



info_destination()
{
    # Prints out some information about the backups.

    local -r dst="${1}"; shift
    local -r nb=$(count_snapshots "${dst}")
    local -r oldest=$(get_oldest_snapshot "${dst}")
    local -r latest=$(get_latest_snapshot "${dst}")
    local -r space=$(space_left "${dst}")

    printf -- "%s backups available.\n" "${nb}"

    [ -n "${oldest}" ] \
        && printf -- "Oldest is %s.\n" "${oldest}"

    [ -n "${latest}" ] \
        && printf -- "Latest is %s.\n" "${latest}"

    printf -- "%s left on %s.\n" "${space}" "${dst}"
}



space_left()
{
    local -r dst="${1}"; shift

    df -P -h -- "${dst}" \
        | tail -n 1 \
        | tr -s " " \
        | cut -d " " -f 4
}



keep_all()
{
    # Keeps **everything** for the last $2 hours.

    local -r dst="${1}"; shift              # Destination.
    local -r hours=$((${1}*60)); shift      # Number of hours.

    find "${dst}" -maxdepth 1 -type d -mmin -"${hours}" \
        | grep -E "${DATE_REGEXP}" \
        | sort
}



keep_one_per_day()
{
    # Keeps one backup per day for the last $2 days.

    local -r dst="${1}"; shift          # Destination.
    local -r limit="${1}"; shift        # Number of days.

    local d1
    local d2
    local i

    d1=$(date_latest_snapshot "${dst}")

    for ((i=0 ; i<limit ; i++))
    do
        d2=$(date_add_day "${d1}" "+1")

        keep_between "${dst}" "${d1}" "${d2}"

        d1=$(date_add_day "${d1}" "-1")
    done
}



keep_one_per_week()
{
    # Keeps one backup per week for the last $2 weeks.

    local -r dst="${1}"; shift          # Destination.
    local -r limit="${1}"; shift        # Number of weeks.

    local -r latest=$(date_latest_snapshot "${dst}")

    local d1
    local d2
    local i

    d1=$(date_start_of_week "${latest}")

    for ((i=0 ; i<limit ; i++))
    do
        d2=$(date_add_week "${d1}" "+1")

        keep_between "${dst}" "${d1}" "${d2}"

        d1=$(date_add_week "${d1}" "-1")
    done
}



keep_one_per_month()
{
    # Keeps one backup per month for the last $2 months.

    local -r dst="${1}"; shift          # Destination.
    local -r limit="${1}"; shift        # Number of months.

    local -r latest=$(date_latest_snapshot "${dst}")

    local d1
    local d2
    local i

    d1=$(date_start_of_month "${latest}")

    for ((i=0 ; i<limit ; i++))
    do
        d2=$(date_add_month "${d1}" "+1")

        keep_between "${dst}" "${d1}" "${d2}"

        d1=$(date_add_month "${d1}" "-1")
    done
}



keep_one_per_year()
{
    # Keeps one backup per year, without limit.

    local -r dst="${1}"; shift

    local -r oldest=$(date_oldest_snapshot "${dst}")
    local -r first_year=$(date_year_of "${oldest}")
    local -r now_year=$(date_year_of "$(date "+%F")")

    local d1
    local d2
    local i

    for ((i=first_year ; i<now_year ; i++))
    do
        d1=$(date_build "${i}" "01" "01")
        d2=$(date_add_year "${d1}" "+1")

        keep_between "${dst}" "${d1}" "${d2}"
    done
}



keep_between()
{
    # Keeps one backup betwen the two given dates (interval [$1 ; $2[)

    local -r dst="${1}"; shift      # Destination.
    local -r d1="${1}"; shift       # Oldest date of the considered dates interval.
    local -r d2="${1}"; shift       # Latest date of the considered dates interval.

    find "${dst}" -maxdepth 1 -type d \( -newermt "${d1}" -a ! -newermt "${d2}" \) \
        | grep -E "${DATE_REGEXP}" \
        | sort \
        | tail -n 1
}



remove_expired()
{
    # Removes expired backups.

    local -r dst="${1}"; shift              # Destination.
    local -r nb_hours="${1}"; shift         # Number of hours.
    local -r nb_days="${1}"; shift          # Number of days.
    local -r nb_weeks="${1}"; shift         # Number of weeks.
    local -r nb_months="${1}"; shift        # Number of months.
    local -r keep_file="${PROGDIR}/wabac.running/keep"  # File that lists snapshots to keep.

    {
        keep_all "${dst}" "${nb_hours}"
        keep_one_per_day "${dst}" "${nb_days}"
        keep_one_per_week "${dst}" "${nb_weeks}"
        keep_one_per_month "${dst}" "${nb_months}"
        keep_one_per_year "${dst}"
    } > "${keep_file}"

    remove_useless "${dst}" "${keep_file}"
}



remove_useless()
{
    # Removes useless backups (those that are **NOT** listed in the given `keep_file`).

    local -r dst="${1}"; shift              # Destination.
    local -r keep_file="${1}"; shift        # File that lists snapshots **TO KEEP**.

    local -r snapshots_file="${PROGDIR}/wabac.running/backups"      # File that lists all existing snapshots.
    local -r kickout="${PROGDIR}/wabac.running/kickout"             # File that lists snapshots to delete.

    # Builds the list of backups to remove :
    #   Sorts the two files, merges them and removes duplicates.
    #   See `man sort` for further details.
    #   See `man uniq` for further details.
    get_snapshots "${dst}" \
        > "${snapshots_file}"

    sort -- "${keep_file}" "${snapshots_file}" \
        | uniq -u > "${kickout}"

    # Removes what's useless :
    local -r rm_count=$(wc -l < "${kickout}" | tr -d " ")

    case "${rm_count}" in
        0)
            printf -- "%s expired backup found.\n" "No"
            ;;
        1)
            printf -- "%s expired backup will be removed.\n" "One"
            ;;
        *)
            printf -- "%s expired backups will be removed.\n" "${rm_count}"
            ;;
    esac

    while read -r snap
    do
        remove_backup "${snap}"
    done < "${kickout}"

    rm -f -- "${snapshots_file}"
    rm -f -- "${keep_file}"
    # We keep the kickout file, just in case.
    # It will be removed if the WABAC Machine exits successfully.
}



remove_backup()
{
    # Removes the given backup.

    local bck="${1}"           # Backup to delete.

    if [ "${DRYRUN}" -gt 0 ]
    then
        rm -Rf "${bck}"
        printf -- "Deleted %s.\n" "${bck}"
    else
        printf -- "I would have deleted %s.\n" "${bck}"
    fi
}



remove_oldest()
{
    # Removes the oldest backup, only if it's not the only one remaining.

    local -r dst="${1}"; shift      # Destination

    local -r nb_backups=$(count_snapshots "${dst}")

    local exit_code=0

    if [ "${nb_backups}" -gt 1 ]
    then
        local -r oldest=$(get_oldest_snapshot "${dst}")
        remove_backup "${oldest}"
    else
        printf -- "Can't remove the oldest backup : it's the last one remaining.\n" 1>&2
        exit_code=1
    fi

    return ${exit_code}
}



lock()
{
    # Creates a lock to ensure we run only one instance at the same time.
    # We use mkdir because it is atomic.

    local -r exit_code=$?
    local -r lockdir="${PROGDIR}/wabac.running"
    local -r mkdir_output=$(mkdir -- "${lockdir}" 2>&1)

    if [ "${exit_code}" -eq 0 ]
    then
        echo $$ > "${lockdir}/pid"
    else
        printf -- "Could not acquire lock : %s (probably hold by %s).\n" "${mkdir_output}" "$(<"${lockdir}"/pid)"
    fi

    return ${exit_code}
}



unlock()
{
    # Allows another instance of the WABAC Machine to run.
    # As we store every temp file in the lockdir directory, it also deletes those.

    local -r lockdir="${PROGDIR}/wabac.running"

    rm -Rf "${lockdir}"
}



setup_traps()
{
    # Setup traps.
    #   The following signals are trapped : EXIT, TERM, HUP, QUIT and INT.

    trap "handle_exit" EXIT
    trap "handle_sigs" TERM HUP QUIT INT
}



remove_traps()
{
    # Remove previously setup traps.

    trap - TERM HUP QUIT INT EXIT
}



handle_sigs()
{
    # Handle trapped signals.

    local sig
    local signame

    sig=$?

    if [ "${sig}" -gt 127 ]
    then
        sig=$(( sig-128 ))
        signame="SIG"$(kill -l -- "${sig}")
    else
        signame="RSYNC_INTERRUPTED"
    fi

    printf -- "Received %s. Backup interrupted !\n" "${signame}" 1>&2

    # Propagate :
    kill -s "${sig}" $$
}



handle_exit()
{
    # This is the exit door of the WABAC Machine.

    errno=$?

    remove_traps
    exit ${errno}
}



get_rsync()
{
    local exit_code
    local rsync_cmd

    exit_code=0
    rsync_cmd="${1}"; shift

    if [ -n "${rsync_cmd}" ]      # A path is specified in the config file.
    then
        if [ ! -f "${rsync_cmd}" ] || [ ! -x "${rsync_cmd}" ]
        then
            printf -- "Could not find a suitable rsync executable at the provided path (%s).\n" "${rsync_cmd}" 1>&2
            rsync_cmd=""
            exit_code=2
        fi
    else                    # Let's try the "standards" paths.
        if [ -f "/usr/bin/rsync" ] && [ -x "/usr/bin/rsync" ]
        then
            rsync_cmd="/usr/bin/rsync"
        elif [ -f "/usr/local/bin/rsync" ] && [ -x "/usr/local/bin/rsync" ]
        then
            rsync_cmd="/usr/local/bin/rsync"
        else
            printf -- "Could not find a suitable rsync executable. Please make sure rsync is installed. If you use a custom version, please specify it in your config file.\n" 1>&2
            exit_code=1
        fi
    fi

    printf -- "%s\n" "${rsync_cmd}"

    return ${exit_code}
}



getOSFamily()
{
    case "${OSTYPE}" in
        darwin*)
            printf -- "%s\n" "OSX"
            ;;
        linux*)
            printf -- "%s\n" "Linux"
            ;;
        solaris*)
            printf -- "%s\n" "Solaris"
            ;;
        bsd*)
            printf -- "%s\n" "BSD"
            ;;
        *)
            printf -- "Unknown: %s\n" "${OSTYPE}"
            ;;
    esac
}



contains()
{
    # Checks if the first argument is in the following ones.
    # This is especially useful to check if an array contains a specific value.

    local exit_code
    local needle
    local haystack

    exit_code=1
    needle="${1}"; shift

    for haystack in "${@:1}"
    do
        if [ "${needle}" = "${haystack}" ]
        then
            exit_code=0
            break
        fi
    done

    return ${exit_code}
}



check_root()
{
    local exit_code

    exit_code=$(id -u)

    if [ "${exit_code}" -ne 0 ]
    then
        printf -- "%s must be run as root. Aborting.\n" "${PROGNAME}" 1>&2
    fi

    return "${exit_code}"
}



create_conf()
{
    local cnf

    cnf="${1}"

    cat << EO_DEFAULT_CONFIG > "${cnf}"
# The WABAC Machine configuration.

# Source :
#     Source can be either :
#         - a local directory (ABSOLUTE PATH),
#         - a directory on a remote host, accessible through SSH,
#         - a rsync module.
source=$2

# Destination :
#     Destination MUST be a local directory.
# Please provide an ABSOLUTE PATH.
destination=$3

# rsync options :
#     Please keep the --stats option.
#     DO NOT EDIT unless you really know what you do.
opts=(
    --stats
    --archive
    --hard-links
    --acls
    --xattrs
    --sparse
    --one-file-system
    --partial-dir=.incomplete
    --protect-args
    --numeric-ids
    --human-readable
# Those are specific to HFS+ (OS X)
# You'll certainly need to compile rsync with a few patches to get them working.
# See https://github.com/Frzk/WABACMachine/wiki/Running-on-OSX
#    --crtimes                   # Preserves create times
#    --fileflags                 # Preserves file-flags (chflags)
#    --force-change              # Affects user-/system-immutable files/dirs
#    --hfs-compression           # Preserves  HFS compression if supported
#    --protect-decmpfs           # Preserves HFS compression as xattrs
)

# Keeps **EVERYTHING** for the last <nb_hours> hours :
nb_hours=1

# Keeps **ONE** backup **PER DAY** for the last <nb_days> days :
nb_days=31

# Keeps **ONE** backup **PER WEEK** for the last <nb_weeks> weeks :
nb_weeks=52

# Keeps **ONE** backup **PER MONTH** for the last <nb_months> months :
nb_months=24

# Exclude file (ABSOLUTE PATH) :
exclude_file=

# Preflight :
#     ABSOLUTE PATH to a script that you may want to run BEFORE the backup.
#     (e.g. Mounting a remote share, mounting an encrypted volume, ...)
#
#     Note : The WABAC Machine will **ONLY** run if the preflight script returns zero.
#
preflight=

# Postflight :
#     ABSOLUTE PATH to a script that you may want to run AFTER the backup.
#     (e.g. Unmounting an encrypted volume, unmounting a remote share, shutting down a computer, sending an email...)
#
#     Note : The WABAC Machine will *ALWAYS* run the postflight script.
#
postflight=

# ABSOLUTE PATH to the rsync executable you want to run.
# If left empty, the WABAC Machine will try to run rsync from (in that order) :
#     - /usr/bin/rsync
#     - /usr/local/bin/rsync
#
rsync_path=

EO_DEFAULT_CONFIG

    return $?
}



display_usage()
{
    cat <<EOH
Usage: $PROGNAME <verb> <options>
Try '$PROGNAME help' for more information.
EOH

    exit 0
}



display_help()
{
    cat <<EOH
WABAC Machine version $VERSION.
The WABAC Machine is a wrapper for rsync that will help you backup your files.
Options and functionnalities mostly depend on your platform. Please refer to the
avalaible online documentation for further information.

Usage: $PROGNAME <verb> <options>, where <verb> is as follows:

    backup                              Create a new backup of source in destination.
    help                                Show help (this output).
    info                                Output some information about destination and exit. DO NOT backup.
    init                                Initialize a new WABAC Machine with the given source, destination and default configuration. DO NOT backup.
    remove-expired                      Only remove expired backups and exit. DO NOT backup.

Options:

    -k, --keep-expired                  Do not remove expired backups (use with 'backup' only).
    -c, --config <config_file>          Specify the config file to use.
                                        When called with 'init', output the newly created configuration file to the given file instead of the default one.
                                        Else, read configuration from the given file.

Files:
    WABACMachine.sh           The backup script
    WABACMachine.conf         The default config file


Head over https://github.com/Frzk/WABACMachine/ for further information and help.
EOH

    exit 0
}





# # #   RUN   # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

# PROGNAME and version :
PROGNAME=$(basename "${0}")
PROGDIR=$(cd "$(dirname "$0")" || exit 1; pwd)    # Rather ugly but, well...
VERSION="20210720"

# Date format :
DATE_REGEXP="[0-9]{4}-[0-9]{2}-[0-9]{2}"

# Get the platform :
PLATFORM=$(getOSFamily)

# Make all these readonly:
readonly PROGNAME
readonly PROGDIR
readonly VERSION
readonly DATE_REGEXP
readonly PLATFORM

# Arguments ;
readonly -a ARGS=("${@}")

# Run :
main "${ARGS[@]}"

# This should never be reached :
exit 0
