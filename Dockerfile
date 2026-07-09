FROM ubuntu:22.04

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ── Base tools ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    build-essential \
    cmake \
    git \
    apt-transport-https \
    ca-certificates \
    wget \
    libeigen3-dev \
    libboost-all-dev \
    libomp-dev \
    libpcl-dev \
    libopencv-dev \
    libyaml-cpp-dev \
    libgoogle-glog-dev \
    libgflags-dev \
    nlohmann-json3-dev \
    tmux \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# ── ROS 2 Humble ─────────────────────────────────────────────────────────────
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/ros2.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-humble-desktop \
    ros-humble-tf2-ros \
    ros-humble-tf2-eigen \
    ros-humble-pcl-conversions \
    ros-humble-pcl-ros \
    ros-humble-cv-bridge \
    ros-humble-image-transport \
    ros-humble-message-filters \
    ros-humble-geometry-msgs \
    ros-humble-nav-msgs \
    ros-humble-sensor-msgs \
    ros-humble-std-srvs \
    ros-humble-visualization-msgs \
    ros-humble-rosbag2-cpp \
    ros-humble-rosbag2-storage \
    ros-humble-rosbag2-storage-default-plugins \
    ros-humble-rclcpp-components \
    ros-humble-yaml-cpp-vendor \
    python3-colcon-common-extensions \
    python3-rosdep \
    && rm -rf /var/lib/apt/lists/*

# ── rosbags (Python tool to convert ROS 1 bags to ROS 2 format) ──────────────
RUN pip3 install --no-cache-dir "rosbags==0.9.22"

# ── Ceres 2.2.0 (the version BIEVR-LIO's core estimator is built against) ────
WORKDIR /tmp
RUN git clone --depth 1 --branch 2.2.0 https://github.com/ceres-solver/ceres-solver.git && \
    cd ceres-solver && \
    mkdir build && cd build && \
    cmake .. \
      -DCMAKE_BUILD_TYPE=Release \
      -DBUILD_TESTING=OFF \
      -DBUILD_EXAMPLES=OFF && \
    make -j$(nproc) && make install && \
    ldconfig && \
    cd / && rm -rf /tmp/ceres-solver

# ── Build colcon workspace (BIEVR-LIO core + ROS 2 interface + converter) ────
WORKDIR /ros2_ws

COPY ./src/BIEVR-LIO               ./src/BIEVR-LIO
COPY ./src/bievr-lio-to-hdmapping  ./src/bievr-lio-to-hdmapping

# --packages-up-to pulls in bievr_lio (core) and bievr_ros_common as
# dependencies of bievr_lio_ros2. Livox CustomMsg support is optional upstream
# (compiled only when livox_ros_driver2 is in the workspace) and is not built
# here: the benchmark inputs are standard sensor_msgs/PointCloud2 topics.
RUN source /opt/ros/humble/setup.bash && \
    colcon build \
      --packages-up-to bievr_lio_ros2 bievr-lio-to-hdmapping \
      --cmake-args -DCMAKE_BUILD_TYPE=Release && \
    test -f /ros2_ws/install/bievr_lio_ros2/lib/bievr_lio_ros2/process_topics && \
    test -f /ros2_ws/install/bievr-lio-to-hdmapping/lib/bievr-lio-to-hdmapping/listener && \
    echo "[build] bievr_lio_ros2 node and converter present"

# ── Non-root user ─────────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID ros && \
    useradd -m -u $UID -g $GID -s /bin/bash ros && \
    chown -R $UID:$GID /ros2_ws

RUN echo "source /opt/ros/humble/setup.bash"    >> /root/.bashrc && \
    echo "source /ros2_ws/install/setup.bash"   >> /root/.bashrc && \
    echo "source /opt/ros/humble/setup.bash"    >> /home/ros/.bashrc && \
    echo "source /ros2_ws/install/setup.bash"   >> /home/ros/.bashrc

CMD ["bash"]
