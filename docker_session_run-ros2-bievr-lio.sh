#!/bin/bash
# Run BIEVR-LIO (ROS 2) on a rosbag (ROS 2 bag directory or ROS 1 .bag file),
# record output topics, then convert the recorded bag to an HDMapping session.
#
# BIEVR-LIO publishes the world-frame registered scan on
# /bievr_lio/points/registered and the body pose on /bievr_lio/odom. We record
# both; the converter chunks the world points and rebuilds the trajectory from
# the odometry.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_NAME='bievr-lio_humble'
TMUX_SESSION='ros2_BIEVR-LIO'

DATASET_CONTAINER_PATH='/ros2_ws/dataset/input.bag'
DATASET_ROS2_PATH='/tmp/dataset_ros2'
BAG_OUTPUT_CONTAINER='/ros2_ws/recordings'
WRAPPER_CONFIG_CONTAINER='/ros2_ws/wrapper_config'
WRAPPER_CONFIG_HOST="${SCRIPT_DIR}/config"

RECORDED_BAG_NAME="recorded-BIEVR-LIO"
HDMAPPING_OUT_NAME="output_hdmapping"

# BIEVR-LIO output topics (see BIEVR/src/pipeline.cpp; namespaced "bievr_lio").
ODOM_TOPIC=${ODOM_TOPIC:-/bievr_lio/odom}
CLOUD_TOPIC=${CLOUD_TOPIC:-/bievr_lio/points/registered}

# Sensor config: selects the LiDAR/IMU topics BIEVR-LIO subscribes to, the
# LiDAR->IMU extrinsic and the usable LiDAR range.
# This branch (Bunker-DVI-Dataset-reg-1) defaults to the repo-local
# config/bunker.yaml (Livox Mid-360 as PointCloud2 on /livox/pointcloud).
# Wrapper configs in this repo's config/ directory take precedence; any other
# name falls back to the upstream package configs (enwide, ncd, gamma, mars,
# grandtour).
SENSOR_CONFIG=${SENSOR_CONFIG:-bunker}

# Resolve the config: a file in this repo's config/ dir is mounted into the
# container and passed as an absolute path (the BIEVR-LIO launch uses absolute
# paths verbatim); otherwise the bare name resolves to an upstream config.
if [[ -f "${WRAPPER_CONFIG_HOST}/${SENSOR_CONFIG}.yaml" ]]; then
  USE_WRAPPER_CONFIG=1
  SENSOR_CONFIG_ARG="${WRAPPER_CONFIG_CONTAINER}/${SENSOR_CONFIG}.yaml"
else
  USE_WRAPPER_CONFIG=0
  SENSOR_CONFIG_ARG="${SENSOR_CONFIG}"
fi

# RViz on by default — the live view of how the algorithm tracks the dataset.
USE_RVIZ="${USE_RVIZ:-1}"

# Force Mesa software rendering by default so RViz renders even when the host
# GPU driver is not exposed to the container (the libGL "nvidia-drm" case).
LIBGL_SW="${LIBGL_SW:-1}"
if [[ "$LIBGL_SW" == "1" ]]; then LIBGL_ENV="1"; else LIBGL_ENV=""; fi

usage() {
  echo "Usage:"
  echo "  $0 <input.bag | ros2_bag_dir> <output_dir>"
  echo
  echo "  input.bag    : ROS 1 bag file — converted to ROS 2 format on the fly"
  echo "  ros2_bag_dir : ROS 2 bag directory — played directly, no conversion"
  echo "                 (this is what the HDMapping orchestration passes)"
  echo
  echo "If no arguments are provided, a GUI file selector will be used."
  echo
  echo "Environment variables:"
  echo "  SENSOR_CONFIG - BIEVR-LIO sensor config name (default: bunker, from this repo's config/)"
  echo "                  upstream-shipped: enwide, ncd, gamma, mars, grandtour"
  echo "  ODOM_TOPIC    - recorded odometry topic (default: /bievr_lio/odom)"
  echo "  CLOUD_TOPIC   - recorded cloud topic    (default: /bievr_lio/points/registered)"
  echo "  USE_RVIZ      - 1/0, launch RViz live view (default: 1)"
  exit 1
}

echo "=== BIEVR-LIO rosbag pipeline ==="

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ $# -eq 2 ]]; then
  DATASET_HOST_PATH="$1"
  BAG_OUTPUT_HOST="$2"
elif [[ $# -eq 0 ]]; then
  command -v zenity >/dev/null || {
    echo "Error: zenity is not available"
    exit 1
  }
  DATASET_HOST_PATH=$(zenity --file-selection --title="Select BAG file (or ROS 2 bag directory)")
  BAG_OUTPUT_HOST=$(zenity --file-selection --directory --title="Select output directory")
else
  usage
fi

if [[ -z "$DATASET_HOST_PATH" || -z "$BAG_OUTPUT_HOST" ]]; then
  echo "Error: no file or directory selected"
  exit 1
fi

if [[ ! -f "$DATASET_HOST_PATH" && ! -d "$DATASET_HOST_PATH" ]]; then
  echo "Error: BAG path does not exist: $DATASET_HOST_PATH"
  exit 1
fi

mkdir -p "$BAG_OUTPUT_HOST"

DATASET_HOST_PATH=$(realpath "$DATASET_HOST_PATH")
BAG_OUTPUT_HOST=$(realpath "$BAG_OUTPUT_HOST")

# Orchestration convention: a directory input is an already-converted ROS 2 bag
# (played directly); a file input is a ROS 1 .bag (converted on the fly).
if [[ -d "$DATASET_HOST_PATH" ]]; then
  INPUT_IS_DIR=1
else
  INPUT_IS_DIR=0
fi

# RViz on/off resolved to a launch-file boolean
RVIZ_ARG=false; [[ "$USE_RVIZ" == "1" ]] && RVIZ_ARG=true

echo "Input bag     : $DATASET_HOST_PATH"
echo "Input type    : $([[ $INPUT_IS_DIR == 1 ]] && echo 'ROS 2 bag directory (no conversion)' || echo 'ROS 1 bag file (convert to ROS 2)')"
echo "Output dir    : $BAG_OUTPUT_HOST"
echo "Sensor config : $SENSOR_CONFIG $([[ $USE_WRAPPER_CONFIG == 1 ]] && echo "(repo config/ -> ${SENSOR_CONFIG_ARG})" || echo '(upstream package config)')"
echo "Odom topic    : $ODOM_TOPIC"
echo "Cloud topic   : $CLOUD_TOPIC"
echo "RViz          : $RVIZ_ARG"

xhost +local:docker >/dev/null

WRAPPER_CONFIG_MOUNT=()
if [[ "$USE_WRAPPER_CONFIG" == "1" ]]; then
  WRAPPER_CONFIG_MOUNT=(-v "${WRAPPER_CONFIG_HOST}":"${WRAPPER_CONFIG_CONTAINER}":ro)
fi

# ── Phase 1: run BIEVR-LIO + record output topics ─────────────────────────────
docker run -it --rm \
  --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_HOME=/tmp/.ros \
  -e INPUT_IS_DIR="$INPUT_IS_DIR" \
  -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ENV" \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$DATASET_HOST_PATH":"$DATASET_CONTAINER_PATH":ro \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "${WRAPPER_CONFIG_MOUNT[@]}" \
  "$IMAGE_NAME" \
  /bin/bash -c '

    source /opt/ros/humble/setup.bash
    source /ros2_ws/install/setup.bash

    # ── Convert ROS 1 bag to ROS 2 format if needed ──
    # INPUT_IS_DIR is decided on the host by the real input type: a directory
    # is an already-converted ROS 2 bag (orchestration passes these), a file
    # is a ROS 1 .bag that still needs conversion.
    if [[ "$INPUT_IS_DIR" == "1" ]]; then
      echo "[convert] Input is already a ROS 2 bag directory — skipping conversion."
      ROS2_BAG="'"$DATASET_CONTAINER_PATH"'"
    else
      echo "[convert] Converting ROS 1 bag to ROS 2 format..."
      ls -la "'"$DATASET_CONTAINER_PATH"'" || { echo "[convert] ERROR: input bag not found!"; exit 1; }
      rm -rf "'"$DATASET_ROS2_PATH"'"
      rosbags-convert "'"$DATASET_CONTAINER_PATH"'" --dst "'"$DATASET_ROS2_PATH"'"
      if [[ ! -d "'"$DATASET_ROS2_PATH"'" ]]; then
        echo "[convert] ERROR: rosbags-convert failed! Output not created."
        exit 1
      fi
      ROS2_BAG="'"$DATASET_ROS2_PATH"'"
    fi

    export ROS2_BAG
    echo "[convert] ROS 2 bag ready at: $ROS2_BAG"
    ls -la $ROS2_BAG/

    tmux new-session -d -s '"$TMUX_SESSION"'

    # ---------- PANE 0: BIEVR-LIO process_topics launch (+ RViz) ----------
    tmux send-keys -t '"$TMUX_SESSION"' '\''
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
sleep 2
ros2 launch bievr_lio_ros2 process_topics.launch.py \
  sensor_config:='"$SENSOR_CONFIG_ARG"' \
  rviz:='"$RVIZ_ARG"'
'\'' C-m

    # ---------- PANE 1: ros2 bag record ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 2
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
rm -rf '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] start"
ros2 bag record '"$ODOM_TOPIC"' '"$CLOUD_TOPIC"' -o '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] exit"
'\'' C-m

    # ---------- PANE 2: ros2 bag play ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 8
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
echo "[play] start"
ros2 bag play $ROS2_BAG --clock; tmux wait-for -S BAG_DONE;
echo "[play] done"
'\'' C-m

    # ---------- PANE 3: diagnostics ----------
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 12
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
echo "=== ROS 2 DIAGNOSTICS ==="
echo ""
echo "--- Active topics ---"
ros2 topic list
echo ""
echo "--- Checking BIEVR-LIO output: '"$ODOM_TOPIC"' ---"
timeout 5 ros2 topic hz '"$ODOM_TOPIC"' 2>&1 &
echo ""
echo "--- Checking BIEVR-LIO output: '"$CLOUD_TOPIC"' ---"
timeout 5 ros2 topic hz '"$CLOUD_TOPIC"' 2>&1 &
wait
echo ""
echo "=== If output topics show nothing, verify the lidar/imu topic names ==="
echo "=== in the chosen sensor config match the topics inside the bag.    ==="
echo ""
echo "--- Node list ---"
ros2 node list
echo ""
echo "[diag] done — you can type ROS 2 commands here, e.g.:"
echo "  ros2 topic list"
echo "  ros2 topic echo '"$ODOM_TOPIC"'"
'\'' C-m

    # ---------- Control window (window 1) ----------
    # This is the window the user attaches to; the noisy panes are on window 0
    # (press Ctrl+b then 0 to watch RViz / node output). It waits for the play
    # pane to signal end of playback, then tears the whole session down.
    tmux new-window -t '"$TMUX_SESSION"' -n control '\''
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
echo "[control] waiting for bag playback to finish..."
tmux wait-for BAG_DONE
echo "[control] bag playback finished — shutting down"

# Give BIEVR-LIO a moment to process remaining queued scans
sleep 3

# Graceful stop: Ctrl+C to each pane
# Pane layout: 0=bievr_lio(+rviz), 1=recorder, 2=play, 3=diag
echo "[control] sending Ctrl+C to all panes..."
tmux send-keys -t '"$TMUX_SESSION"':0.1 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.0 C-c
sleep 3

# Force-kill by process name
echo "[control] force-killing remaining processes..."
pkill -9 process_topics 2>/dev/null || true
pkill -9 rviz2 2>/dev/null || true
sleep 1

echo "[control] terminating tmux"
tmux kill-server
'\''

    tmux attach -t '"$TMUX_SESSION"'
  '

# ── Phase 2: convert recorded bag to HDMapping session ────────────────────────
echo "=== Converting recorded bag to HDMapping session ==="

docker run -it --rm \
  --network host \
  -e DISPLAY="$DISPLAY" \
  -e ROS_HOME=/tmp/.ros \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c "
    set -e
    source /opt/ros/humble/setup.bash
    source /ros2_ws/install/setup.bash
    ros2 run bievr-lio-to-hdmapping listener \
      \"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME\" \
      \"$BAG_OUTPUT_CONTAINER/$HDMAPPING_OUT_NAME-BIEVR-LIO\" \
      \"$ODOM_TOPIC\" \
      \"$CLOUD_TOPIC\"
  "

echo "=== DONE ==="
