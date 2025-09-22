#!/usr/bin/env sh
#

echo "====================================================="
echo "/opt/staging:"
ls -la /opt/staging
echo "====================================================="
echo
echo "/opt/out/instance/bin:"
ls -la /opt/out/instance/bin
echo "====================================================="
echo
echo "====================================================="
echo "50-before-post-start.sh : "
echo
cat /opt/staging/hooks/50-before-post-start.sh                   │

echo "====================================================="
