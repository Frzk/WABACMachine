#!/bin/bash

# The WABAC Machine.
#
# This script creates incremental backups with a smart retention strategy.
# It's obviously inspired by Apple's Time Machine.
# All credits to rsync devs.
# Copyright François KUBLER, 2009-2015.
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

run()
{
    local exit_code
    local cli_source
    local cli_destination
    local action
    local config
    local keep_expired
    local dryrun

    # Config file variables (set when config is loaded) :
    local source
    local destination
    local opts
    local nb_hours
    local nb_days
    local nb_weeks
    local nb_months
    local exclude_file
    local preflight
    local postflight
    local rsync_path

    exit_code=0

    # Some defaults values :
    action="usage"                          # Default action -- Use command line to change the value.
    config="${APPDIR}/WABACMachine.conf"    # Default config file -- Use the '-c' option to change the value.
    keep_expired=1                          # Keep expired backups (0=yes, 1=no, default is 1) -- Use the '-k' option to change the value

    # Read arguments.
    read_args "${@}" || exit $?

    # Usage ?
    [ "${action}" = "usage" ] && display_usage

    # Help ?
    [ "${action}" = "help" ] && display_help


    # After this line, we have to be root.

    # Check if root.
    check_root || exit $?

    # Setup traps.
    setup_traps

    # Load conf.
    if [ "${action}" != "init" ]
    then
        load_config "${config}"  || exit $?
    fi

    # Run preflight.
    run_preflight "${preflight}" || exit $?

    # Backup, remove expired, output info, init, ...
    if [ "${action}" = "init" ]
    then
        init "${cli_source}" "${cli_destination}" "${config}"
        exit_code=$?
    else
        # Dry run.
        contains "--dry-run" "${opts[@]}"
        dryrun=$?

        # Starting...
        printf "Starting the WABAC Machine"
        if [ ${dryrun} -eq 0 ]
        then
            printf " in DRY RUN MODE"
        fi
        printf " with:\n  Action: %s\n  Config: %s\n  Source: %s\n  Destination: %s\n" "${action}" "${config}" "${source}" "${destination}"

        # Check source.
        check_source "${source}" || exit $?

        # Check destination.
        check_destination "${destination}" || exit $?

        # Lock.
        lock || exit $?

        # Backup ?
        if [ "${action}" = "backup" ]
        then
            backup "${source}" "${destination}" "${opts[*]}"
            exit_code=$?
        fi

        # Remove expired ?
        if ([ "${action}" = "backup" ] && [ "${exit_code}" = "0" ] && [ "${keep_expired}" != "0" ]) || [ "${action}" = "remove-expired" ]
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
    #

    local exit_code

    exit_code=0

    while :
    do
        case "${1}" in
	        backup|info|remove-expired)
	            action="${1}"
	            shift
	            ;;

            help)
                action="help"
                break
                ;;

            init)
                if [ $# -lt 3 ]
                then
                    printf "Usage: %s init <source> <destination> [-c | --config <filename>]\n" "${APPNAME}" 1>&2
                    exit 1
                else
                    action="init"
                    cli_source="${2}"
                    cli_destination="${3}"
                    shift 3
                fi
                ;;

            -k|--keep-expired)
                keep_expired=0
                shift
                ;;

	        -c|--config)
                config="${2}"
                shift 2
                ;;

            --) # End of all options
                shift
                break
                ;;

            -*) # Unsupported option
                printf "Error: Unsupported option (%s).\n" "${1}" 1>&2
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
    #

    local exit_code

    source "${1}" 2>/dev/null
    exit_code=$?

    if [ "${exit_code}" != "0" ]
    then
        printf "Config file (%s) could not be read. Does it exist ?\n" "${1}" 1>&2
    fi

    return ${exit_code}
}



check_source()
{
    # Checks if the source is readable.
    #

    local exit_code

    exit_code=1

    if [ ! -z "${1}" ]
    then
        if [ -r "${1}" ]
        then
            exit_code=0
        else
            printf "The provided source (%s) is not readable !\n" "${1}" 1>&2
        fi
    else
        printf "Source is not defined. Please fix your config file.\n" 1>&2
    fi

    return ${exit_code}
}



check_destination()
{
    # Checks if the destination is explicitly marked as being a destination for the WABAC Machine.
    # Also checks if it is writeable.
    #

    local exit_code

    exit_code=1

    if [ ! -z "${1}" ]
    then
        if [ -f "${1}/.wabac_machine_is_present" ]
        then
            if [ -w "${1}" ]
            then
                exit_code=0
            else
                printf "The provided destination (%s) is not writeable !\n" "${1}" 1>&2
            fi
        else
            printf "The provided destination (%s) is not marked as being a destination for the WABAC Machine.\n" "${1}" 1>&2
        fi
    else
        printf "Destination is not defined. Please fix your config file.\n" 1>&2
    fi

    return ${exit_code}
}



init()
{
    # Initializes a new WABAC Machine :
    #     - Marks the given directory as a destination for the WABAC Machine.
    #     - Creates a new default configuration file with the given source and destination.
    #
    #     $1 : source
    #     $2 : destination
    #     $3 : path to the config file
    #

    local exit_code
    local src
    local dst
    local cnf

    exit_code=0
    src="${1}"
    dst="${2}"
    cnf="${3}"

    if [ ${exit_code} -eq 0 ]
    then
        # Create a default config file :
        if [ ! -f "${cnf}" ]
        then
            create_conf "${cnf}" "${src}" "${dst}"
            exit_code=$?

            if [ ${exit_code} -eq 0 ]
            then
                chmod 600 "${cnf}"
                exit_code=$?
            fi

            if [ ${exit_code} -ne 0 ]
            then
                printf "An error occured while creating the config file (%s). Please check that it is complete and 'chmod 600' it.\n" "${cnf}" 1>&2
            fi
        else
            exit_code=1
            printf "The provided configuration file (%s) already exists. I am NOT going to overwrite it. Please chose another file or remove this one.\n" "${cnf}" 1>&2
        fi
    fi

    # Mark destination as being ready for the WABAC Machine :
    if [ ${exit_code} -eq 0 ]
    then
        touch -- "${dst}/.wabac_machine_is_present"
        exit_code=$?
    fi

    if [ ${exit_code} -eq 0 ]
    then
        printf "The WABAC Machine has been successfully initialized.\n"

        if [ "${platform}" = "OSX" ]
        then
            printf "\nCAUTION:\nThe WABAC Machine detected that you are running OSX.\n"
            printf "If you are backing up data stored on an HFS+ volume, you might need a custom version of rsync.\n"
            printf "You might also need to enable a few options in your config file (%s).\n" "${cnf}"
            printf "See instructions here : https://github.com/Frzk/WABACMachine/wiki/Running-on-OSX\n\n"
        fi

        if [ "${cnf}" != "{APPDIR}/WABACMachine.conf" ]
        then
            printf "Run 'WABACMachine.sh backup -c %s' as root to create a new backup.\n" "${cnf}"
        else
            printf "Run 'WABACMachine.sh backup' as root to create a new backup.\n"
        fi
        printf "Run 'WABACMachine.sh help' to get some help.\n"
    fi

    return ${exit_code}
}



run_preflight()
{
    # Runs the given script.
    #     $1 : preflight script.
    #

    local exit_code
    local script

    exit_code=0
    script="${1}"

    if [ ! -z "${script}" ]     # Do we have a pre-flight script to run ?
    then
        if [ -x "${script}" ]   # Is it executable ?
        then
            source "${script}"  # Run it !
            exit_code=$?
        else
            printf "The preflight script (%s) does not exist or cannot be executed. Please fix your config file.\n" "${script}" 1>&2
            exit_code=1
        fi
    fi

    return ${exit_code}
}



run_postflight()
{
    # Runs the given script.
    #     $1 : postflight script
    #

    local exit_code
    local script

    exit_code=0
    script="${1}"

    if [ ! -z "${script}" ]     # Do we have a postflight script to run ?
    then
        if [ -x "${script}" ]   # Is it executable ?
        then
            source "${script}"  # Run it !
            exit_code=$?
        else
            printf "The postflight script (%s) does not exist or cannot be executed. Please fix your config file.\n" "${script}" 1>&2
            exit_code=1
        fi
    fi

    return ${exit_code}
}



backup()
{
    # Creates a new backup.
    # It's a basic call to rsync <3
    #     $1 : source
    #     $2 : destination (must be ready to use)
    #     $3 : rsync options
    #

    local exit_code
    local src
    local dst
    local opts
    local ref
    local completed
    local rsync_cmd
    local rsync_output
    local now
    local now_t
    local latest
    local remove_oldest_ok

    exit_code=0
    src="${1}"
    dst="${2}"
    shift 2
    opts=("${@}")
    completed=1
    now=$(date "+%Y-%m-%d-%H%M%S")
    now_t=$(date "+%Y%m%d%H%M.%S")


    # See if we have an exclude file.
    if [ ! -z "${exclude_file}" ]     # Checks that exclude_file is set AND not empty.
    then
    if [ -f "${exclude_file}" ]
        then
            opts+=(--exclude-from="${exclude_file}")
        else
            # This will be printed to STDERR later :
            rsync_output=$(printf "The given exclude file does not exist (%s). Please fix your config file.\n" "${exclude_file}")
            exit_code=1
        fi
    else
        exclude_file="None"
    fi
    printf "  Exclude file: %s\n" "${exclude_file}"


    # See if we can take advantage of an existing backup and use the --link-dest option.
    if [ -h "${dst}/latest" ]
    then
        ref=$(readlink "${dst}/latest")
        opts+=(--link-dest="${dst}/latest")
    else
        ref="None (new backup)"
    fi
    printf "  Reference: %s\n" "${ref}"


    # Backup.
    # The first `if` check prevents from running if the `exclude_file` preference is
    # set but pointing to an unreadable file.
    if [ ${exit_code} -eq 0 ]
    then
        # Get rsync path :
        rsync_cmd=$(get_rsync "${rsync_path}" 2>&1)
        exit_code=$?

        if [ ${exit_code} -eq 0 ]
        then
            # Start the backup process.
            while [ ${completed} -gt 0 ]
            do
                rsync_output=$($rsync_cmd ${opts[@]} -- "${src}" "${dst}/inProgress" 2>&1)
                exit_code=$?

                grep --invert-match --quiet "No space left on device (28)\|Result too large (34)" <<< "${rsync_output}"
                completed=$?

                if [ ${completed} -gt 0 ]
                then
                    remove_oldest "${dst}"
                    remove_oldest_ok=$?

                    if [ ${remove_oldest_ok} -ne 0 ]
                    then
                        completed=0     # Ends the while loop.
                        rsync_output=$(printf "No more space available on %s.\n" "${dst}")  # Will be printed later.
                        exit_code=1
                    fi
                fi
            done
        else
            rsync_output="${rsync_cmd}"
        fi
    fi

    # Handle exit codes. We have 4 cases :
    #     0  : Everything is OK, we just have to rotate the backups and purge them.
    #     24 : Some files have vanished during the backup. We still consider the backup as OK.
    #     23 : Some files/attrs were not transferred (in most cases, this is an ACL issue). We still consider the backup as OK but a message is printed on STDERR.
    #     *  : Something went wrong ! We keep everything in the current state.
    case "${exit_code}" in
        0|23|24)
            if [ ${dryrun} -gt 0 ]
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

            if [ "${exit_code}" = "23" ]
            then
                printf "Warning: there might be an ACL issue :\n%s" "${rsync_output}" 1>&2
            fi

            exit_code=0     # Reset `exit_code` to zero since we consider the backup as OK.
            ;;

        *)
            printf "Error: An error occured while backing up (%s). The backup might be incomplete or corrupt ! Details :\n%s\n" "${exit_code}" "${rsync_output}" 1>&2
            ;;
    esac

    return ${exit_code}
}



get_snapshots()
{
    find "${1}" -maxdepth 1 -type d | grep -E "${date_regexp}" | sort
}



get_oldest_snapshot()
{
    get_snapshots "${1}" | head -n 1
}



get_latest_snapshot()
{
    get_snapshots "${1}" | tail -n 1
}



info_backup()
{
    # Prints out some information about the just-ending backup process.
    # Requires rsync to run with the "--stats" and "--human-readable" options.
    #     $1 : rsync output
    #

    local rsync_output
    local total_nb_files
    local total_size
    local nb_files
    local size
    local speedup

    rsync_output="${1}"

    total_nb_files=$(grep "Number of files:" <<< "${rsync_output}" | cut -d " " -f 4)
    total_size=$(grep "Total file size:" <<< "${rsync_output}" | cut -d " " -f 4)
    nb_files=$(grep -E "Number of (regular )?files transferred:" <<< "${rsync_output}" | grep -oE "[^ ]+$")
    size=$(grep "Total transferred file size:" <<< "${rsync_output}" | cut -d " " -f 5)
    speedup=$(grep "speedup" <<< "${rsync_output}" | cut -d " " -f 8)

    printf "Successfully backed up %s files (%s).\n" "${total_nb_files}" "${total_size}"
    printf "Actually copied %s files (%s) - Speedup : %s.\n" "${nb_files}" "${size}" "${speedup}"
}



info_destination()
{
    # Prints out some information about the backups.
    #     $1 : destination
    #

    local dst
    local nb
    local oldest
    local latest
    local space_left

    dst="${1}"
    nb=$(get_snapshots "${dst}" | wc -l | tr -d " ")
    oldest=$(get_oldest_snapshot "${dst}")
    latest=$(get_latest_snapshot "${dst}")

    space_left=$(df -PH -- "${dst}" | tail -n 1 | tr -s " " | cut -d " " -f 4)

    printf "%s backups available.\n" "${nb}"
    [ ! -z "${oldest}" ] && printf "Oldest is %s.\n" "${oldest}"
    [ ! -z "${latest}" ] && printf "Latest is %s.\n" "${latest}"
    printf "%s left on %s.\n" "${space_left}" "${dst}"
}



keep_all()
{
    # Keeps **everything** for the last $2 hours.
    #     $1 : path to examine
    #     $2 : nb hours
    #
    # For example, calling `keep_all /my/path 24`
    # will keep everything within the last 24 hours.
    #

    local dst
    local hours

    dst="${1}"
    hours=$((${2}*60))

    find "${dst}" -type d -maxdepth 1 -mmin -"${hours}" | grep -E "${date_regexp}" | sort
}



keep_one_per_day()
{
    # Keeps **one** backup per day for the last $2 days.
    #     $1 : path to examine
    #     $2 : nb days
    #
    # For example, calling `keep_one_per_day /my/path 10`
    # will keep 1 backup per day for the last 10 days.
    #

    local dst
    local days
    local latest_backup

    dst="${1}"
    days="${2}"

    latest_backup=$(get_latest_snapshot "${dst}")

    case "${platform}" in
        OSX|BSD)
            osx_keep_one_per_day "${dst}" "${days}" "${latest_backup}"
            ;;
        Linux)
            linux_keep_one_per_day "${dst}" "${days}" "${latest_backup}"
            ;;
        *)
            printf "FIXME: keep_one_per_day isn't supported on this platform (%s).\n" "${platform}" 1>&2
            ;;
    esac
}



keep_one_per_week()
{
    # Keeps one backup per week for the last $2 weeks.
    #     $1 : path to examine
    #     $2 : nb weeks
    #
    # For example, calling `keep_one_per_week /my/path 2`
    # will keep 1 backup per week for the last 2 weeks.
    #

    local dst
    local weeks
    local latest_backup

    dst="${1}"
    weeks="${2}"

    latest_backup=$(get_latest_snapshot "${dst}")

    case "${platform}" in
        OSX|BSD)
            osx_keep_one_per_week "${dst}" "${weeks}" "${latest_backup}"
            ;;
        Linux)
            linux_keep_one_per_week "${dst}" "${weeks}" "${latest_backup}"
            ;;
        *)
            printf "FIXME: keep_one_per_week isn't supported on this platform (%s).\n" "${platform}" 1>&2
            ;;
    esac
}



keep_one_per_month()
{
    # Keeps one backup per month for the last $2 months.
    #     $1 : path to examine
    #     $2 : nb months
    #
    # For example, calling `keep_one_per_month /my/path 10`
    # will keep 1 backup per month for the last 10 months.
    #

    local dst
    local months
    local latest_backup

    dst="${1}"
    months="${2}"

    latest_backup=$(get_latest_snapshot "${dst}")

    case "${platform}" in
        OSX|BSD)
            osx_keep_one_per_month "${dst}" "${months}" "${latest_backup}"
            ;;
        Linux)
            linux_keep_one_per_month "${dst}" "${months}" "${latest_backup}"
            ;;
        *)
            printf "FIXME: keep_one_per_month isn't supported on this platform (%s).\n" "${platform}" 1>&2
            ;;
    esac
}



keep_one_per_year()
{
    # Keeps one backup per year, without limit.
    #     $1 : path to examine
    #
    # For example, calling `keep_one_per_year /my/path`
    # will keep 1 backup per year, without limit of time.
    #

    local dst
    local oldest_backup

    dst="${1}"

    oldest_backup=$(get_oldest_snapshot "${dst}")

    case "${platform}" in
        OSX|BSD)
            osx_keep_one_per_year "${dst}" "${oldest_backup}"
            ;;
        Linux)
            linux_keep_one_per_year "${dst}" "${oldest_backup}"
            ;;
        *)
            printf "FIXME: keep_one_per_year isn't supported on this platform (%s).\n" "${platform}" 1>&2
            ;;
    esac
}



keep_between()
{
    # Keeps one backup betwen the two given dates.
    #     $1 : path to examine
    #     $2 : first date (oldest)
    #     $3 : second date (latest)
    #

    local dst
    local d1
    local d2

    dst="${1}"
    d1="${2}"
    d2="${3}"

    # Keeps one snapshot for the interval [$D1 ; $D2[
    find "${dst}" -type d -maxdepth 1 \( -newermt "${d1}" -a ! -newermt "${d2}" \) | grep -E "${date_regexp}" | sort | tail -n 1
}



osx_keep_one_per_day()
{
    # OSX version of `keep_one_per_day`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : nb days
    #     $3 : latest backup
    #

    local dst
    local limit
    local latest_backup
    local tstamp
    local date_ref
    local d1
    local d2

    dst="${1}"
    limit="${2}"
    latest_backup="${3}"

    tstamp=$(stat -f "%m" "${latest_backup}")
    date_ref=$(date -jf "%s" "${tstamp}" "+%F")

    for ((i=0 ; i<limit ; i++ ))
    do
        d1="${date_ref}"
        d2=$(date -v+1d -jf "%F" "${d1}" "+%F")

        keep_between "${dst}" "${d1}" "${d2}"

        date_ref=$(date -v-1d -jf "%F" "${d1}" "+%F")
    done
}



osx_keep_one_per_week()
{
    # OSX version of `keep_one_per_week`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : nb weeks
    #     $3 : latest backup
    #

    local dst
    local limit
    local latest_backup
    local tstamp
    local date_ref
    local d1
    local d2

    dst="${1}"
    limit="${2}"
    latest_backup="${3}"

    tstamp=$(stat -f "%m" "${latest_backup}")
    date_ref=$(date -jf "%s" "${tstamp}" "+%F")

    for ((i=0 ; i<limit ; i++ ))
    do
        d1=$(date -v-sun -jf "%F" "${date_ref}" "+%F")  # Previous Sunday
        d2=$(date -v+1w -v+sun -jf "%F" "${d1}" "+%F")  # Next Sunday

        keep_between "${dst}" "${d1}" "${d2}"

        date_ref=$(date -v-7d -jf "%F" "${d1}" "+%F")
    done
}



osx_keep_one_per_month()
{
    # OSX version of `keep_one_per_month`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : nb months
    #     $3 : latest backup
    #

    local dst
    local limit
    local latest_backup
    local tstamp
    local date_ref
    local cur_month
    local cur_year
    local d1
    local d2

    dst="${1}"
    limit="${2}"
    latest_backup="${3}"

    tstamp=$(stat -f "%m" "${latest_backup}")
    date_ref=$(date -jf "%s" "${tstamp}" "+%F")

    for ((i=0 ; i<limit ; i++ ))
    do
        cur_month=$(date -jf "%F" "${date_ref}" "+%m")
        cur_year=$(date -jf "%F" "${date_ref}" "+%Y")

        d1=$(date -jf "%F" "${cur_year}-${cur_month}-01" "+%F")
        d2=$(date -v+1m -jf "%F" "${d1}" "+%F")

        keep_between "${dst}" "${d1}" "${d2}"

        date_ref=$(date -v-1m -jf "%F" "${d1}" "+%F")
    done
}



osx_keep_one_per_year()
{
    # OSX version of `keep_one_per_year`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : oldest backup
    #

    local dst
    local oldest_backup
    local tstamp
    local date_ref
    local first_year
    local latest_year
    local d1
    local d2

    dst="${1}"
    oldest_backup="${2}"

    tstamp=$(stat -f "%m" "${oldest_backup}")
    date_ref=$(date -jf "%s" "${tstamp}" "+%F")

    first_year=$(date -jf "%F" "${date_ref}" "+%Y")
    latest_year=$(( ($(date "+%Y")) + 1 ))

    for ((i=first_year ; i<latest_year ; i++))
    do
        d1=$(date -jf "%F" "${i}-01-01" "+%F")
        d2=$(date -v+1y -jf "%F" "${d1}" "+%F")

        keep_between "${dst}" "${d1}" "${d2}"
    done
}



linux_keep_one_per_day()
{
    # Linux version of `keep_one_per_day`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : nb days
    #     $3 : latest backup
    #

    local dst
    local limit
    local latest_backup
    local tstamp
    local date_ref
    local d1
    local d2

    dst="${1}"
    limit="${2}"
    latest_backup="${3}"

    tstamp=$(stat -c %y "${latest_backup}" | cut -f 1 -d" ")
    date_ref=$(date --date "${tstamp}" "+%F")

    for ((i=0 ; i<limit ; i++ ))
    do
        d1="${date_ref}"
        d2=$(date --date "${d1} +1day" "+%F")

        keep_between "${dst}" "${d1}" "${d2}"

        date_ref=$(date --date "${d1} -1day" "+%F")
    done
}



linux_keep_one_per_week()
{
    # Linux version of `keep_one_per_week`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : nb weeks
    #     $3 : latest backup
    #

    local dst
    local limit
    local latest_backup
    local tstamp
    local date_ref
    local d1
    local d2
    local n

    dst="${1}"
    limit="${2}"
    latest_backup="${3}"

    tstamp=$(stat -c %y "${latest_backup}" | cut -f 1 -d" ")
    date_ref=$(date --date "${tstamp}" "+%F")

    for ((i=0 ; i<limit ; i++ ))
    do
        n=$(date -d "${date_ref}" +%u)
        d1=$(date --date "${date_ref} -${n} days" "+%F")  # Previous Sunday
        d2=$(date --date "${d1} +1week" "+%F")            # Next Sunday

        keep_between "${dst}" "${d1}" "${d2}"

        date_ref="${d1}"
    done
}



linux_keep_one_per_month()
{
    # Linux version of `keep_one_per_month`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : nb months
    #     $3 : latest backup
    #

    local dst
    local limit
    local latest_backup
    local tstamp
    local date_ref
    local cur_month
    local cur_year
    local d1
    local d2

    dst="${1}"
    limit="${2}"
    latest_backup="${3}"

    tstamp=$(stat -c %y "${latest_backup}" | cut -f 1 -d" ")
    date_ref=$(date --date "${tstamp}" "+%F")

    for ((i=0 ; i<limit ; i++ ))
    do
        cur_month=$(date --date "${date_ref}" "+%m")
        cur_year=$(date --date "${date_ref}" "+%Y")

        d1=$(date --date "${cur_year}-${cur_month}-01" "+%F")
        d2=$(date --date "${d1} +1month" "+%F")

        keep_between "${dst}" "${d1}" "${d2}"

        date_ref=$(date --date "${d1} -1month" "+%F")
    done
}



linux_keep_one_per_year()
{
    # Linux version of `keep_one_per_year`.
    # `date` invokations are different.
    #     $1 : destination
    #     $2 : oldest backup
    #

    local dst
    local oldest_backup
    local tstamp
    local date_ref
    local first_year
    local latest_year
    local d1
    local d2

    dst="${1}"
    oldest_backup="${2}"

    tstamp=$(stat -c %y "${oldest_backup}" | cut -f 1 -d" ")
    date_ref=$(date --date "${tstamp}" "+%F")

    first_year=$(date --date "${date_ref}" "+%Y")
    latest_year=$(date --date "now +1year" "+%Y")

    for ((i=first_year ; i<latest_year ; i++))
    do
        d1=$(date --date "${i}-01-01" "+%F")
        d2=$(date --date "${d1} +1year" "+%F")

        keep_between "${dst}" "${d1}" "${d2}"
    done
}



remove_expired()
{
    # Removes expired backups.
    #     $1 : destination (where the backups are stored)
    #     $2 : nb hours
    #     $3 : nb days
    #     $4 : nb weeks
    #     $5 : nb months
    #

    local dst
    local nb_hours
    local nb_days
    local nb_weeks
    local nb_months
    local keep_file

    dst="${1}"
    nb_hours="${2}"
    nb_days="${3}"
    nb_weeks="${4}"
    nb_months="${5}"

    keep_file="${APPDIR}/wabac.running/keep"

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
    #     $1 : path to where the backups are stored
    #     $2 : keep file, file that lists the backups to **KEEP**.
    #

    local dst
    local keep_file
    local rm_count
    local readonly snapshots_file="${APPDIR}/wabac.running/backups"
    local readonly kickout="${APPDIR}/wabac.running/kickout"


    dst="${1}"
    keep_file="${2}"

    # Builds the list of backups to remove :
    #   Sorts the two files, merges them and removes duplicates.
    #   See `man sort` for further details.
    #   See `man uniq` for further details.
    get_snapshots "${dst}" > "${snapshots_file}"
    sort -- "${keep_file}" "${snapshots_file}" | uniq -u > "${kickout}"

    # Removes what's useless :
    rm_count=$(wc -l < "${kickout}" | tr -d " ")

    case "${rm_count}" in
        0)
            printf "%s expired backup found.\n" "No"
            ;;
        1)
            printf "%s expired backup will be removed.\n" "One"
            ;;
        *)
            printf "%s expired backups will be removed.\n" "${rm_count}"
            ;;
    esac

    while read snap
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
    #     $1 : backup to be removed.
    #

    if [ ${dryrun} -gt 0 ]
    then
        rm -Rf "${1}"
        printf "Deleted %s.\n" "${1}"
    else
        printf "I would have deleted %s.\n" "${1}"
    fi


}



remove_oldest()
{
    # Removes the oldest backup, only if it's not the only one remaining.
    #     $1 : destination (where the backups are stored)

    local dst
    local exit_code
    local nb_backups
    local oldest

    dst="${1}"
    exit_code=0
    nb_backups=$(get_snapshots "${dst}" | wc -l)

    if [ ${nb_backups} -gt 1 ]
    then
        oldest=$(get_oldest_snapshot "${dst}")
        remove_backup "${oldest}"
    else
        printf "Can't remove the oldest backup : it's the last one remaining.\n" 1>&2
        exit_code=1
    fi

    return ${exit_code}
}



lock()
{
    # Creates a lock to ensure we run only one instance at the same time.
    # We use mkdir because it is atomic.
    #

    local exit_code
    local mkdir_output
    local readonly lockdir="${APPDIR}/wabac.running"

    mkdir_output=$(mkdir -- "${lockdir}" 2>&1)
    exit_code=$?

    if [ "${exit_code}" = "0" ]
    then
        echo $$ > "${lockdir}/pid"
    else
        printf "Could not acquire lock : %s (probably hold by %s).\n" "${mkdir_output}" "$(<${lockdir}/pid)"
    fi

    return ${exit_code}
}



unlock()
{
    # Allows another instance of the WABAC Machine to run.
    # As we store every temp file in the lockdir directory, it also deletes those.
    #

    local readonly lockdir="${APPDIR}/wabac.running"
    rm -Rf "${lockdir}"
}



setup_traps()
{
    # Setup traps.
    #   The following signals are trapped : EXIT, TERM, HUP, QUIT and INT.
    #

    trap "handle_exit" EXIT
    trap "handle_sigs" TERM HUP QUIT INT
}



remove_traps()
{
    # Remove previously setup traps.
    #

    trap - TERM HUP QUIT INT EXIT
}



handle_sigs()
{
    # Handle trapped signals.
    #

    local sig
    local signame

    sig=$?

    if [ ${sig} -gt 127 ]
    then
        let sig-=128
        signame="SIG"$(kill -l -- ${sig})
    else
        signame="RSYNC_INTERRUPTED"
    fi

    printf "Received %s. Backup interrupted !\n" "${signame}" 1>&2

    # Propagate :
    kill -s ${sig} $$
}



handle_exit()
{
    # This is the exit door of the WABAC Machine.
    #

    errno=$?

    remove_traps
    exit ${errno}
}



get_rsync()
{
    local exit_code
    local rsync_cmd

    exit_code=0
    rsync_cmd=""

    if [ ! -z "${1}" ]      # A path is specified in the config file.
    then
        if [ ! -f "${1}" ] || [ ! -x "${1}" ]
        then
            printf "Could not find a suitable rsync executable at the provided path (%s).\n" "${1}" 1>&2
            exit_code=2
        else
            rsync_cmd="${1}"
        fi
    else                    # Let's try the "standards" paths.
        if [ -f "/usr/bin/rsync" ] && [ -x "/usr/bin/rsync" ]
        then
            rsync_cmd="/usr/bin/rsync"
        elif [ -f "/usr/local/bin/rsync" ] && [ -x "/usr/local/bin/rsync" ]
        then
            rsync_cmd="/usr/local/bin/rsync"
        else
            printf "Could not find a suitable rsync executable. Please make sure rsync is installed. If you use a custom version, please specify it in your config file.\n" 1>&2
            exit_code=1
        fi
    fi

    printf "%s\n" "${rsync_cmd}"

    return ${exit_code}
}



getOSFamily()
{
    case "${OSTYPE}" in
        darwin*)
            printf "%s\n" "OSX"
            ;;
        linux*)
            printf "%s\n" "Linux"
            ;;
        solaris*)
            printf "%s\n" "Solaris"
            ;;
        bsd*)
            printf "%s\n" "BSD"
            ;;
        *)
            printf "Unknown: %s\n" "${OSTYPE}"
            ;;
    esac
}



contains()
{
    # Checks if the first argument is in the following ones.
    # This is especially useful to check if an array contains a specific value.
    #

    local exit_code
    local needle
    local haystack

    exit_code=1
    needle=${1}

    for haystack in "${@:2}"
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

    if [ "${exit_code}" != "0" ]
    then
        printf "%s must be run as root. Aborting.\n" "${APPNAME}" 1>&2
    fi

    return "${exit_code}"
}



create_conf()
{
    cat << EO_DEFAULT_CONFIG > "${1}"
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
Usage: $APPNAME <verb> <options>
Try '$APPNAME help' for more information.
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

Usage: $APPNAME <verb> <options>, where <verb> is as follows:

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

# Appname and version :
readonly APPNAME=$(basename "${0}")
readonly APPDIR=$(cd "$(dirname "$0")"; pwd)    # Rather ugly but, well...
readonly VERSION="20150619"

# Date format :
readonly date_regexp="[0-9]{4}-[0-9]{2}-[0-9]{2}"
readonly date_fmt="%F-%H%M%S"

# Get the platform :
readonly platform=$(getOSFamily)

# Run :
run "${@}"

# This should never be reached :
exit 0
