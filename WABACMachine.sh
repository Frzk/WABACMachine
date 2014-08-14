#!/bin/bash

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
# latest rev: 2014-08-15
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

# File that contains rsync call errors :
err_file="$lockdir/errors.txt"


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
            errmsg="Unable to mount $vol, aborting !"
            error_exit 1 "$errmsg"
        fi

        echo "OK."
    fi
}

clean()
{
    # Makes sure every needed file is empty.
    #

    rm -f "$keep_file"
    rm -f "$snapshots_file"
    rm -f "$kickout"
    rm -f "$err_file"
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
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { error_exit 1 "keep_all requires an integer."; }

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
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { error_exit 1 "keep_one_per_day requires an integer."; }

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
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { error_exit 1 "keep_one_per_week requires an integer."; }

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
    [[ -n "$1" ]] && [[ $1 != *[!0-9]* ]] || { error_exit 1 "keep_one_per_month requires an integer."; }

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

    [[ "$#" -eq 2 ]] || { error_exit 1 "keep_between takes exactly 2 args."; }
    (echo "$1" | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" > /dev/null) || { error_exit 1 "Wrong date : $1"; }
    (echo "$2" | grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}$" > /dev/null) || { error_exit 1 "Wrong date : $2"; }

    # Keeps one snapshot for the interval [$1 ; $2[
    find "$dst" -maxdepth 1 -type d \( -newermt "$1" -a ! -newermt "$2" \) | grep -E "$snap_exp" | sort | tail -n 1 >> "$keep_file"
}

remove_snapshot()
{
    unprotect "$1"
    rm -Rf "$1"
    echo "Deleted $1."
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
    local nb_rem=$(wc -l < "$kickout")

    case $nb_rem in
    0)
        echo "Nothing to do."
        ;;
    1)
        echo "One backup to be removed."
        ;;
    *)
        echo "$nb_rem backups to be removed."
        ;;
    esac

    while read snap
    do
        remove_snapshot "$snap"
    done < "$kickout"

    rm -f "$snapshots_file"
    rm -f "$keep_file"
}

remove_oldest()
{
    local nb_backups=$(get_snapshots | wc -l)

    if [ $nb_backups -gt 1 ]
    then
        local oldest="$(get_oldest_snapshot)"
        remove_snapshot "$oldest"
        available_space
    else
        error_exit 1 "Seems like we need some space, but there's nothing left to remove !"
    fi
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

available_space()
{
    local df_output=$(df -m $dst | grep "/dev" | tr -s " ")
    
    local avail_space_mo=$(cut -d" " -f4 <<< "$df_output")
    
    local occupied=$(cut -d" " -f5 <<< "$df_output" | cut -d"%" -f1)
    local avail_space_perc=$((100 - occupied))

    echo "Free space : $avail_space_perc% ($avail_space_mo Mo)."
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

backup()
{
    echo "Backing up to $dst/$now."

    if [ ! -z "$link_dest" ]
    then
        echo "Using $link_dest as ref."
        unprotect "$link_dest"
    fi

    completed=false

    until $completed
    do
        rm -Rf "$err_file"
        rsync "${opts[@]}" "$src" "$dst/inProgress" 2> "$err_file"
        rsync_exit_code=$?

        local no_space_left="$(grep "No space left on device (28)\|Result too large (34)" "$err_file")"

        if [ -n "$no_space_left" ]
        then
            remove_oldest
        else
            completed=true
        fi
    done

    # We ignore rsync error code 23 and 24
    #     23 : Some files/attrs were not transferred. We consider the backup as OK.
    #     24 : Some files have vanished during the backup. We still consider the backup as OK.
    case $rsync_exit_code in
        0|23|24)
            make_link
            echo "Backup done."
            echo "Protecting backup."
            protect "$(get_latest_snapshot)"
            purge
            ;;
        *)
            errmsg="An error occured while backing up ($rsync_exit_code). Please check your log to see what happend."
            error_exit $rsync_exit_code "$errmsg"
            ;;
    esac
}

prepare()
{
    # Builds rsync options, depending on the config and the existing backups.
    #

    if [ "$exclude_file" != "" ]
    then
        if [ -f "$exclude_file" ]
        then
            opts+=(--exclude-from="$exclude_file")
        else
            errmsg="The given exclude file does not exist. Please fix your config file. Aborting."
            error_exit 1 "$errmsg"
        fi
    fi

    if [ -h "$dst/latest" ]
    then
        link_dest=$(readlink "$dst/latest")
        opts+=(--link-dest="$dst/latest")
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
        errmsg="Couldn't acquire lock (hold by $(<$lockdir/pid)). The WABAC Machine is already running. Aborting."
        error_exit 1 "$errmsg"
    fi
}

unlock()
{
    # Allows another instance of the WABAC Machine to run.
    # As we store every temp file in the lockdir directory, it also deletes those.
    #

    rm -Rf "$lockdir"
}

error_exit()
{
    echo "$2"
    exit $1
}

setup_traps()
{
    trap "handle_exit" EXIT
    trap "handle_signals" INT TERM HUP QUIT
}

remove_traps()
{
    trap - EXIT INT TERM HUP QUIT
}

handle_signals()
{
    sig=$?

    if [ $sig -gt 127 ]
    then
        let sig-=128
        local signame=$(kill -l $sig)
    else
        local signame="RSYNC_INTERRUPT"
    fi

    errmsg="The WABAC Machine has been interrupted ($signame) !"
    error_exit $sig "$errmsg"

    # Propagate SIGHUP, SIGTERM and SIGINT :
    #kill -s $sig $$
}

handle_exit()
{
    # This is the exit door of the WABAC Machine.
    #
    errno=$?

    # Reset traps :
    remove_traps

    # Re-protect the backup that was used with link-dest :
    if [ ! -z "$link_dest" ]
    then
        protect "$link_dest"
    fi

    # Unlock so another instance can run :
    unlock

    # And finally exit :
    exit $errno
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

USAGE:  WABACMachine.sh [-h | --help] [-c | --config CONFIG_FILE]

OPTIONS:
  -c, --config CONFIG_FILE  Read configuration from CONFIG_FILE.
  -h, --help                Show HELP (this output).

FILES:
  WABACMachine.sh           The backup script
  WABACMachine.conf         The default config file
  exclude                   The filter rules

Head over https://github.com/Frzk/WABACMachine/ for further information and help.

EOH
}

run()
{
    lock
    setup_traps
    prepare
    check_mounted
    clean
    backup
    available_space
}



# # #   R U N   # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # 

VERSION=20140815

# 1/ Checks if we are root :
[[ $EUID -eq 0 ]] || { error_exit 1 "$(basename $0) must be run as root. Aborting."; }

# 2/ Parses options :
config_file="$selfdir/WABACMachine.conf"

while [ "$1" != "" ]
do
    case $1 in
        -c | --config )
            shift
            config_file=$1
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
[[ -f "$config_file" ]] || { error_exit 1 "Config file ($config_file) not found. Exiting."; }

# 4/ Loads the config_file:
source "$config_file"

# 5/ Runs :
run

# 6/ This should never be reached :
exit 0

#EOF