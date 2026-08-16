#!/bin/bash
# Standalone test entrypoint: fake the Supervisor, then boot s6 normally.
set -e
echo "127.0.0.1 supervisor" >> /etc/hosts

# bashio::config reads options via GET /addons/self/options/config against
# this mock httpd — it does NOT read /data/options.json directly. The mock
# tree is bind-mounted read-only at /test, so copy it to a writable location
# and regenerate that one endpoint from whatever options file is bind-mounted
# at /data/options.json for this run (default vs. an enabled-variant file).
# This makes any options variant testable via the bind mount alone.
cp -r /test/supervisor-mock /tmp/supervisor-mock
jq -n --slurpfile o /data/options.json '{result:"ok",data:$o[0]}' > /tmp/supervisor-mock/addons/self/options/config

# Serve the (now writable) mock tree as the Supervisor API.
# NOTE: the base image's `busybox` binary does not include the httpd applet;
# it ships in the separate busybox-extras package (added to the Dockerfile's
# apk list in this task), exposed via the /usr/sbin/httpd symlink.
/usr/sbin/httpd -p 127.0.0.1:80 -h /tmp/supervisor-mock
exec /init
