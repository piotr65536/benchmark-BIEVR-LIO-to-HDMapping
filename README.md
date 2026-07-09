# benchmark-BIEVR-LIO-to-HDMapping

Runs the [BIEVR-LIO](https://github.com/ethz-asl/BIEVR-LIO) LiDAR-Inertial
odometry algorithm (ROS 2 interface) on a rosbag and converts the output to an
[HDMapping](https://github.com/MapsHD/HDMapping) session.

BIEVR-LIO is *Robust LiDAR-Inertial Odometry through Bump-Image-Enhanced Voxel
Maps* by Pfreundschuh et al., ETH Zurich ASL, RSS 2026
([paper](https://arxiv.org/abs/2604.14421)). The upstream repo ships both a
ROS 1 and a ROS 2 interface on top of a ROS-independent core; this benchmark
uses the **ROS 2** interface (`bievr_lio_ros2`) on ROS 2 Humble.

## Prerequisites

- Docker
- A bag containing a `sensor_msgs/msg/PointCloud2` topic and a
  `sensor_msgs/msg/Imu` topic matching the topic names declared in the chosen
  BIEVR-LIO sensor config. Both input forms are accepted:
  - a **ROS 2 bag directory** — played directly
  - a **ROS 1 `.bag` file** — converted to ROS 2 format automatically

## Step 1 — Clone with submodules

```bash
git clone https://github.com/MapsHD/benchmark-BIEVR-LIO-to-HDMapping.git --recursive
cd benchmark-BIEVR-LIO-to-HDMapping
```

## Step 2 — Build the Docker image

```bash
docker build -t bievr-lio_humble .
```

This installs:
- Ubuntu 22.04 + ROS 2 Humble
- Eigen3, PCL, Boost, glog/gflags
- Ceres 2.2.0 (built from source — the version BIEVR-LIO is developed against)
- BIEVR-LIO core + `bievr_lio_ros2` interface (compiled from submodule)
- colcon workspace with `bievr_lio_ros2` and `bievr-lio-to-hdmapping`

The build takes several minutes on first run (Ceres is built from source).

## Step 3 — Run the pipeline

```bash
chmod +x docker_session_run-ros2-bievr-lio.sh
./docker_session_run-ros2-bievr-lio.sh /path/to/bag /path/to/output/dir
```

Or with no arguments to use a GUI file selector (requires `zenity`):

```bash
./docker_session_run-ros2-bievr-lio.sh
```

By default the script uses the `enwide` sensor config. Pick a different one
with the `SENSOR_CONFIG` environment variable, e.g.:

```bash
SENSOR_CONFIG=ncd ./docker_session_run-ros2-bievr-lio.sh /path/to/bag /path/to/output/dir
```

Available sensor configs (from the upstream `config/sensor_configs/` directory):

| `SENSOR_CONFIG` | Dataset | Config LiDAR topic | Config IMU topic |
|-----------------|---------|--------------------|------------------|
| `enwide`    | [ENWIDE](https://projects.asl.ethz.ch/datasets/enwide/) | `/ouster/points` | `/ouster/imu` |
| `ncd`       | [Newer College](https://ori-drs.github.io/newer-college-dataset/) | `/os_cloud_node/points` | `/os_cloud_node/imu` |
| `gamma`     | [GEODE](https://thisparticle.github.io/geode) | `/livox/lidar` | `/livox/imu` |
| `mars`      | [MARS-LVIG](https://mars.hku.hk/dataset.html) | `/livox/lidar` | `/livox/imu` |
| `grandtour` | [GrandTour](https://grand-tour.leggedrobotics.com/) | `/boxi/hesai/points` | `/boxi/cpt7/imu` |

The sensor config also carries the LiDAR→IMU extrinsic and the usable LiDAR
range; to run on your own sensor, add a config as described in the upstream
README (`config/sensor_configs/<name>.yaml`).

Note: the Livox configs (`gamma`, `mars`) refer to datasets whose LiDAR topic
is a `sensor_msgs/msg/PointCloud2` export. Native Livox `CustomMsg` bags would
require `livox_ros_driver2` in the workspace, which this benchmark does not
build.

**What happens:**

The script opens a Docker container with a tmux session containing four panes
on window 0 and a `control` window (window 1, the attach target):

| Pane | Role |
|------|------|
| 0 | `ros2 launch bievr_lio_ros2 process_topics.launch.py` — subscribes to the LiDAR + IMU topics, publishes `/bievr_lio/odom` + `/bievr_lio/points/registered` (+ RViz live view) |
| 1 | `ros2 bag record` — captures the two output topics |
| 2 | `ros2 bag play --clock` — plays your input bag |
| 3 | diagnostics — shows active topics and publishing rates |

Press `Ctrl+b` then `0` to switch to window 0 and watch RViz (on by default;
disable with `USE_RVIZ=0`). When playback finishes, the control window stops
the recorder, kills the node and RViz, and exits tmux. A second Docker run then
converts the recorded bag into the HDMapping session format.

## Step 4 — Open in HDMapping

Output files appear in `<output_dir>/output_hdmapping-BIEVR-LIO/`:

```
lio_initial_poses.reg
poses.reg
scan_lio_0.laz
scan_lio_1.laz
...
session.json
trajectory_lio_0.csv
trajectory_lio_1.csv
...
```

Open `session.json` with the
[multi_view_tls_registration_step_2](https://github.com/MapsHD/HDMapping)
application.

## Notes on BIEVR-LIO

BIEVR-LIO publishes (all topics namespaced under `bievr_lio`):

| Topic | Type | Meaning |
|-------|------|---------|
| `/bievr_lio/odom` | `nav_msgs/msg/Odometry` | the current 6-DoF body pose in the world (`map`) frame (also mirrored on TF) |
| `/bievr_lio/points/registered` | `sensor_msgs/msg/PointCloud2` | the current scan, already registered into the world frame (with intensity) |

Because `/bievr_lio/points/registered` is already in the world frame, the
converter does **not** re-apply the pose to the points — it only uses
`/bievr_lio/odom` to build the per-chunk trajectory files. The recorded topics
are tunable via env vars:

| Variable | Meaning | Default |
|----------|---------|---------|
| `ODOM_TOPIC`  | BIEVR-LIO odometry output           | `/bievr_lio/odom` |
| `CLOUD_TOPIC` | BIEVR-LIO registered cloud (world)  | `/bievr_lio/points/registered` |

The input topic names are configured **inside the sensor config YAML** (not as
command-line parameters):

```yaml
topics:
  pointcloud: "/your/lidar/topic"
  imu: "/your/imu/topic"
calibration:   # T_IMU_LIDAR (LiDAR -> IMU)
  translation: [x, y, z]
  rotation: [r00, r01, ... r22]
lidar:
  min_range_m: 0.5
  max_range_m: 100
```

This benchmark captures BIEVR-LIO's **online** odometry output via
`process_topics` (playing the bag in real time), consistent with the other LIO
benchmarks in this repo. Upstream also offers `process_bag` (offline,
faster-than-realtime); it is not used here so that all benchmarked algorithms
process data under the same real-time playback conditions.

## Contact

januszbedkowski@gmail.com
