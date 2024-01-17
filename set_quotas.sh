#!/usr/bin/env bash

FSNAME=testfs
LUSTRE_MOUNTPOINT=/lustre/testfs/client
LOGFILE=/tmp/quotas.log
TMP_LOGFILE=/tmp/quotas.tmp.log
DEFAULT_INPUT_FILE=

#TODO Replace with absolute paths
AWK=$(type -P awk)
CAT=$(type -P cat)
CHMOD=$(type -P chmod)
CHOWN=$(type -P chown)
CUT=$(type -P cut)
DATE=$(type -P date)
GETENT=$(type -P getent)
GREP=$(type -P grep)
HEAD=$(type -P head)
LFS=$(type -P lfs)
MKDIR=$(type -P mkdir)
MOUNT=$(type -P mount)
RM=$(type -P rm)
SORT=$(type -P sort)
TAIL=$(type -P tail)

DDN_LUSTRE_MOUNT=$(type -P mount-lustre-client)

__LUSTRE_COMMANDS=$(mktemp)
__SHELL_PID=$$

TIMESTAMP="[\$($DATE --rfc-3339=seconds)]"

function utils::cleanup() {
    # Cleanup temporary files and unmount lustre filesystem
    $RM -f $__LUSTRE_COMMANDS
    lustre::fs::umount

    exit
}

# Run the cleanup function on exit or when receiving SIGINT or SIGTERM
trap utils::cleanup SIGINT SIGTERM EXIT

function utils::usage() {
    $CAT << EOF
Usage: $0 <quota_spec>

This program will create or update the project folders in the lustre
filesystem named \`$FSNAME\` with the quotas specified in <quota_spec>.
There are two operation modes depending on the format of the spec:

1. Create a new project folder with a quota
    <project_dir> <quota> <group> <user> <mode>

    <project_dir> is the path to the project folder
    <quota> is the quota in TB
    <group> is the group owning the project folder
    <user> is the user owning the project folder
    <mode> is the mode of the project folder

    This will create a new project folder with the specified quota and set the
    permissions to the specified mode. The project folder will be owned by the
    specified user and group. If the project exists, the project will not be
    modified, but the permissions will.

2. Update an existing project folder with a new quota
    <project_dir> <quota>

    <project_dir> is the path to the project folder
    <quota> is the quota in TB

    This will update the quota of the project folder. The quota can be
    specified as an absolute value or as a relative value. If the quota is
    specified as a relative value, it must be prefixed with a + or a - sign.
    The quota will be updated by adding the relative value to the current
    quota. If the quota is specified as an absolute value, the quota will be
    set to the specified value.

The two operation modes can be used in the same spec. Example:
# Mountpoint	Quota(TB)	Group	User	Mode(Octal)
$LUSTRE_MOUNTPOINT/mount1	250	grp1	admin-usr	0775
$LUSTRE_MOUNTPOINT/mount2	+2
$LUSTRE_MOUNTPOINT/mount3 50 grp4 admin-usr 0555

Applied changes will be appended to $LOGFILE.
Commands to apply the changes will be written to $TMP_LOGFILE each run.
EOF
}

function utils::critical() {
    # Print an error message and kill the current shell, triggering cleanup
    if [[ -n $FILE && -n $LINE_N ]]; then
        echo "ERROR: $FILE:$LINE_N: $1" >&2
    else
        echo "ERROR: $1" >&2
    fi

    kill -s TERM $__SHELL_PID
}

function utils::error() {
    # Print an error message and kill the current shell, triggering cleanup
    if [[ -n $FILE && -n $LINE_N ]]; then
        echo "ERROR: $FILE:$LINE_N: $1" >&2
    else
        echo "ERROR: $1" >&2
    fi
}

function utils::warning() {
    # Print an error message and kill the current shell, triggering cleanup
    if [[ -n $FILE && -n $LINE_N ]]; then
        echo "WARN: $FILE:$LINE_N: $1" >&2
    else
        echo "WARN: $1" >&2
    fi
}

function lustre::fs::mountpoint() {
    # Return the mountpoint of the lustre filesystem named $FSNAME
    echo $($MOUNT                   \
        | $GREP -e ":/$FSNAME"      \
        | $AWK '{print $3}')
}

function lustre::fs::umount() {
    # Unmount the lustre filesystem named $FSNAME
    MOUNTPOINT=$(lustre::fs::mountpoint)

    if [[ $MOUNTPOINT && -z $EXISTING_MOUNTPOINT ]]; then
        umount $MOUNTPOINT
    fi
}

function lustre::fs::mount() {
    # Mount the lustre filesystem named $FSNAME on $LUSTRE_MOUNTPOINT
    # If the filesystem is already mounted, use the existing mountpoint
    MOUNTPOINT=$(lustre::fs::mountpoint)

    if [[ -z $MOUNTPOINT ]]; then
        mount_command="$($DDN_LUSTRE_MOUNT --fs $FSNAME -n \
            | $AWK '{print $1" "$2" "$3" "$4}') $LUSTRE_MOUNTPOINT"
        $mount_command
    else
        utils::warning "Using \`$FSNAME\` mount on $MOUNTPOINT"
        export LUSTRE_MOUNTPOINT=$MOUNTPOINT
        export EXISTING_MOUNTPOINT=1
    fi

    export MAX_PROJID=$(lustre::fs::max_projid)
}

function lustre::fs::check() {
    # Check that the lustre filesystem is mounted
    # If $1 is set, check that it is in the lustre filesystem
    MOUNTPOINT=$(lustre::fs::mountpoint)
    if [[ -z $MOUNTPOINT ]] ; then
        utils::critical "Lustre filesystem not mounted"
    fi

    if [[ $1 && ! $1 = "$MOUNTPOINT"* ]]; then
        utils::critical "Directory \`$1\` is not in the lustre filesystem"
    fi
}

function lustre::fs::max_projid() {
    # Return the maximum defined project id for the filesystem
    lustre::fs::check

    PROCFILE=/proc/fs/lustre/qmt/$FSNAME-*/dt-0x0/glb-prj

    MAX=$($CAT $PROCFILE 2>/dev/null        \
        | $GREP id                          \
        | $AWK '{print $3}'                 \
        | $SORT -n                          \
        | $TAIL -n 1)

    if [[ -z $MAX ]]; then
        utils::critical "Unable to determine maximum projid, check $PROCFILE"
    fi

    echo $MAX
}

function lustre::fs::get_dir_projid() {
    # Get the projid of a directory
    # /!\ This can return an empty string and it is legal
    local dir="$1"

    lustre::fs::check

    echo $($LFS project -d $dir 2>/dev/null | $AWK '{print $1}')
}

function lustre::fs::get_dir_quota() {
    # For a given directory, return the quota in kbytes
    local dir="$1"

    lustre::fs::check "$dir"

    PROJECT_ID=$(lustre::fs::get_dir_projid "$dir")

    # Return if the project id is null or default
    if [[ -z $PROJECT_ID || $PROJECT_ID -eq 0 ]]; then
        echo 0
        return
    fi

    KBYTES=$($LFS quota -p $PROJECT_ID $dir                 \
      | $HEAD -n 4                                          \
      | $TAIL -n 1                                          \
      | $AWK '{print $2}')

    echo $KBYTES
}

function utils::get_uid() {
    local user="$1"

    OID=$($GETENT passwd $user | $CUT -d: -f3)

    if [[ -z $OID ]]; then
        utils::critical "User $user not found"
    fi

    echo $OID
}

function utils::get_gid() {
    local group="$1"

    GID=$($GETENT group $group | $CUT -d: -f3)

    if [[ -z $GID ]]; then
        utils::critical "Group $group not found"
    fi

    echo $GID
}

function quotas::set() {
    # Add to __LUSTRE_COMMANDS the commands to set the quota
    local PROJ_DIR="$1"
    local QUOTA="$2"
    local GROUP="$3"
    local USER="$4"
    local MODE="$5"

    local SPEC="$PROJ_DIR	$QUOTA	$GROUP	$USER	$MODE"

    lustre::fs::check "$PROJ_DIR"

    # Convert quotas in TB to KB
    KBYTES=$((QUOTA*1024*1024*1024))

    OID=$(utils::get_uid $USER)
    GID=$(utils::get_gid $GROUP)

    # Check for a project id for the PROJ_DIR
    PROJID=$(lustre::fs::get_dir_projid "$PROJ_DIR")

    # If the PROJID is not set or if it is default (0), assign one
    if [[ -z $PROJID || $PROJID -eq 0 ]]; then
        export MAX_PROJID=$((MAX_PROJID + 1))
        PROJID=$MAX_PROJID
    else
        # Warn the user that a new project id will not be created
        utils::warning "Respecting \`$PROJ_DIR\` associated projid $PROJID"
    fi

    echo "$MKDIR -p $PROJ_DIR"                  >> $__LUSTRE_COMMANDS
    echo "$CHOWN -R $OID:$GID $PROJ_DIR"        >> $__LUSTRE_COMMANDS
    echo "$CHMOD -R $MODE $PROJ_DIR"            >> $__LUSTRE_COMMANDS
    echo "$LFS project -p $PROJID -s $PROJ_DIR" >> $__LUSTRE_COMMANDS
    echo "$LFS setquota -p $PROJID -b $KBYTES -B $KBYTES $PROJ_DIR" >> $__LUSTRE_COMMANDS

    echo "echo \"$TIMESTAMP $SPEC\" >> $LOGFILE" >> $__LUSTRE_COMMANDS
}

function quotas::update() {
    local PROJ_DIR="$1"
    local QUOTA="$2"

    local SPEC="$PROJ_DIR	$QUOTA"

    lustre::fs::check "$PROJ_DIR"

    # Check for a project id for the PROJ_DIR
    PROJID=$(lustre::fs::get_dir_projid "$PROJ_DIR")

    if [[ -z $PROJID ]]; then
        utils::critical "No project id found for $PROJ_DIR"
    fi

    local KBYTES=$(lustre::fs::get_dir_quota "$PROJ_DIR")
    local DELTA=$((QUOTA*1024*1024*1024))
    case "${QUOTA:0:1}" in
        "+")
            KBYTES=$((KBYTES + DELTA))
            ;;
        "-")
            # Ensure that the quota will not be negative
            if [[ $KBYTES -lt $((-1*DELTA)) ]]; then
                utils::critical "Quota of $PROJ_DIR would be negative, \
current is $((KBYTES/1024/1024/1024)) TB ($KBYTES KB)"
            fi
            KBYTES=$((KBYTES + DELTA))
            ;;
        *)
            KBYTES=$DELTA
            ;;
    esac

    echo "$LFS setquota -p $PROJID -b $KBYTES -B $KBYTES $PROJ_DIR" >> $__LUSTRE_COMMANDS
    echo "echo \"$TIMESTAMP $SPEC\" >> $LOGFILE" >> $__LUSTRE_COMMANDS
}

function spec::parse_line() {
    # Parse a line of the quota spec file and add the necessary commands to
    # apply the required changes to __LUSTRE_COMMANDS
    local PARAMS=($1)

    # Return if line is a comment
    if [[ $1 == \#* ]]; then
        return
    fi

    # Return if line does not contain 2 or 5 parameters
    case ${#PARAMS[@]} in
        5)
            quotas::set ${PARAMS[0]} ${PARAMS[1]} \
                ${PARAMS[2]} ${PARAMS[3]} ${PARAMS[4]}
            ;;
        2)
            quotas::update ${PARAMS[0]} ${PARAMS[1]}
            ;;
        *)
            utils::critical "Badly formatted line"
            ;;
    esac
}

function spec::parse() {
    # Parse the quota spec, keep track of the line number for more relevant
    # error messages
    export FILE="$1"
    LINE_N=0

    while read LINE; do
        export LINE_N=$((LINE_N + 1))
        spec::parse_line "$LINE"
    done < $FILE
}

function execute() {
    # Record the changes in the temporary log file
    $CAT $__LUSTRE_COMMANDS > $TMP_LOGFILE

    # Execute the commands in __LUSTRE_COMMANDS
    # This will append spec elements to $LOGFILE
    while read COMMAND; do
        bash -c "$COMMAND"
    done < $__LUSTRE_COMMANDS
}

function main() {
    local INPUT="$DEFAULT_INPUT_FILE"

    if [[ $# -ge 1 ]]; then
        INPUT="$1"
    fi

    if [[ ! -f "$INPUT" ]] ; then
        utils::error "Input file error: No such file: $INPUT"
        utils::usage
        exit 1
    fi

    lustre::fs::mount
    spec::parse "$INPUT"
    execute
}

main $@
