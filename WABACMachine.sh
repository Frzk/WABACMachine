#!/bin/sh

#
#-------------------------------------------------------------------------------
#
# The WABAC Machine.
#
# This script tries to mimic Apple's TimeMachine, *thanks to rsync* :)
# Copyright François KUBLER, 2009-2014.
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
#-------------------------------------------------------------------------------
# latest rev: 2014-06-17
#-------------------------------------------------------------------------------
#


# # #   C O N F I G   # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

# Path of the WABAC Machine :
selfdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path of the directory we create to lock the WABAC Machine :
lockdir="$selfdir/WABACMachine.running"

# File that contains the list of backups we want to keep :
keep_file="$lockdir/keep.txt"

# File that contains the list of available backups :
snapshots_file="$lockdir/snaps.txt"

# File that contains the list of backups we want to delete :
kickout="$lockdir/kickout.txt"

# Whether use a verbose output or not :
verbose=false


# # #   F U N C T I O N S   # # # # # # # # # # # # # # # # # # # # # # # # # # 

check_mounted()
{
    cat /etc/mtab | grep "$vol" >/dev/null

    if [ "$?" -ne "0" ]
    then
        echo -n "$vol is not mounted, trying to mount..."

        mount "$vol"

        cat /etc/mtab | grep "$vol" >/dev/null

        if [ "$?" -ne "0" ]
        then
            echo "failed."
            local err="Unable to mount $vol, aborting !"
            cleanupexit 2 "$err"
        fi

        echo "OK."
    fi
}

clean()
{
    # Makes sure a potentially existing "inProgress" backup is deleted.
    # Makes sure every needed file is empty.
    #

    if [ -d "$dst/inProgress" ]
    then
        rm -Rf "$dst/inProgress"
    fi

    rm -f "$keep_file"
    rm -f "$snapshots_file"
    rm -f "$kickout"
}

protect()
{
    chattr -Rf +i "$1"
}

unprotect()
{
    chattr -Rf -i "$1"
}

get_snapshots()
{
    find "$dst" -maxdepth 1 -type d | grep -E "$snap_exp" | sort
}

get_oldest_snapshot()
{
    get_snapshots | head -n 1
}

get_latest_snapshot()
{
    get_snapshots | tail -n 1
}

keep_all()
{
    # Keeps everything for the last n hours.
    #
    # For example, calling keep_all 24
    # will keep everything for the last 24 hours.
    #

    # Checks that we have an integer as argument :
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { echo "keep_all requires an integer." 2>&1; exit 1; }

    local hours=$(($1*60))

    find "$dst" -maxdepth 1 -type d -mmin -"$hours" | grep -E "$snap_exp" | sort >> "$keep_file"
}

keep_one_per_day()
{
    # Keeps one backup per day for the last n days.
    #
    # For example, calling keep_one_per_day 10
    # will keep 1 backup per day for the last 10 days.
    #

    # Checks that we have an integer as argument :
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { echo "keep_one_per_day requires an integer." 2>&1; exit 1; }

    # Reset date_ref :
    local tstamp=$(stat -c %y "$(get_latest_snapshot)" | cut -f 1 -d" ")
    local date_ref=$(date --date "$tstamp" "+%F")

    for ((i=0 ; i<$1 ; i++ ))
    do
        local d1="$date_ref"
        local d2=$(date --date "$d1 +1day" "+%F")

        keep_between "$d1" "$d2"

        date_ref=$(date --date "$d1 -1day" "+%F")
    done
}

keep_one_per_week()
{
    # Keeps one backup per week for the last n weeks.
    #
    # For example, calling keep_one_per_week 2
    # will keep 1 backup per week for the last 2 weeks.
    #

    # Checks that we have an integer as argument :
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { echo "keep_one_per_week requires an integer." 2>&1; exit 1; }

    # Reset date_ref :
    local tstamp=$(stat -c %y "$(get_latest_snapshot)" | cut -f 1 -d" ")
    local date_ref=$(date --date "$tstamp" "+%F")

    for ((i=0 ; i<$1 ; i++ ))
    do
        local d1=$(date --date "$date_ref -$(date -d $date_ref +%u) days" "+%F")      # Previous Sunday
        local d2=$(date --date "$d1 +1week" "+%F")                                    # Next Sunday

        keep_between "$d1" "$d2"

        date_ref=$d1
    done
}

keep_one_per_month()
{
    # Keeps one backup per month for the last n months.
    #
    # For example, calling keep_one_per_month 10
    # will keep 1 backup per month for the last 10 months.
    #

    # Checks that we have an integer as argument :
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { echo "keep_one_per_month requires an integer." 2>&1; exit 1; }

    # Reset date_ref :
    local tstamp=$(stat -c %y "$(get_latest_snapshot)" | cut -f 1 -d" ")
    local date_ref=$(date --date "$tstamp" "+%F")

    for ((i=0 ; i<$1 ; i++ ))
    do
        local cur_month=$(date --date "$date_ref" "+%m")
        local cur_year=$(date --date "$date_ref" "+%Y")

        local d1=$(date --date "$cur_year-$cur_month-01" "+%F")
        local d2=$(date --date "$d1 +1month" "+%F")

        keep_between "$d1" "$d2"

        date_ref=$(date --date "$d1 -1month" "+%F")
    done
}

keep_one_per_year()
{
    # Keeps one backup per year for all the last years.
    #

    local tstamp=$(stat -c %y "$(get_oldest_snapshot)" | cut -f 1 -d" ")
    local oldest_save=$(date --date "$tstamp" "+%F")

    local first_year=$(date --date "$oldest_save" "+%Y")
    local latest_year=$(date --date "now +1year" "+%Y")

    for ((i=$first_year ; i<$latest_year ; i++))
    do
        local d1=$(date --date "$i-01-01" "+%F")
        local d2=$(date --date "$d1 +1year" "+%F")

        keep_between "$d1" "$d2"
    done
}

keep_between()
{
    # Keeps one backup betwen the two given dates.
    #

    [[ "$#" -eq 2 ]] || { echo "keep_between takes exactly 2 args." >2; exit 1; }
    (echo "$1" | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" > /dev/null) || { echo "Wrong date : $1" >&2; exit 1; }
    (echo "$2" | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" > /dev/null) || { echo "Wrong date : $2" >&2; exit 1; }

    # Keeps one snapshot for the interval [$1 ; $2[
    find "$dst" -maxdepth 1 -type d \( -newermt "$1" -a ! -newermt "$2" \) | grep -E "$snap_exp" | sort | tail -n 1 >> "$keep_file"
}

remove_useless()
{
    # Removes useless snapshots (those that are not listed in $keep_file).
    #

    # Builds the list of snapshots to remove.
    #   Sorts the two files, merges them and removes duplicates.
    #   > man sort for further details.
    #   > man uniq for further details.
    get_snapshots > "$snapshots_file"
    sort "$keep_file" "$snapshots_file" | uniq -u > "$kickout"

    # Removes what's useless :
    local nb_rem=$(cat "$kickout" | wc -l | tr -d " ")
    echo "$nb_rem backups are to be removed."

    while read snap
    do
        unprotect "$snap"
        rm -Rf "$snap"
        echo "Deleted $snap."
    done < "$kickout"

    rm -f "$snapshots_file"
    rm -f "$keep_file"
}

make_link()
{
    # Rename the "inProgress" backup :
    touch -a -m -c -d "$now" "$dst/inProgress"
    mv "$dst/inProgress" "$dst/$now"

    # Build the new "latest" link :
    rm -f "$dst/latest"
    ln -s "$(get_latest_snapshot)" "$dst/latest"
}

purge()
{
    echo "Starting post-backup thinning."

    keep_all "$nb_hours"
    keep_one_per_day "$nb_days"
    keep_one_per_week "$nb_weeks"
    keep_one_per_month "$nb_months"
    keep_one_per_year

    remove_useless

    echo "Post-backup thinning done."
}


backup()
{
    echo "Backing up to $dst/$now."

    if [ ! -z "$link_dest" ]
    then
        unprotect "$link_dest"
    fi

    rsync "${rsync_opts[@]}" "$src" "$dst/inProgress"

    cleanupexit $?
}

needed_space()
{
    needed_space=$(rsync "${rsync_dryrun_opts[@]}" "$src" "$dst/inProgress/" | grep "Total transferred file size" | tr -d "," | tr -s " " | cut -d" " -f5)
    needed_space=$((needed_space*120/100))          # +20% margin
    needed_space=$((needed_space/(1024*1024)))
}

available_space()
{
    avail_space=$(df -m "$dst" | grep "/dev" | tr -s " " | cut -d" " -f4)
}

free_space()
{
    # Checks if nwm has enough space to backup the files.
    # If not, it tries to delete the oldest backups until there is enough free space.
    #

    # Let's see what we need :
    needed_space
    # And what we have :
    available_space

    # Removes oldest backup until there is enough space :
    if [ "$needed_space" -gt "$avail_space" ]
    then
        echo "Starting pre-backup thinning: $needed_space Mo requested, $avail_space Mo available."

        while [ "$needed_space" -gt "$avail_space" ]
        do
            local oldest=$(get_oldest_snapshot)

            if [ ! -z "$oldest" ]
            then
                unprotect "$oldest"
                rm -Rf "$oldest"
                available_space
                echo "Deleted $oldest: $avail_space Mo now available."
            else
                cleanupexit 3 "Not enough space on $dst."
            fi
        done
    else
        echo "No pre-backup thinning needed: $needed_space Mo requested, $avail_space Mo available."
    fi
}

prepare()
{
    # Builds rsync options, depending on the config and the existing backups.
    #

    link_dest=""
    rsync_opts=(-ahAXS --numeric-ids)
    rsync_dryrun_opts=(-a --stats --dry-run)

    if [ "$verbose" = true ]
    then
        rsync_opts+=( -v)
    fi

    if [ "$exclude_file" != "" ]
    then
        if [ -f "$exclude_file" ]
        then
            rsync_opts+=( --exclude-from="$exclude_file")
            rsync_dryrun_opts+=( --exclude-from="$exclude_file")
        else
            echo "The given exclude file does not exist. Please fix your config file. Aborting."
            cleanupexit 1
        fi
    fi

    if [ -h "$dst/latest" ]
    then
        link_dest=$(readlink "$dst/latest")
        rsync_opts+=( --link-dest="$dst/latest")
        rsync_dryrun_opts+=( --link-dest="$dst/latest")
    fi

    # Dates :
    snap_exp=".*/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}"
    now=$(date "+%Y-%m-%d %H:%M:%S")
}

lock()
{
    # Tries to lock the WABAC Machine to ensure we run only one instance at the same time.
    # We use mkdir because it is atomic.
    #
    
    if mkdir "$lockdir" 2>/dev/null
    then
        echo "Successfully acquired lock : starting new backup."
        echo $$ > "$lockdir/pid"
    else
        echo "Couldn't acquire lock (hold by $(<$lockdir/pid)). The WABAC Machine is already running. Aborting."
        exit 1
    fi
}

unlock()
{
    # Allows another instance of the WABAC Machine to run.
    # As we store every temp file in the lockdir directory, it also deletes those.
    #

    rm -Rf "$lockdir"
}

cleanupexit()
{
    # This is the exit door of the WABAC Machine.
    # It does several things :
    #   * Resets trap to its default behavior.
    #   * Rotates the backups.
    #   * Smartly removes old backups.
    #   * Removes the lock file.
    #   * Unmount everything that needs to be unmounted.
    #   * Exit.
    #

    # Reset default error handler :
    trap - SIGHUP SIGINT SIGTERM ERR

    # Print error message if any :
    if [ "$2" != "" ]
    then
        echo "$2">&2
    fi
    
    # Re-protect the backup that was used with link-dest :
    if [ ! -z "$link_dest" ]
    then
        protect "$link_dest"
    fi

    # Handle exit codes :
    #
    #   We have 4 cases :
    #     0  : Everything is OK, we just have to rotate the backups and purge them.
    #     23 : Some files/attrs were not transferred. We consider the backup as OK.
    #     24 : Some files have vanished during the backup. We still consider the backup as OK.
    #     *  : Something went wrong ! We keep the failing backup as it is. We do not rotate. We do not purge.
    #

    case $1 in
        0|23|24)
            make_link
            echo "Backup done."
            echo "Protecting backup."
            protect "$(get_latest_snapshot)"
            purge
            ;;

        *)
            echo "Backup exited with code $1." 2>&1
            echo "WARNING: An error occured while backing up. The backup might be incomplete or corrupt !"
            ;;
    esac

    # Unlock : deletes all temp files and allows another instance of the WABAC Machine to run :
    unlock

    exit $1
}

usage()
{
    cat <<EOH
WABAC Machine version $VERSION.

Copyright (C) 2009-2014 by François Kubler.
<https://github.com/Frzk/WABACMachine/>

WABACMachine.sh comes with ABSOLUTELY NO WARRANTY.  This is free software, and you
are welcome to redistribute it under certain conditions.  See the GNU
General Public Licence for details.

WABAC Machine is a wrapper for rsync that will help you backup your files.

USAGE:  WABACMachine.sh [-h | --help] [-v | --verbose] [-c | --config CONFIG_FILE]

OPTIONS:
  -c, --config CONFIG_FILE  Read configuration from CONFIG_FILE.
  -h, --help                Show HELP (this output).
  -v, --verbose             Produce verbose output. Useful if you want to check what is saved or to complete your exclude file.

FILES:
  WABACMachine.sh           The backup script
  WABACMachine.conf         The default config file
  exclude                   The filter rules

Head over https://github.com/Frzk/WABACMachine/ for further information and help.

EOH
}

run()
{
    # Lock :
    lock

    # Signals trap :
    trap "cleanupexit" SIGHUP SIGINT SIGTERM ERR

    prepare
    check_mounted
    clean
    free_space
    backup
}



# # #   R U N   # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

VERSION=20140617

# 1/ Checks if we are root :

[[ $EUID -eq 0 ]] || { echo "$(basename $0) must be run as root. Aborting."; exit 1; }

# 2/ Parses options :

config_file="$selfdir/WABACMachine.conf"

while [ "$1" != "" ]; do
    case $1 in
        -c | --config )
            shift
            config_file=$1
            ;;
        -v | --verbose )
            verbose=true
            ;;
        -h | --help )
            usage
            exit 1
            ;;
        * )
            usage
            exit 1
    esac
    shift
done

# 3/ Checks if the config_file exists :

[[ -f "$config_file" ]] || { echo "Config file ($config_file) not found. Exiting."; exit 1; }

# 4/ Loads the config_file:

source "$config_file"

# 5/ Runs :

run


# This should never be reached :

cleanupexit 0


#EOF
