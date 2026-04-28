export MESA_LOADER_DRIVER_OVERRIDE=pvr
export XDG_RUNTIME_DIR=/root
export QT_QPA_PLATFORM_PLUGIN_PATH=/usr/lib/qt/plugins/platforms
export QT_QPA_PLATFORM=wayland

XDG_RUNTIME_DIR=/root weston --drm-device=card1 --idle-time=0 --log=/var/log/weston.1 &
WESTON_PID1=$!

XDG_RUNTIME_DIR=/root weston --drm-device=card2 --idle-time=0 --log=/var/log/weston.2 &
WESTON_PID2=$!

wait $WESTON_PID1 $WESTON_PID2
