#!/bin/sh
# THROWAWAY PROTOTYPE: exposes the composed-command exit limitation.
sleep 30 &
wait "$!"
