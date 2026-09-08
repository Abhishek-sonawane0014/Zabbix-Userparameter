#!/bin/bash

echo "=== OS Information ==="

if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "Name: $NAME"
    echo "Version: $VERSION"
    echo "ID: $ID"
elif type lsb_release >/dev/null 2>&1; then
    lsb_release -a
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    echo "Name: $DISTRIB_ID"
    echo "Version: $DISTRIB_RELEASE"
else
    echo "Falling back to uname:"
    uname -a
fi
