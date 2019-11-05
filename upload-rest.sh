#!/bin/sh

#
# Software Name : Fossology Helper Tools
# Version: 1.0
# Copyright (c) 2019 Orange Business Services
# SPDX-License-Identifier: MIT
#
# This software is distributed under the MIT License
# the text of which is available at https://spdx.org/licenses/MIT.html
# or see the "license.txt" file for more details.
#
# Author: Nicolas Toussaint nicolas1.toussaint@orange.com
# Software description: Fossology helper tools
#

# Exec example:
# ./upload-rest.sh -f Sandbox/001 -i foobar-3.zip
#                  -n fossy -p fossy
#                  -s "https://<fqdn>/repo"
#
# For HTTPS GIT clones, the script will use the following
# environment variable, if they exist
# GIT_USERNAME=
# GIT_PASSWORD=
#

_debug="false"
folder="Software Repository"

# Stores the reply data from the latest Rest call.
JSON_REPLY_FILE=$(mktemp) || f_fatal "Cannot create temp file"

while getopts "derf:i:u:g:t:s:h:n:p:" opt; do
        case $opt in
        i) input_file_full=$OPTARG ; shift ;;
        u) input_git_url=$OPTARG ; shift ;;
        g) group_id=$OPTARG ; shift ;;
        f) folder=$OPTARG ; shift ;;
        d) _debug="true" ;;
        e) _debug="true" ; _extra_debug="true" ;;
        r) _reuse="true" ;;
        t) t_tkn=$OPTARG ; shift ;;
        n) t_usr=$OPTARG ; shift ;;
        p) t_pwd=$OPTARG ; shift ;;
        h) rest_url=$OPTARG ; shift ;;
        s) site_url=$OPTARG ; shift ;;
        \?) _usage 1 ;;
        esac
        shift
done

_usage() {
cat <<-EOS

Usage: $(basename $0)
  $(basename $0) <authentication> <urls options> <upload options> [other options...]

Authentication: Either a token or a user+password options should be provided (a token will be created).
  - Token authentication: $(basename $0) -t <...> ...
  - User+Password authentication: $(basename $0) -n <...> -p <...>

URLs options: Specify the Service URL, optionnally the Rest API URL
  - $(basename $0) -s <service_fqdn> [ -h <rest_api_url> ]

Upload Options: Upload either a binary file, or a GIT repository
  - $(basename $0) -i <upload-file>
  - $(basename $0) -u <git-url>

Other options:
 -f <folder> : Folder in which the upload will be added
 -d : Debug mode
 -e : Extra Debug mode
 -g : Group under which the upload will be created
 -r : Enable reuse (not finalized)
EOS
        exit $1
}

f_extra_debug() {
        echo "$_extra_debug" | grep -q "^true$"
}

f_debug() {
        echo "$_debug" | grep -q "^true$"
}

f_log_part() {
cat >&2 <<-EOS

======================================
=== $*
======================================

EOS
}

f_fatal() {
        echo
        echo "Fatal: $@"
        exit 1
}

# Execute REST Query
# Full Curl command output stored in the file $JSON_REPLY_FILE
#
# Arg1. HTTP Verb: GET or POST
# Arg2. Action to be appended to REST base URI
# Arg+. All other query parameters
#
# Returns:
# x 0 on Success - Json contains a "Code" entry in the 200 family
# x Json error code otherwise.
# x 999 on Curl error
#
f_do_curl() {
        http_verb=$1
        rest_action=$2
        shift 2
        [ -s "$JSON_REPLY_FILE" ] && >$JSON_REPLY_FILE
        f_debug && set -x
        curl -k -s -S -X $http_verb $rest_url/$rest_action "$@" > $JSON_REPLY_FILE
        rc=$?
        set +x
        if f_debug
        then
                echo "CURL output file: $JSON_REPLY_FILE" >&2
                [ $rc -ne 0 ] && echo "CURL exit code  : $rc" >&2
        fi
        [ $rc -ne 0 ] && return 999
        head -n 1 $JSON_REPLY_FILE | jq . >/dev/null || f_fatal "Reply is not JSON"
        if f_extra_debug
        then
                echo "=== JSON OUTPUT ===" >&2
                cat $JSON_REPLY_FILE | jq . >&2
        fi
        local code=$(cat $JSON_REPLY_FILE | jq 'try .code  catch 0 |  if . == null then 0 else . end')
        if echo "$code" | grep -q '^[02]'
        then
                return 0
        else
cat <<-EOS
ERROR:
  Code: $(cat $JSON_REPLY_FILE | jq '.code')
  Message: $(cat $JSON_REPLY_FILE | jq '.message')
EOS
                return $code
        fi

}

f_get_token_expire_date() {
        local now=$(date +%s)
        local exp=$((now + token_validity_days * 24 * 60 * 60))
        date +%Y-%m-%d --date="@$exp"
}

# Echo Folder ID if found
# Return 0 if found, 1 otherwise
# Arg 1: Folder name
# Arg 2: Parent folder ID

f_get_folder_id() {
        f_do_curl GET folders -H "$t_auth" || f_fatal "Failed to list folders"
        _folder_id=$(jq ".[] | select(.\"name\" == \"$1\" and .\"parent\" == $2) | .\"id\"" $JSON_REPLY_FILE)
        [ -n "$_folder_id" ] || return 1
        echo $_folder_id
        return 0
}

[ -n "$input_file_full$input_git_url" ] || _usage 1
[ -n "$site_url" ] || _usage 1
[ -n "$rest_url" ] || rest_url="$site_url/api/v1"

[ -n "$input_file_full" ] && upload_name="$(basename $input_file_full)"
[ -n "$input_git_url" ] && upload_name="$(echo $input_git_url | sed 's_.*/__')"
token_validity_days=2
token_scope="write"

cat <<EOS

Host Target: $rest_url
Username   : $t_usr
Group ID   : $group_id
Pwd size   : $(echo $t_pwd | wc -c)
Token      : $(echo $t_tkn | cut -c 1-16)...
Debug      : $_debug
Extra Debug: $_extra_debug
Folder     : $folder
Upload Name: $upload_name

JSON_REPLY_FILE: $JSON_REPLY_FILE

EOS

# #############################################################################
# Authentication
# #############################################################################

f_log_part "Authentication"
if [ -n "$t_tkn" ]
then
        echo "Using provided token"
else
        echo "No Token, trying to generate one"
        if ! echo "$t_usr:$_pwd" | grep -q "^..*:..*$"
        then
                token_name="ci-cd_$(date +%Y%m%d-%H%M%S)"
                token_expire=$(f_get_token_expire_date)
cat <<-EOS
== Create token:
- Valitidy: $token_validity_days days
- Expires : $token_expire
- Name    : $token_name
- Scope   : $token_scope

EOS

                options_json=$(jq -n \
                        --argjson user_username "\"$t_usr\"" \
                        --argjson user_password "\"$t_pwd\"" \
                        --argjson token_name    "\"$token_name\"" \
                        --argjson token_scope   "\"$token_scope\"" \
                        --argjson token_expire  "\"$token_expire\"" \
                        -f "json-templates/request-token.json") || \
                        f_fatal "JQ operation failed"
                f_do_curl POST tokens \
                        -H "Content-Type: application/json" \
                        -d "$options_json" || f_fatal "REST command failed"
                t_tkn=$(jq '."Authorization"' $JSON_REPLY_FILE | sed 's/Bearer //' | tr -d '"')
                [ -z "$t_tkn" ] && f_fatal "Failed to create token"
                [ "$t_tkn" = "null" ] && f_fatal "Failed to create token"
                echo "Token: $(echo $t_tkn | cut -c 1-16)..."
        fi
fi

t_auth="Authorization:Bearer $t_tkn"

[ -z "$t_tkn" ] && f_fatal "No Token"

# #############################################################################
# Folders
# #############################################################################

f_log_part "Folder"

# List Folder
# Searches and create if nedded the folders at each level
# Reads successive folfer names
# Echo last folder ID to stdout
f_handle_folders() {
        local parent_id=1
        local level_id=
        while read level_name
        do
                if level_id=$(f_get_folder_id "$level_name" $parent_id)
                then
                        f_debug && echo "=- Found  : $level_name : $level_id" >&2
                else
                        # Create a new folder
                        f_do_curl POST folders -H "$t_auth" \
                                -H "parentFolder:$parent_id" \
                                -H "folderName:$level_name" \
                                || f_fatal "Failed to create folder '$level_name'"
                        level_id=$(f_get_folder_id "$level_name" $parent_id) || \
                                f_fatal "Failed to find created folder"
                        f_debug && echo "=- Created: $level_name : $level_id" >&2
                fi
                parent_id=$level_id
        done
        echo $level_id
}

echo "Folder path: '$folder'"

folder_id=$(echo "$folder" | tr '/' '\n' | f_handle_folders)
echo "Folder ID: $folder_id"
[ -n "$folder_id" ] || f_fatal "Bug."

# #############################################################################
# Upload
# #############################################################################

f_log_part "Upload"

[ -n "$group_id" ] && option_groupid="-H uploadGroupId:$group_id"
if [ -n "$input_file_full" ]
then
        echo "Upload file: $input_file_full"
        f_do_curl POST  uploads -H "$t_auth" $option_groupid \
                -H "folderId:$folder_id" \
                -H "uploadDescription:REST Upload - from File" \
                -H "public:private" \
                -H "ignoreScm:true" \
                -H "Content-Type:multipart/form-data" \
                -F "fileInput=@\"$input_file_full\";type=application/octet-stream" \
                || f_fatal "REST command failed"
elif [ -n "$input_git_url" ]
then
        echo "Upload GIT URL: $input_git_url"
        options_json=$(jq -n \
                --argjson vcs_url "\"$input_git_url\"" \
                --argjson vcs_username "\"$GIT_USERNAME\"" \
                --argjson vcs_password "\"$GIT_PASSWORD\"" \
                -f "json-templates/upload-vcs_auth.json") || \
                f_fatal "JQ operation failed"
        f_do_curl POST  uploads -H "$t_auth" \
                -H "folderId:$folder_id" \
                -H "uploadDescription:REST Upload - from VCS" \
                -H "public:private" \
                $option_json_username $option_json_password \
                -H "Content-Type:application/json" \
                -d "$options_json" \
                || f_fatal "REST command failed"
else
        f_fatal "BUG - Upload"
fi

upload_id=$(cat $JSON_REPLY_FILE | jq .message)
echo "Upload ID : $upload_id"

# that's a pretty clunky way to find the item ID to build the URL, but works for now
f_do_curl GET search -H "$t_auth" -H "filename:$upload_name" || f_fatal "Failed to search folder"

####################################################""
# /!\ UNRELIABLE REQUEST BECAUSE OF SQL CACHE ISSUE
# Requires fix for: https://github.com/fossology/fossology/issues/1481
item_id=$(cat $JSON_REPLY_FILE | jq ".[-1] | select(.\"upload\".\"folderid\" == $folder_id) | .uploadTreeId")
# TODO: filter with 'upload:#' option, when it works
f_do_curl GET "jobs?upload=$upload_id" -H "$t_auth" || f_fatal "Failed to find upload job"
job_status=$(jq '.[].status' $JSON_REPLY_FILE)
job_id=$(jq '.[].id' $JSON_REPLY_FILE)
group_id_n=$(jq '.[].groupId' $JSON_REPLY_FILE)
job_upload_eta=$(jq '.[].eta' $JSON_REPLY_FILE)

cat <<EOS

- Upload ID: $upload_id
- Job ID   : $job_id
- Group ID : $group_id_n
- Job ETA  : $job_upload_eta

EOS

echo "Unpack job: started"
mark=
while true
do
        f_do_curl GET "jobs?upload=$upload_id" -H "$t_auth" || f_fatal "Failed to find upload job"
        upload_status=$(jq '.[].status' $JSON_REPLY_FILE | tr -d '"')
        case $upload_status in
        "Queued") mark="Q" ;;
        "Processing") mark="P" ;;
        "Completed") break ;;
        "Failed") f_fatal "Upload Job Failed" ;;
        *) f_fatal "BUG."
        esac
        echo -n "$mark"
        sleep 1
done
[ -n "$mark" ] && echo
echo "Unpack job: terminated with status '$upload_status'"

# #############################################################################
# Scan Job
# #############################################################################

f_log_part "Trigger Scan Jobs"

if [ "$_reuse" = "true" ]
then
        # Try to guess previous upload, to use it as a base for reuse.
        f_do_curl GET search -H "$t_auth" -H "filename:$upload_name" || fatal "Failed to search folder"
        previous_upload_id=$(cat $JSON_REPLY_FILE | jq '.[-2].upload.id')
        scan_options_file="json-templates/scan-options-reuse.json"
        [ -z "$previous_upload_id" ] && f_fatal "Failed to find ID for reuse"
        jq_reuse_args="--argjson reuse_upload $previous_upload_id --argjson reuse_group $group_id_n"
        echo "REUSE: Previous Upload ID: $previous_upload_id"
else
        scan_options_file="json-templates/scan-options.json"
        echo "REUSE: Disabled"
fi

cat <<EOS
Input file: $input_file_full
Input Git URL: $input_fit_url
item_id: $item_id

Fossology Link: $site_url/?mod=license&upload=$upload_id&folder=$folder_id&item=$item_id

EOS

options_json=$(jq -n $jq_reuse_args -f $scan_options_file) || f_fatal "JQ operation failed"
f_do_curl POST  jobs -H "$t_auth" \
        -H "Content-Type:application/json" \
        -H "folderId:$folder_id" \
        -H "uploadId:$upload_id" \
        -d "$options_json" || f_fatal "Failed to start scan"


f_log_part "End"
