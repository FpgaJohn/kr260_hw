#!/bin/bash

echo "Unloading any existing app..."
sudo xmutil unloadapp

echo "Loading app kr260_hw"
sudo xmutil loadapp kr260_hw
