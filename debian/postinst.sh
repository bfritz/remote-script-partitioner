#!/bin/sh

TAG="remote-partitioner"
SERVER=$(sed -n 's/.*tftp_server=\([^ ]\+\).*/\1/p' /proc/cmdline)
SCRIPT=partitioner

# make $TAG available to partitioning script
export TAG="$TAG"

sed -i -e 's/partman/#partman/' /var/lib/dpkg/info/partman-base.postinst
logger -t "$TAG" "Disabled partman."

logger -t "$TAG" "Starting disk partition."
logger -t "$TAG" "Downloading $SCRIPT from $SERVER."
tftp -g $SERVER -r "$SCRIPT" -l "/tmp/$SCRIPT" \
    && chmod 755 "/tmp/$SCRIPT" \
    && "/tmp/$SCRIPT"

if [ $? -eq 0 ]; then
  logger -t "$TAG" "Finished disk partitioning."
else
  logger -t "$TAG" "Disk partitioning failed."
fi
