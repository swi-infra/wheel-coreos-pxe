#!/bin/bash
docker build -t "corfr/coreos-pxe-hub" hub
docker build -t "corfr/coreos-pxe-spoke" spoke
