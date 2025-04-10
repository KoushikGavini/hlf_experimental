#!/bin/bash

# Exit script on error
set -e

# --- Variables ---
# Allow overriding install dir for samples, default to ~/fabric-samples
FABRIC_SAMPLES_DIR="${FABRIC_SAMPLES_DIR:-$HOME/fabric-samples}"
# Allow overriding setup dir, default to ~/peer-org-setup
PEER_ORG_SETUP_DIR="${PEER_ORG_SETUP_DIR:-$HOME/peer-org-setup}"

# Fabric and CA versions (adjust as needed)
FABRIC_VERSION="3.0.0"
CA_VERSION="1.5.10"     # Compatible CA version for 3.0.x

# Org and CA Configuration
ORG_NAME="Org1"
ORG_DOMAIN="org1.example.com"
MSP_ID="${ORG_NAME}MSP"
NUM_PEERS=3
CA_NAME="ca-${ORG_NAME,,}" # ca-org1
CA_PORT=7054
CA_ADMIN_USER="admin"
CA_ADMIN_PASS="adminpw"
CA_IMAGE_TAG="1.5" # Use tag compatible with CA_VERSION
PEER_IMAGE_TAG="3.0" # Use tag compatible with FABRIC_VERSION

# --- Helper Functions ---
command_exists() {
  command -v "$@" > /dev/null 2>&1
}

install_package() {
  local package_name=$1
  local install_command=$2
  echo "Attempting to install ${package_name}..."
  if eval "${install_command}"; then
    echo "${package_name} installed successfully."
  else
    echo "Failed to install ${package_name}. Please install it manually and re-run the script."
    exit 1
  fi
}

detect_os_and_package_manager() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  PM=""
  SUDO=""

  if command_exists sudo; then
    SUDO="sudo"
  fi

  case "$OS" in
    Linux)
      if command_exists apt-get; then
        PM="apt"
      elif command_exists yum; then
        PM="yum"
      else
        echo "Unsupported Linux distribution. Please install prerequisites manually."
        exit 1
      fi
      ;;
    Darwin) # macOS
      if command_exists brew; then
        PM="brew"
        SUDO="" # Homebrew generally advises against sudo
      else
        echo "Homebrew not found. Please install Homebrew (https://brew.sh/) or install prerequisites manually."
        exit 1
      fi
      ;;
    *)
      echo "Unsupported operating system: $OS. Please install prerequisites manually."
      exit 1
      ;;
  esac
  echo "Detected OS: $OS, Arch: $ARCH, Package Manager: $PM"
}

# --- Prerequisite Installation ---
echo "#############################################"
echo "### Checking Prerequisites...             ###"
echo "#############################################"
detect_os_and_package_manager

# 1. Git
if ! command_exists git; then
  echo "Git not found."
  case "$PM" in
    apt) install_package "git" "$SUDO apt-get update && $SUDO apt-get install -y git" ;;
    yum) install_package "git" "$SUDO yum install -y git" ;;
    brew) install_package "git" "brew install git" ;;
  esac
else
  echo "Git found: $(git --version)"
fi

# 2. Docker
if ! command_exists docker; then
  echo "Docker not found. Attempting installation using convenience script..."
  echo "Note: This requires curl and sudo privileges."
  if ! command_exists curl; then
      install_package "curl" "${SUDO} ${PM} update -y && ${SUDO} ${PM} install -y curl"
  fi
  # Download and run the Docker installation script
  if curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh; then
      echo "Docker installed successfully via convenience script."
      rm get-docker.sh # Clean up downloaded script
      # Attempt to add user to docker group
      echo "Adding current user ($USER) to the docker group..."
      ${SUDO} usermod -aG docker $USER
      echo "############################################################################"
      echo "### IMPORTANT: Docker installed & user added to 'docker' group.        ###"
      echo "### You MUST log out and log back in OR run 'newgrp docker' in your  ###"
      echo "### terminal for group changes to take effect before running docker  ###"
      echo "### commands without sudo.                                           ###"
      echo "############################################################################"
      # Check if docker daemon is running (might need a moment or manual start)
      echo "Checking Docker service status..."
      if ! systemctl is-active --quiet docker; then
         echo "Attempting to start Docker service..."
         ${SUDO} systemctl start docker
         ${SUDO} systemctl enable docker # Enable on boot
         sleep 5 # Give service time to start
      fi
  else
      echo "Failed to install Docker using the convenience script."
      echo "Please install Docker manually: https://docs.docker.com/engine/install/"
      rm -f get-docker.sh # Clean up if download failed mid-way
      exit 1
  fi
fi

# Re-check Docker command and daemon status after installation attempt
echo "Verifying Docker installation..."
if ! command_exists docker; then
   echo "ERROR: Docker command still not found after installation attempt."
   exit 1
fi
echo "Docker command found: $(docker --version)"

# Check daemon requires running docker command, which might fail if group membership not active
# Use systemctl or equivalent to check service status instead of docker info initially
if ! systemctl is-active --quiet docker; then
    echo "WARNING: Docker service does not appear to be active."
    echo "Please ensure the Docker service is running (e.g., 'sudo systemctl start docker')."
    # Don't exit here, maybe user runs script then logs out/in and runs again
    # Let the later docker compose commands fail if daemon is truly not running
else
    echo "Docker service appears to be active."
    # Now try docker info with potential sudo if needed (might prompt for pass)
    echo "Attempting to connect to Docker daemon... (May require newgrp docker or relogin if just installed)"
    if ! docker info > /dev/null 2>&1; then
        echo "WARNING: Could not connect to Docker daemon using current user."
        echo "This might be due to group membership not being active yet."
        echo "Try running 'newgrp docker' or logging out/in after the script finishes."
        # Attempt with sudo as fallback verification
        if ${SUDO} docker info > /dev/null 2>&1; then
            echo "Confirmed Docker daemon is running via sudo."
        else
            echo "ERROR: Failed to connect to Docker daemon even with sudo."
            echo "Please diagnose Docker installation and daemon status manually."
            exit 1
        fi
    else
        echo "Successfully connected to Docker daemon."
    fi
fi

# 3. Docker Compose (V2)
if ! docker compose version > /dev/null 2>&1; then
    echo "Docker Compose V2 (docker compose) not found. It's usually included with Docker Desktop."
    echo "If you installed Docker Engine separately, follow instructions here:"
    echo "https://docs.docker.com/compose/install/"
    if command_exists docker-compose; then
        echo "Legacy docker-compose (V1) found: $(docker-compose --version)"
        echo "However, this script requires Docker Compose V2."
    fi
    exit 1
else
    echo "Docker Compose V2 found: $(docker compose version)"
fi

# 4. Go
GO_VERSION_MIN="1.18"
if command_exists go; then
  INSTALLED_GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//' | cut -d. -f1,2)
  echo "Go found: version ${INSTALLED_GO_VERSION}"
  # POSIX compliant version comparison: check if MIN_VERSION is the smallest when sorted
  if [ "$(printf '%s\n' "$GO_VERSION_MIN" "$INSTALLED_GO_VERSION" | sort -V | head -n 1)" != "$GO_VERSION_MIN" ]; then
       echo "Go version ${INSTALLED_GO_VERSION} is older than required ${GO_VERSION_MIN}. Attempting upgrade/install..."
       GO_INSTALL_NEEDED=true
  else
       echo "Go version is sufficient."
       GO_INSTALL_NEEDED=false
  fi
else
  echo "Go not found. Attempting installation..."
  GO_INSTALL_NEEDED=true
fi

if [ "$GO_INSTALL_NEEDED" = true ]; then
  echo "Note: Installing Go via package manager. For specific versions or environments, consider manual install or a version manager like 'gvm'."
  case "$PM" in
      apt) install_package "Go" "${SUDO} apt-get update && ${SUDO} apt-get install -y golang-go" ;; # Installs golang-go package
      yum) install_package "Go" "${SUDO} yum install -y golang" ;; # Installs golang package
      brew) install_package "Go" "brew install go" ;; # Should already be handled, but for completeness
      *) echo "Cannot automatically install Go for package manager ${PM}. Please install manually."; exit 1 ;;
  esac
  # Re-check Go version after installation
  if command_exists go; then
      INSTALLED_GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//' | cut -d. -f1,2)
      echo "Go installed: version ${INSTALLED_GO_VERSION}"
      if [ "$(printf '%s\n' "$GO_VERSION_MIN" "$INSTALLED_GO_VERSION" | sort -V | head -n 1)" != "$GO_VERSION_MIN" ]; then
          echo "WARNING: Installed Go version ${INSTALLED_GO_VERSION} is still older than required ${GO_VERSION_MIN}."
          echo "Manual upgrade or using a version manager (gvm) is recommended: https://go.dev/doc/install"
          # Decide whether to exit or continue with warning
          # exit 1
      else
           echo "Installed Go version meets requirements."
      fi
  else
      echo "ERROR: Go installation failed or command still not found. Please install manually."
      exit 1
  fi
fi

export GOPATH=${GOPATH:-"$HOME/go"}
export GOBIN=${GOBIN:-"$GOPATH/bin"}
export PATH=$PATH:$GOBIN
echo "Ensure \$GOPATH/bin is in your \$PATH."

# 5. Node.js & npm (Still useful for chaincode development/testing later)
NODE_VERSION_MIN="16"
NPM_VERSION_MIN="8"
NODE_INSTALL_NEEDED=false # Flag to track if install/upgrade needed
if command_exists node && command_exists npm; then
  INSTALLED_NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
  INSTALLED_NPM_VERSION=$(npm -v | cut -d. -f1)
  echo "Node found: v$(node -v)"
  echo "npm found: v$(npm -v)"
  if [ "$INSTALLED_NODE_VERSION" -lt "$NODE_VERSION_MIN" ] || [ "$INSTALLED_NPM_VERSION" -lt "$NPM_VERSION_MIN" ]; then
    echo "Node.js (>= v${NODE_VERSION_MIN}) or npm (>= v${NPM_VERSION_MIN}) version requirement not met. Attempting install/upgrade..."
    NODE_INSTALL_NEEDED=true
  else
    echo "Node.js and npm versions are sufficient."
  fi
else
  echo "Node.js or npm not found. Attempting installation..."
  NODE_INSTALL_NEEDED=true
fi

if [ "$NODE_INSTALL_NEEDED" = true ]; then
    echo "Note: Installing Node.js/npm via package manager. For specific versions (especially LTS), consider manual install or a version manager like 'nvm' or 'fnm'."
    # Attempt installation using package manager
    case "$PM" in
      apt) install_package "Node.js & npm" "${SUDO} apt-get update && ${SUDO} apt-get install -y nodejs npm" ;; 
      yum) install_package "Node.js & npm" "${SUDO} yum install -y nodejs npm" ;; # Might need EPEL repo or NodeSource setup for newer versions on older systems
      brew) install_package "Node.js" "brew install node" ;; # Should already be handled
      *) echo "Cannot automatically install Node.js/npm for package manager ${PM}. Please install manually."; exit 1;;
    esac
    # Re-check Node/npm versions after installation
    if command_exists node && command_exists npm; then
        INSTALLED_NODE_VERSION=$(node -v | sed 's/v//' | cut -d. -f1)
        INSTALLED_NPM_VERSION=$(npm -v | cut -d. -f1)
        echo "Node installed: v$(node -v)"
        echo "npm installed: v$(npm -v)"
        if [ "$INSTALLED_NODE_VERSION" -lt "$NODE_VERSION_MIN" ] || [ "$INSTALLED_NPM_VERSION" -lt "$NPM_VERSION_MIN" ]; then
            echo "WARNING: Installed Node.js/npm versions may still not meet requirements (v${NODE_VERSION_MIN}+/v${NPM_VERSION_MIN}+)."
            echo "Using a Node Version Manager (like nvm: https://github.com/nvm-sh/nvm) is strongly recommended."
            # Decide whether to exit or continue with warning
            # exit 1 
        else
            echo "Installed Node.js and npm versions meet requirements."
        fi
    else
        echo "ERROR: Node.js/npm installation failed or commands still not found. Please install manually."
        exit 1
    fi
fi

# 6. Python (Needed for some build/utility scripts in Fabric)
PYTHON_CMD="python3"
if ! command_exists python3; then
    if command_exists python; then PYTHON_CMD="python"; else echo "Python 3 not found. Please install it."; exit 1; fi
fi
PYTHON_VERSION_OUTPUT=$($PYTHON_CMD --version 2>&1)
echo "Python found: ${PYTHON_VERSION_OUTPUT}"
if [[ "$PYTHON_VERSION_OUTPUT" != *"Python 3"* ]]; then
    echo "Python 3 is required. Found ${PYTHON_VERSION_OUTPUT}. Please install Python 3."
    exit 1
fi

echo "All prerequisites seem to be installed and meet minimum requirements."
echo "----------------------------------------"

# --- Download Fabric Samples and Binaries ---
echo "#############################################"
echo "### Downloading Fabric Samples/Binaries ###"
echo "#############################################"

if [ ! -d "$FABRIC_SAMPLES_DIR" ]; then
  echo "Cloning Hyperledger Fabric Samples v${FABRIC_VERSION} into '$FABRIC_SAMPLES_DIR'..."
  TARGET_TAG="v${FABRIC_VERSION}" # Try exact v3.0.0 tag
  TARGET_BRANCH="release-${FABRIC_VERSION%.*}" # e.g., release-3.0
  if git ls-remote --tags https://github.com/hyperledger/fabric-samples | grep -q "refs/tags/${TARGET_TAG}$"; then
      echo "Checking out tag '${TARGET_TAG}'..."
      git clone --depth 1 --branch ${TARGET_TAG} https://github.com/hyperledger/fabric-samples.git "$FABRIC_SAMPLES_DIR"
  elif git ls-remote --heads https://github.com/hyperledger/fabric-samples | grep -q "refs/heads/${TARGET_BRANCH}$"; then
      echo "Tag ${TARGET_TAG} not found, cloning branch ${TARGET_BRANCH}..."
      git clone --depth 1 --branch ${TARGET_BRANCH} https://github.com/hyperledger/fabric-samples.git "$FABRIC_SAMPLES_DIR"
  else
      echo "Warning: Neither tag ${TARGET_TAG} nor branch ${TARGET_BRANCH} found. Cloning main branch."
      echo "This might lead to version mismatches or missing scripts."
      git clone https://github.com/hyperledger/fabric-samples.git "$FABRIC_SAMPLES_DIR"
  fi
else
  echo "Directory '$FABRIC_SAMPLES_DIR' already exists. Skipping clone."
  echo "Ensure it contains the correct version (v${FABRIC_VERSION}) or remove it and re-run."
fi

cd "$FABRIC_SAMPLES_DIR"

# Check if binaries already exist (including fabric-ca-client)
FABRIC_CA_CLIENT_PATH="$FABRIC_SAMPLES_DIR/bin/fabric-ca-client"
if [ -d "bin" ] && [ -f "bin/peer" ] && [ -f "$FABRIC_CA_CLIENT_PATH" ]; then
    echo "Fabric binaries (peer, fabric-ca-client) already found in $FABRIC_SAMPLES_DIR/bin. Skipping download."
else
    echo "Downloading Fabric binaries (v${FABRIC_VERSION}), CA binaries (v${CA_VERSION}), and Docker images..."
    if [ -f "scripts/bootstrap.sh" ]; then
        ./scripts/bootstrap.sh ${FABRIC_VERSION} ${CA_VERSION} -d -s
    else
        echo "ERROR: scripts/bootstrap.sh not found in the cloned repository."
        echo "Please check the fabric-samples repository structure or try manual download:"
        echo "https://hyperledger-fabric.readthedocs.io/en/latest/install.html"
        exit 1
    fi
fi

# Check if fabric-ca-client is executable
if [ ! -x "$FABRIC_CA_CLIENT_PATH" ]; then
    echo "Error: fabric-ca-client tool not found or not executable at $FABRIC_CA_CLIENT_PATH"
    exit 1
fi
echo "Fabric binaries and images should be available."
echo "----------------------------------------"

# --- Setup Peer Organization Directory & CA ---
echo "#############################################"
echo "### Setting up CA & Org Directories     ###"
echo "#############################################"

# Create directories
mkdir -p "$PEER_ORG_SETUP_DIR/organizations/fabric-ca/${ORG_NAME,,}"
mkdir -p "$PEER_ORG_SETUP_DIR/organizations/peerOrganizations/${ORG_DOMAIN}"
cd "$PEER_ORG_SETUP_DIR"

# Define CA compose file path
DOCKER_COMPOSE_CA_FILE="docker-compose-ca.yaml"
ORG_CA_DIR="${PWD}/organizations/fabric-ca/${ORG_NAME,,}"
ORG_PEER_DIR="${PWD}/organizations/peerOrganizations/${ORG_DOMAIN}"

# Check if CA container is already running or crypto exists
if [ "$(docker ps -q -f name="^${CA_NAME}$")" ] || [ -d "${ORG_PEER_DIR}/peers" ]; then
  echo "Fabric CA container '${CA_NAME}' might already be running or crypto material exists."
  echo "Skipping CA setup and identity generation."
  echo "If you want to regenerate, run the following and then re-run this script:"
  echo "  cd $PEER_ORG_SETUP_DIR"
  echo "  docker compose -f $DOCKER_COMPOSE_CA_FILE down -v"
  echo "  rm -rf organizations"
else
  echo "Creating Fabric CA server configuration..."
  cat > "${ORG_CA_DIR}/fabric-ca-server-config.yaml" <<EOF
port: ${CA_PORT}
ca:
  name: ${CA_NAME}
  certfile: /etc/hyperledger/fabric-ca-server/ca.crt
  keyfile: /etc/hyperledger/fabric-ca-server/ca.key
crl:
  enabled: false
registry:
  maxenrollments: -1
  identities:
    - name: ${CA_ADMIN_USER}
      pass: ${CA_ADMIN_PASS}
      type: client
      affiliation: ""
      attrs:
        hf.Registrar.Roles: "*"
        hf.Registrar.DelegateRoles: "*"
        hf.Revoker: true
        hf.GenCRL: true
        hf.Registrar.Attributes: "*"
        hf.AffiliationMgr: true
        admin: true # Custom attribute indicating administrative rights (used by default bootstrap admin)
        abac.init: true # Custom attribute, potentially for ABAC initialization
tls:
  enabled: true
  certfile: /etc/hyperledger/fabric-ca-server/tls-cert.pem
  keyfile: /etc/hyperledger/fabric-ca-server/tls-key.pem
affiliations:
   # Example: Define affiliations like departments
   # ${ORG_NAME,,}:
   #    - department1
   #    - department2
   # Default affiliations if needed:
   org1: []
   org2: [] # Keep even if unused, CA server expects defined top-level orgs if any are defined
crypto:
  provider: "sw"
  hash_algo: "sha256"
csp:
  sw:
    hash: SHA2
    security: 256
    filekeystore:
      keystore: msp/keystore # Path relative to CA server home
csr:
  cn: ${CA_NAME}
  names:
    - C: US
      ST: "California"
      L: "San Francisco"
      O: ${ORG_NAME}.example.com
      OU: ca
  hosts:
    - localhost
    - ${CA_NAME} # Hostname for the CA container
EOF

  echo "Creating Docker Compose file for Fabric CA..."
  cat > $DOCKER_COMPOSE_CA_FILE <<EOF
version: '3.7'

networks:
  ${ORG_NAME,,}_ca_net:
    name: ${ORG_NAME,,}_fabric_network # Define the network name

services:
  ${CA_NAME}:
    image: hyperledger/fabric-ca:${CA_IMAGE_TAG}
    labels:
      service: hyperledger-fabric
    environment:
      - FABRIC_CA_HOME=/etc/hyperledger/fabric-ca-server
      - FABRIC_CA_SERVER_CA_NAME=${CA_NAME}
      - FABRIC_CA_SERVER_TLS_ENABLED=true
      - FABRIC_CA_SERVER_PORT=${CA_PORT}
      # Use the config file we just created
      - FABRIC_CA_SERVER_CONFIG_PATH=/etc/hyperledger/fabric-ca-server/fabric-ca-server-config.yaml
      # Bootstrap admin user credentials (match config file) - used for first time enrollment
      - FABRIC_CA_SERVER_BOOTSTRAP_USER=${CA_ADMIN_USER}
      - FABRIC_CA_SERVER_BOOTSTRAP_PASSWORD=${CA_ADMIN_PASS}
      # Database settings (using SQLite default)
      # - FABRIC_CA_SERVER_DB_TYPE=sqlite3
      # - FABRIC_CA_SERVER_DB_DATASOURCE=/etc/hyperledger/fabric-ca-server/fabric-ca-server.db
      # Operations settings
      - FABRIC_CA_SERVER_OPERATIONS_LISTENADDRESS=0.0.0.0:17054 # Separate port for operations
    ports:
      - "${CA_PORT}:${CA_PORT}"
      - "17054:17054" # Expose operations port
    command: sh -c 'fabric-ca-server start -b ${CA_ADMIN_USER}:${CA_ADMIN_PASS}' # Start with bootstrap user/pass
    volumes:
      # Mount the CA config file
      - ${ORG_CA_DIR}/fabric-ca-server-config.yaml:/etc/hyperledger/fabric-ca-server/fabric-ca-server-config.yaml
      # Persist the CA data (database, server certs, keys)
      - ${ORG_CA_DIR}/server-data:/etc/hyperledger/fabric-ca-server
    networks:
      - ${ORG_NAME,,}_ca_net
    container_name: ${CA_NAME}
EOF

  echo "Starting Fabric CA server (${CA_NAME}) using $DOCKER_COMPOSE_CA_FILE..."
  docker compose -f $DOCKER_COMPOSE_CA_FILE up -d

  # Wait for CA server to start by checking its health/logs or enrollment readiness
  echo "Waiting for CA server to start (may take a minute)..."
  sleep 5 # Initial wait
  MAX_RETRIES=10
  COUNT=0
  while [ $COUNT -lt $MAX_RETRIES ]; do
    # Check if CA port is listening locally (adjust if CA is remote)
    if nc -z localhost ${CA_PORT}; then
      echo "CA server port ${CA_PORT} is accessible."
      # Optionally check logs for a specific message indicating readiness
      if docker logs ${CA_NAME} 2>&1 | grep -q "Listening on https*://0.0.0.0:${CA_PORT}"; then
         echo "CA server log indicates it is listening."
         break
      fi
    fi
    echo "CA server not ready yet, waiting... ($((COUNT+1))/${MAX_RETRIES})"
    sleep 6
    COUNT=$((COUNT+1))
  done

  if [ $COUNT -ge $MAX_RETRIES ]; then
     echo "ERROR: Fabric CA server (${CA_NAME}) failed to start within the timeout period."
     echo "Check CA logs: docker logs ${CA_NAME}"
     docker compose -f $DOCKER_COMPOSE_CA_FILE down # Attempt cleanup
     exit 1
  fi
  echo "CA server started successfully."

  # --- Enroll CA Admin and Prepare MSP ---
  echo "Enrolling the CA admin (${CA_ADMIN_USER})..."
  # Define where the CA's TLS cert will be stored
  export FABRIC_CA_CLIENT_HOME="${ORG_CA_DIR}/client-admin"
  mkdir -p "${FABRIC_CA_CLIENT_HOME}/msp"

  # We need the CA's TLS cert to communicate securely
  CA_TLS_CERTFILE="${ORG_CA_DIR}/server-data/ca-cert.pem" # Default location where CA server writes its root cert

  # Enroll the admin user specified in the config
  "$FABRIC_CA_CLIENT_PATH" enroll -u https://${CA_ADMIN_USER}:${CA_ADMIN_PASS}@localhost:${CA_PORT} --caname ${CA_NAME} \
   -M "${FABRIC_CA_CLIENT_HOME}/msp" --tls.certfiles "${CA_TLS_CERTFILE}"

  if [ $? -ne 0 ]; then
      echo "ERROR: Failed to enroll CA admin."
      echo "Check CA logs: docker logs ${CA_NAME}"
      exit 1
  fi
  echo "CA Admin enrolled successfully."

  # Copy Node OU config (essential for peers and orderers)
  # This typically comes from fabric-samples/test-network or a similar structure
  # Adapt path if necessary
  NODE_OU_CONFIG_SRC="$FABRIC_SAMPLES_DIR/test-network/organizations/fabric-ca/msp/config.yaml"
  NODE_OU_CONFIG_DEST="${ORG_PEER_DIR}/msp/config.yaml"

  if [ ! -f "$NODE_OU_CONFIG_SRC" ]; then
      echo "WARNING: Node OU config file not found at ${NODE_OU_CONFIG_SRC}."
      echo "Attempting to find 'config.yaml' within ${FABRIC_SAMPLES_DIR}/organizations..."
      # Try a common alternative location
      NODE_OU_CONFIG_SRC=$(find "$FABRIC_SAMPLES_DIR/organizations" -name config.yaml -print -quit)
      if [ -z "$NODE_OU_CONFIG_SRC" ] || [ ! -f "$NODE_OU_CONFIG_SRC" ]; then
          echo "ERROR: Cannot locate a suitable Node OU 'config.yaml' in fabric-samples. Peer MSP setup will be incomplete."
          exit 1
      fi
      echo "Found Node OU config at: ${NODE_OU_CONFIG_SRC}"
  fi

  mkdir -p "${ORG_PEER_DIR}/msp"
  cp "${NODE_OU_CONFIG_SRC}" "${NODE_OU_CONFIG_DEST}"
  echo "Copied Node OU config to ${ORG_DOMAIN} MSP directory."

  # --- Register and Enroll Peers ---
  echo "Registering and enrolling peers..."
  for (( i=0; i<$NUM_PEERS; i++ ))
  do
    PEER_HOST="peer${i}"
    PEER_FULL_HOST="peer${i}.${ORG_DOMAIN}"
    PEER_PASS="${PEER_HOST}pw"
    PEER_DIR="${ORG_PEER_DIR}/peers/${PEER_FULL_HOST}"
    PEER_MSP_DIR="${PEER_DIR}/msp"
    PEER_TLS_DIR="${PEER_DIR}/tls"

    echo "\nRegistering ${PEER_HOST} with Fabric CA..."
    # Use the CA admin's identity to register the peer
    export FABRIC_CA_CLIENT_HOME="${ORG_CA_DIR}/client-admin"
    "$FABRIC_CA_CLIENT_PATH" register --caname ${CA_NAME} --id.name ${PEER_HOST} --id.secret ${PEER_PASS} \
      --id.type peer --tls.certfiles "${CA_TLS_CERTFILE}"

    echo "Enrolling ${PEER_HOST} (MSP)..."
    # Set client home to the peer's directory for enrollment artifacts
    export FABRIC_CA_CLIENT_HOME="${PEER_DIR}"
    mkdir -p "$PEER_MSP_DIR"
    "$FABRIC_CA_CLIENT_PATH" enroll -u https://${PEER_HOST}:${PEER_PASS}@localhost:${CA_PORT} --caname ${CA_NAME} \
      -M "${PEER_MSP_DIR}" --csr.hosts ${PEER_FULL_HOST} --tls.certfiles "${CA_TLS_CERTFILE}"
    # Copy the NodeOU config into the peer's MSP dir
    cp "${NODE_OU_CONFIG_DEST}" "${PEER_MSP_DIR}/config.yaml"

    echo "Enrolling ${PEER_HOST} (TLS)..."
    mkdir -p "$PEER_TLS_DIR"
    "$FABRIC_CA_CLIENT_PATH" enroll -u https://${PEER_HOST}:${PEER_PASS}@localhost:${CA_PORT} --caname ${CA_NAME} \
      -M "${PEER_TLS_DIR}" --enrollment.profile tls --csr.hosts ${PEER_FULL_HOST} --csr.hosts localhost \
      --tls.certfiles "${CA_TLS_CERTFILE}"

    # Rename TLS certs to standard names expected by peer/orderer
    # CA's root cert:
    cp "${PEER_TLS_DIR}/tlscacerts/"* "${PEER_TLS_DIR}/ca.crt"
    # Peer's TLS server cert:
    cp "${PEER_TLS_DIR}/signcerts/"* "${PEER_TLS_DIR}/server.crt"
    # Peer's TLS server private key:
    cp "${PEER_TLS_DIR}/keystore/"* "${PEER_TLS_DIR}/server.key"

    # Remove intermediate CA certs if any, and enrollment artifacts we don't need
    rm -f "${PEER_TLS_DIR}/cacerts/"* "${PEER_TLS_DIR}/intermediatecerts/"* "${PEER_TLS_DIR}/users/"* \
          "${PEER_TLS_DIR}/IssuerPublicKey" "${PEER_TLS_DIR}/IssuerRevocationPublicKey" \
          "${PEER_TLS_DIR}/fabric-ca-client-config.yaml"

    # Optional: Clean up intermediate/user certs from MSP dir too
    rm -f "${PEER_MSP_DIR}/cacerts/"* "${PEER_MSP_DIR}/intermediatecerts/"* "${PEER_MSP_DIR}/users/"* \
          "${PEER_MSP_DIR}/IssuerPublicKey" "${PEER_MSP_DIR}/IssuerRevocationPublicKey" \
          "${PEER_MSP_DIR}/fabric-ca-client-config.yaml"

    echo "${PEER_HOST} enrolled successfully."
  done

  # --- Register and Enroll Org Admin User ---
  ADMIN_USER_ID="Admin@${ORG_DOMAIN}"
  ADMIN_USER_PASS="adminpw" # Use a strong password in production!
  ADMIN_USER_DIR="${ORG_PEER_DIR}/users/${ADMIN_USER_ID}"
  ADMIN_USER_MSP_DIR="${ADMIN_USER_DIR}/msp"
  echo "\nRegistering Org Admin User (${ADMIN_USER_ID})..."
  # Use CA Admin's identity to register the Org Admin
  export FABRIC_CA_CLIENT_HOME="${ORG_CA_DIR}/client-admin"
  "$FABRIC_CA_CLIENT_PATH" register --caname ${CA_NAME} --id.name ${ADMIN_USER_ID} --id.secret ${ADMIN_USER_PASS} \
   --id.type client --id.attrs '"hf.Registrar.Roles=client","hf.AffiliationMgr=false","hf.Revoker=false","hf.GenCRL=false","admin=true:ecert"' \
   --tls.certfiles "${CA_TLS_CERTFILE}"

  echo "Enrolling Org Admin User (${ADMIN_USER_ID})..."
  # Set client home to the Admin User's directory
  export FABRIC_CA_CLIENT_HOME="${ADMIN_USER_DIR}"
  mkdir -p "$ADMIN_USER_MSP_DIR"
  "$FABRIC_CA_CLIENT_PATH" enroll -u https://${ADMIN_USER_ID}:${ADMIN_USER_PASS}@localhost:${CA_PORT} --caname ${CA_NAME} \
    -M "${ADMIN_USER_MSP_DIR}" --tls.certfiles "${CA_TLS_CERTFILE}"
  # Copy NodeOU config for the admin user MSP
  cp "${NODE_OU_CONFIG_DEST}" "${ADMIN_USER_MSP_DIR}/config.yaml"
  echo "Org Admin User ${ADMIN_USER_ID} enrolled successfully."

  # Unset FABRIC_CA_CLIENT_HOME to avoid interfering with other commands
  unset FABRIC_CA_CLIENT_HOME

fi # End of check for existing CA / crypto

echo "----------------------------------------"

# --- Create Docker Compose File for Peers ---
echo "#############################################"
echo "### Creating Peer Docker Compose File   ###"
echo "#############################################"

DOCKER_COMPOSE_PEERS_FILE="docker-compose-org1-peers.yaml"

echo "Generating $DOCKER_COMPOSE_PEERS_FILE..."

cat > $DOCKER_COMPOSE_PEERS_FILE <<EOF
version: '3.7'

volumes:
EOF

# Add volumes for each peer
for (( i=0; i<$NUM_PEERS; i++ ))
do
  echo "  peer${i}.${ORG_DOMAIN}:" >> $DOCKER_COMPOSE_PEERS_FILE
done

# Add network definition (referencing the one created by CA compose)
cat >> $DOCKER_COMPOSE_PEERS_FILE <<EOF

networks:
  ${ORG_NAME,,}_net:
    name: ${ORG_NAME,,}_fabric_network # Matches the name defined in CA compose
    external: true # Specify that the network is created elsewhere

services:
EOF

# Define services for each peer
PEER_START_PORT=7051
OPS_START_PORT=9443 # Start operations ports from 9443 upwards
CC_START_PORT=7052

for (( i=0; i<$NUM_PEERS; i++ ))
do
  PEER_NAME="peer${i}.${ORG_DOMAIN}"
  PEER_PORT=$((PEER_START_PORT + i * 1000)) # 7051, 8051, 9051
  OPS_PORT=$((OPS_START_PORT + i))          # 9443, 9444, 9445
  CC_PORT=$((CC_START_PORT + i * 1000))     # 7052, 8052, 9052

  # Determine gossip bootstrap peer(s)
  # Peer 0 points to Peer 1 (if exists), others point to Peer 0
  if [ $i -eq 0 ]; then
    if [ $NUM_PEERS -gt 1 ]; then
        NEXT_PEER_PORT=$((PEER_START_PORT + 1 * 1000))
        GOSSIP_BOOTSTRAP="peer1.${ORG_DOMAIN}:${NEXT_PEER_PORT}"
    else
        GOSSIP_BOOTSTRAP="${PEER_NAME}:${PEER_PORT}" # Point to self if only one peer
    fi
  else
    GOSSIP_BOOTSTRAP="peer0.${ORG_DOMAIN}:${PEER_START_PORT}"
  fi

  cat >> $DOCKER_COMPOSE_PEERS_FILE <<EOF
  ${PEER_NAME}:
    container_name: ${PEER_NAME}
    image: hyperledger/fabric-peer:${PEER_IMAGE_TAG}
    labels:
      service: hyperledger-fabric
    environment:
      # Generic Peer environment variables
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      # the following setting starts chaincode containers on the same
      # bridge network as the peers
      # https://docs.docker.com/compose/networking/
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=${ORG_NAME,,}_fabric_network # Network name
      - FABRIC_LOGGING_SPEC=INFO # Set to DEBUG for more verbose logging
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_PROFILE_ENABLED=false # Disable profiling
      # Peer specific variables
      - CORE_PEER_ID=${PEER_NAME}
      - CORE_PEER_ADDRESS=${PEER_NAME}:${PEER_PORT}
      - CORE_PEER_LISTENADDRESS=0.0.0.0:${PEER_PORT}
      - CORE_PEER_CHAINCODEADDRESS=${PEER_NAME}:${CC_PORT}
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:${CC_PORT}
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=${PEER_NAME}:${PEER_PORT}
      - CORE_PEER_GOSSIP_BOOTSTRAP=${GOSSIP_BOOTSTRAP}
      - CORE_PEER_LOCALMSPID=${MSP_ID}
      # TLS settings
      - CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
      - CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      - CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt # CA Root cert for TLS handshake
      # MSP settings
      - CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/msp
      # Operations service settings
      - CORE_OPERATIONS_LISTENADDRESS=0.0.0.0:${OPS_PORT}
      - CORE_OPERATIONS_TLS_ENABLED=false # Set to true if you want TLS for operations endpoint
      # - CORE_OPERATIONS_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt # Use same TLS certs if TLS enabled
      # - CORE_OPERATIONS_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      # - CORE_OPERATIONS_TLS_CLIENTROOTCAS_FILES=/etc/hyperledger/fabric/tls/ca.crt # CA cert for client auth if needed
      - CORE_METRICS_PROVIDER=disabled # Set to 'prometheus' to enable metrics
    volumes:
        - /var/run/:/host/var/run/ # Mount docker sock
        # Mount crypto material generated by Fabric CA
        - ${ORG_PEER_DIR}/peers/${PEER_NAME}/msp:/etc/hyperledger/fabric/msp
        - ${ORG_PEER_DIR}/peers/${PEER_NAME}/tls:/etc/hyperledger/fabric/tls
        # Mount persistent storage for ledger state
        - ${PEER_NAME}:/var/hyperledger/production
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    ports:
      - "${PEER_PORT}:${PEER_PORT}"
      - "${OPS_PORT}:${OPS_PORT}"   # Expose operations port
    networks:
      - ${ORG_NAME,,}_net

EOF
done

echo "$DOCKER_COMPOSE_PEERS_FILE created successfully."
echo "----------------------------------------"

# --- Start Peer Containers ---
echo "#############################################"
echo "### Starting Peer Containers...           ###"
echo "#############################################"

# Check if peers are already running
PEERS_RUNNING=$(docker ps -q -f name="^peer[0-9]+\\.${ORG_DOMAIN}$" | wc -l | tr -d ' ')
if [ "$PEERS_RUNNING" -ge "$NUM_PEERS" ]; then
    echo "Peers for ${ORG_DOMAIN} appear to be running already. Skipping start."
    docker ps -f name="peer.*.${ORG_DOMAIN}"
else
    echo "Bringing up ${ORG_NAME} peers using $DOCKER_COMPOSE_PEERS_FILE..."
    docker compose -f $DOCKER_COMPOSE_PEERS_FILE up -d

    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to start peer containers with docker compose."
        echo "Check peer logs for errors (e.g., docker logs peer0.${ORG_DOMAIN})"
        exit 1
    fi

    echo "Waiting briefly for peers to start... (Check 'docker ps' and logs)"
    sleep 5
    docker ps -f name="peer.*.${ORG_DOMAIN}" # Show only the peers for this org
fi

echo "----------------------------------------"
echo "### Setup Complete! ###"
echo "----------------------------------------"
echo "Fabric CA Server (${CA_NAME}) and ${NUM_PEERS} peers for ${ORG_NAME} (${ORG_DOMAIN}) should be running."
echo "Configuration and crypto materials are in: $PEER_ORG_SETUP_DIR"
echo "CA Docker Compose file: $PEER_ORG_SETUP_DIR/$DOCKER_COMPOSE_CA_FILE"
echo "Peers Docker Compose file: $PEER_ORG_SETUP_DIR/$DOCKER_COMPOSE_PEERS_FILE"
echo "Org Admin User materials: ${ORG_PEER_DIR}/users/${ADMIN_USER_ID}/msp"
echo ""
echo "To view logs:"
echo "docker logs -f ${CA_NAME}"
echo "docker logs -f peer0.${ORG_DOMAIN}"
# ... etc for other peers
echo ""
echo "To stop peers ONLY:"
echo "cd $PEER_ORG_SETUP_DIR"
echo "docker compose -f $DOCKER_COMPOSE_PEERS_FILE down"
echo ""
echo "To stop CA ONLY:"
echo "cd $PEER_ORG_SETUP_DIR"
echo "docker compose -f $DOCKER_COMPOSE_CA_FILE down"
echo ""
echo "To stop CA and Peers:"
echo "cd $PEER_ORG_SETUP_DIR"
echo "docker compose -f $DOCKER_COMPOSE_PEERS_FILE -f $DOCKER_COMPOSE_CA_FILE down"
echo ""
echo "To stop CA/Peers and remove volumes (CA data, ledger data):"
echo "docker compose -f $DOCKER_COMPOSE_PEERS_FILE -f $DOCKER_COMPOSE_CA_FILE down -v"
echo ""
echo "NOTE: To join an existing channel, you will need the channel's genesis block or a config block,"
echo "and the connection details (addresses, TLS certs) for the ordering service."
echo "Use the generated Org Admin credentials (${ADMIN_USER_DIR}/msp) or peer credentials"
echo "with the 'peer channel fetch' and 'peer channel join' commands." 