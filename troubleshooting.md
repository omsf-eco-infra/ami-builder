# Troubleshooting Tips


* If it fails with a bunch of JSON files missing, check whether you ran out of disk space. This might happen if the disk mapping changes from `dev/sda1`.
* If the AMI fails while in a "waiting for AMI to become ready" state, the problem is likely that the AMI is very large (50+ GB). Change the timeout settings to a larger value (or, better yet, see if you can shrink the AMI!)
