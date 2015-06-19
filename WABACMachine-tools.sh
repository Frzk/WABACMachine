#!/bin/bash

# The WABAC Machine Tools.
#
# These functions are made available with the hope that they will be
# helpful when writting preflight/postflight scripts.
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


###   OSX   #   AFP   # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

osx_mount_afp_share()
{
    # Connects to the given host, and mounts the given AFP share in the given mount point.
    #     $1 : Host
    #     $2 : Share
    #     $3 : User
    #     $4 : Password
    #     $5 : Mount point for the AFP share

    # mount_afp exit codes :
    #     0  : OK
    #     19 : The server volume could not be mounted by mount_afp because the server was not found
    #          or because the sharepoint does not exist, or because node does not have proper
    #          access.
    #     13 : The volume could not be mounted by mount_afp because the user did not provide proper
    #          authentication credentials.
    #     20 : The volume could not be mounted by mount_afp because the mountpoint was not a directory.

    local exit_code
    local host
    local share
    local user
    local pass
    local mount_point
    local afp_connexion_string
    local mount_afp_output

    exit_code=0
    host="${1}"
    share="${2}"
    user="${3}"
    pass="${4}"
    mount_point="${5}"

    if [ ! -d "${mount_point}" ]
    then
        mkdir -p "${mount_point}"
        exit_code=$?
    fi

    if [ ${exit_code} -ne 0 ]
    then
        printf "An error occured while trying to create the mount point (%s) for %s/%s.\n" "${mount_point}" "${host}" "${share}" 1>&2
    else
        if [ "$(ls -A ${mount_point})" ]
        then
            # Seems like ${host} is already mounted in ${mount_point}.
            printf "%s/%s seems to be already mounted in %s.\n" "${host}" "${share}" "${mount_point}" 1>&2
        else
            # We have to mount the share.
            afp_connexion_string=$(printf "afp://%s:%s@%s/%s" "${user}" "${pass}" "${host}" "${share}")
            mount_afp_output=$(mount_afp "${afp_connexion_string}" "${mount_point}" 2>&1)
            exit_code=$?

            if [ ${exit_code} -eq 0 ]
            then
                printf "Successfully connected to %s/%s.\n" "${host}" "${share}"
            else
                printf "An error occured while trying to mount %s/%s (%s).\n" "${host}" "${share}" "${mount_afp_output}" 1>&2
                rmdir -p "${mount_point}" > /dev/null 2>&1
            fi
        fi
    fi

    return ${exit_code}
}



osx_unmount_afp_share()
{
    #
    #     $1 : Host
    #     $2 : Mount point for the AFP share
    #

    local exit_code
    local host
    local mount_point
    local unmount_output

    exit_code=0
    host="${1}"
    mount_point="${2}"

    unmount_output=$(umount "${mount_point}" 2>&1)
    exit_code=$?

    if [ ${exit_code} -ne 0 ]
    then
        printf "An error occured while trying to disconnect from %s (%s).\n" "${host}" "${unmount_output}" 1>&2
    fi

    return ${exit_code}
}



###   OSX   #   SPARSEBUNDLE   # # # # # # # # # # # # # # # # # # # # # # # # #

osx_mount_sparsebundle()
{
    # Mounts the given sparsebundle file.
    #     $1 : Path to the sparsebundle file to mount.
    #     $2 : Password needed to mount the sparsebundle file.
    #

    local exit_code
    local sparsebundle
    local pass
    local hdiutil_output
    local mount_point

    sparsebundle="${1}"
    pass="${2}"

    hdiutil_output=$(printf "%s" "${pass}" | hdiutil attach "${sparsebundle}" -noverify -noautofsck -readwrite -owners on -stdinpass 2>&1)
    exit_code=$?

    if [ ${exit_code} -ne 0 ]
    then
        printf "An error occured while trying to attach %s (%s).\n" "${sparsebundle}" "${hdiutil_output}" 1>&2
    else
        mount_point=$(tr -d "\t" <<< "${hdiutil_output}" | tr -s " " | cut -d" " -f2)
        printf "%s\n" "${mount_point}"
    fi

    return ${exit_code}
}



osx_unmount_sparsebundle()
{
    # Unmounts the given mount point.
    #     $1 : Mount point
    #

    local exit_code
    local mount_point
    local hdiutil_output

    mount_point="${1}"

    hdiutil_output=$(hdiutil detach "${mount_point}" 2>&1)
    exit_code=$?

    if [ ${exit_code} -ne 0 ]
    then
        printf "An error occured while trying to detach %s (%s).\n" "${mount_point}" "${hdiutil_output}" 1>&2
    fi

    return ${exit_code}
}



###   OSX   #   SECURITY   # # # # # # # # # # # # # # # # # # # # # # # # # # #

osx_get_user_from_keychain_for_afp_share()
{
    # Retrieves the user name for the given AFP host in the System keychain.
    #     $1 : AFP host
    #

    local exit_code
    local afp_host
    local security_output
    local user
    local err

    user=""
    afp_host="${1}"

    security_output=$(security 2>&1 find-internet-password -D "AFP Share Password" -s "${afp_host}" -g /Library/Keychains/System.keychain)
    exit_code=$?

    if [ ${exit_code} -ne 0 ]
    then
        err=$(security error "${exit_code}")
        printf "Could not retrieve credentials for %s in the System Keychain (%s).\n" "${afp_host}" "${err}" 1>&2
    else
        user=$(head -n 7 <<< "${security_output}" | tail -n 1 | cut -d "\"" -f 4)
    fi

    printf "%s\n" "${user}"

    return ${exit_code}
}



osx_get_pass_from_keychain_for_afp_share()
{
    # Retrieves the password for the given AFP host in the System keychain.
    #     $1 : AFP host
    #

    local exit_code
    local afp_host
    local security_output
    local pass
    local err

    pass=""
    afp_host="${1}"

    security_output=$(security 2>&1 find-internet-password -D "AFP Share Password" -s "${afp_host}" -g /Library/Keychains/System.keychain)
    exit_code=$?

    if [ ${exit_code} -ne 0 ]
    then
        err=$(security error "${exit_code}")
        printf "Could not retrieve credentials for %s in the System Keychain (%s).\n" "${afp_host}" "${err}" 1>&2
    else
        pass=$(head -n 1 <<< "${security_output}" | cut -d "\"" -f 2)
    fi

    printf "%s\n" "${pass}"

    return ${exit_code}
}



osx_get_pass_from_keychain_for_sparsebundle()
{
    # Retrieves the password for the given sparsebundle in the System keychain.
    #     $1 : AFP host
    #

    local exit_code
    local sparsebundle
    local security_output
    local pass
    local err

    pass=""
    sparsebundle="${1}"

    security_output=$(security 2>&1 find-generic-password -a root -D "Image Disk Password" -s "${sparsebundle}" -g /Library/Keychains/System.keychain)
    exit_code=$?

    if [ ${exit_code} -ne 0 ]
    then
        err=$(security error "${exit_code}")
        printf "Could not retrieve credentials for %s in the System Keychain (%s).\n" "${sparsebundle}" "${err}" 1>&2
    else
        pass=$(head -n 1 <<< "${security_output}" | cut -d "\"" -f 2)
    fi

    printf "%s\n" "${pass}"

    return ${exit_code}
}



###   OSX   #   NOTIFICATIONS   # # # # # # # # # # # # # # # # # # # # # # # #

osx_notify()
{
    # Displays a notification.
    #     $1 : Title
    #     $2 : Message
    #

    local command

    command=$(printf "display notification %s with title %s" "${2}" "${1}")
    osascript -e "${command}"
}



###   EOF   # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
