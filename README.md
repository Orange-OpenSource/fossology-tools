# fossology-tools

This repository gathers some Fossology helpers built by Orange and Orange Business Services.


## Script: `upload-rest.sh`

This is an example script that performs the following:
1. [optional] create a token from username + password
1. Create all required folders
1. Upload a binary file, or Git URL
1. Wait for unpack job to finish successfuly (polling)
1. [optional] looks up previous upload for Reuse.
1. Trigger scan jobs
1. Build URL to browse in Fossology


Notes:
- Autentication: Use either the username+pasword OR the token option.
- GIT proxy credentials may be provided via environment variables
- You can specify the Group ID to which the upload will belong
- The REST API URL can be provided separately

Caveats:
- Group ID: works to upload, but not to trigger a job (yet)
- Group Name: Only the group ID can be specified, not the group name.

