#!/bin/bash
# Run this script from your host machine (laptop/desktop) that functions
# as a ground station for the Jetson/Drone.
ffplay \
    -fflags nobuffer \
    -flags low_delay \
    -analyzeduration 0 \
    -probesize 32 \
    -rtsp_transport tcp rtsp://${JETSON_IP}:8554/infer

#You can aslo use VLC with this command
# vlc --network-caching=50 rtsp://<NANO_IP>:8554/infer

#Easiest! Use the web interface on port 8889. Open a browser and navigate to http://<JETSON_IP>:8889/infer to view the stream and access WHEP controls.
#Jetson and ground station must be on the same network for this to work.