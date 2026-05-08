#!/bin/bash

APP_NAME=kr260_hw

echo "Removing existing app"
sudo rm -rf /lib/firmware/xilinx/${APP_NAME}

echo "Moving new version"
sudo mv ${APP_NAME} /lib/firmware/xilinx/
