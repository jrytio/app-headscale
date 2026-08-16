#!/bin/bash
# Standalone test entrypoint: fake the Supervisor, then boot s6 normally.
set -e
echo "127.0.0.1 supervisor" >> /etc/hosts
# Serve the static mock tree as the Supervisor API.
# NOTE: the base image's `busybox` binary does not include the httpd applet;
# it ships in the separate busybox-extras package (added to the Dockerfile's
# apk list in this task), exposed via the /usr/sbin/httpd symlink.
/usr/sbin/httpd -p 127.0.0.1:80 -h /test/supervisor-mock
exec /init
