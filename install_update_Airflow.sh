#!/usr/bin/env bash
# ==============================================================================
# Github: 
# Script: Airflow 3.x Installer (WSL + Windows Bridge)
# ==============================================================================

# Exit immediately if a command exits with a non-zero status
set -e

# Define log file name with current date
TODAY=$(date +"%Y%m%d")
LOGFILE="airflow-standalone-$TODAY.txt"

# --- Logging Functions ---
# Writes a timestamped message to the log file
log_file()    { echo "[$(date +"%H:%M:%S")] $1" >> "$LOGFILE"; }

# Displays formatted INFO message and logs it
log_info()    { echo -e "\e[34m[INFO]\e[0m $1";  log_file "[INFO] $1"; }

# Displays formatted WARN message and logs it
log_warn()    { echo -e "\e[33m[WARN]\e[0m $1";  log_file "[WARN] $1"; }

# Displays formatted ERROR message and logs it
log_error()   { echo -e "\e[31m[ERROR]\e[0m $1"; log_file "[ERROR] $1"; }

# Displays formatted SUCCESS message and logs it
log_success() { echo -e "\e[32m[OK]\e[0m $1";    log_file "[OK] $1"; }

# Global arrays to track resources for rollback operations
CREATED_DIRS=()
CREATED_FILES=()

rollback() {
    # If any error occurs during installation, clean up created directories and files
    log_error "Installation error detected. Starting rollback of created items..."
    
    # Iterate through the list of created directories and remove them safely
    for d in "${CREATED_DIRS[@]}"; do
        [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
    done
    
    # Iterate through the list of created files and remove them safely
    for f in "${CREATED_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
    done
    
    log_warn "Rollback complete. The environment has been restored to its previous state."
    exit 1
}

require_sudo() {
    # Check if the user has sudo privileges and refresh the credentials cache
    if ! sudo -v; then
        log_error "This script requires administrative (sudo) permissions to manage system packages."
        log_warn "Please ensure your user is in the sudoers group and try again."
        exit 1
    fi
    
    # Keep-alive: update existing sudo time stamp until the script has finished
    # This prevents the password prompt from appearing multiple times
    while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
}

check_dependencies() {
    log_info "Verifying system dependencies (curl, jq, python3)..."
    
    # List of required packages for the script to function correctly
    DEPS=("curl" "jq" "python3" "python3-venv" "python3-pip")
    MISSING_DEPS=()

    # Check each dependency using dpkg to see if it's already installed
    for tool in "${DEPS[@]}"; do
        if ! dpkg -s "$tool" >/dev/null 2>&1; then
            MISSING_DEPS+=("$tool")
        fi
    done

    # If there are missing dependencies, install them using apt
    if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
        log_warn "Missing dependencies: ${MISSING_DEPS[*]}. Installing now..."
        sudo apt update && sudo apt install -y "${MISSING_DEPS[@]}"
        log_success "All dependencies installed successfully."
    else
        log_info "All system dependencies are already met."
    fi
}

detect_wsl_distro() {
    # Check if we are actually running inside a WSL environment
    if ! grep -qi microsoft /proc/version; then
        log_warn "Non-WSL environment detected. Windows features will be skipped."
        WSL_DISTRO=""
        return
    fi

    # Retrieve the WSL Distro name, checking the environment variable first, 
    # then falling back to a PowerShell query if necessary.
    # We use tr and xargs to clean up any Windows line endings or extra spaces.
    WSL_DISTRO=${WSL_DISTRO_NAME:-$(powershell.exe -NonInteractive -NoProfile -Command "Write-Output \$env:WSL_DISTRO_NAME" | tr -d '\r' | xargs)}
    
    log_info "WSL Environment detected: $WSL_DISTRO"
}

choose_airflow_version() {
    log_info "Fetching Airflow 3.x versions from PyPI..."
    
    # Activate venv to ensure we use the correct Python version for constraints
    source "$AIRFLOW_VENV/bin/activate"
    PY_VER=$(python3 -c 'import sys; print(".".join(map(str, sys.version_info[:2])))')
    
    # Fetch all versions, filter for Major version 3+, and sort them descending
    ALL_VERSIONS=$(curl -s https://pypi.org/pypi/apache-airflow/json | jq -r '.releases | keys[]' | sort -Vr)
    COMPATIBLE=()
    for v in $ALL_VERSIONS; do
        major="${v%%.*}"
        [ "$major" -ge 3 ] && COMPATIBLE+=("$v")
    done

    if [ ${#COMPATIBLE[@]} -eq 0 ]; then
        log_error "No Airflow 3.x versions found. Please check your internet connection."
        exit 1
    fi

    # Display versions in an 80-column grid for better readability
    echo -e "\nAvailable Airflow 3.x Versions:"
    TERM_WIDTH=80
    MAXLEN=0
    for v in "${COMPATIBLE[@]}"; do [ ${#v} -gt $MAXLEN ] && MAXLEN=${#v}; done
    COL_WIDTH=$((MAXLEN + 8))
    COLS=$((TERM_WIDTH / COL_WIDTH)); [ $COLS -lt 1 ] && COLS=1
    
    i=1
    for v in "${COMPATIBLE[@]}"; do
        printf "%-*s" "$COL_WIDTH" "$i) $v"
        (( i % COLS == 0 )) && printf "\n"
        i=$((i+1))
    done
    printf "\n"

    # Selection loop with validation
    while true; do
        read -p "Select version number: " INDEX
        if [[ "$INDEX" =~ ^[0-9]+$ ]] && [ "$INDEX" -ge 1 ] && [ "$INDEX" -le "${#COMPATIBLE[@]}" ]; then
            AIRFLOW_VERSION="${COMPATIBLE[$((INDEX-1))]}"
            break
        fi
        log_warn "Invalid selection. Please enter a number from the list above."
    done

    # Set the official constraints URL based on selected version and python version
    CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-$AIRFLOW_VERSION/constraints-$PY_VER.txt"
    log_info "Selected Airflow Version: $AIRFLOW_VERSION"
    log_info "Constraints URL: $CONSTRAINTS_URL"
}

create_windows_autostart() {
    [ -z "$WSL_DISTRO" ] && return
    
    # Get the current WSL user to hardcode in the Windows Task
    USER=$(whoami)
    # Identify Windows user and define bridge paths
    USER_WIN=$(powershell.exe -NonInteractive -Command "echo \$env:USERNAME" | tr -d '\r' | xargs)
    BAT_PATH="/mnt/c/Users/$USER_WIN/airflow_autostart.bat"
    WIN_BAT="C:\\Users\\$USER_WIN\\airflow_autostart.bat"

    log_info "Creating Windows Bridge script at $BAT_PATH"
    
    # Generate the .bat file using heredoc
    # Note: Variables like $WSL_DISTRO and $AIRFLOW_PORT are expanded here by the installer
    cat <<EOF > "$BAT_PATH"
@echo off
setlocal enabledelayedexpansion

:: Ensure the script runs with Administrative privileges
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '\"%1\"' -Verb RunAs"
    exit /b
)


:: --- ROUTING LOGIC ---
if "%~1"=="create" goto :create_task
if "%~1"=="delete" goto :delete_task
if "%~1"=="run"    goto :run_maintenance_and_airflow

:: If no valid argument is passed, show usage and exit
echo Usage: %~nx0 {create ^| delete ^| run}
timeout /t 5
exit /b

:create_task
    echo [INFO] Registering Airflow AutoStart Task...
    schtasks /create /tn Airflow3AutoStart /tr "\"%~f0\" run" /sc ONLOGON /rl HIGHEST /f
    exit /b

:delete_task
    echo [INFO] Removing Airflow AutoStart Task...
    schtasks /delete /tn Airflow3AutoStart /f
    exit /b

:run_maintenance_and_airflow
    :: --- START DISK MAINTENANCE - IN DEVELOPMENT - NEED TO TEST THIS ---
    :: echo [INFO] Starting WSL Disk Maintenance...
    :: wsl --shutdown
    :: powershell -NoProfile -ExecutionPolicy Bypass -Command " ^
    ::     \$vhd = (Get-ChildItem -Path \"\$env:LOCALAPPDATA\Packages\" -Include \"ext4.vhdx\" -Recurse | Select-Object -First 1).FullName; ^
    ::     if (\$vhd) { ^
    ::         Write-Host '[INFO] Compacting VHD: ' \$vhd; ^
    ::         \$tempFile = \"\$env:TEMP\compact_airflow_boot.txt\"; ^
    ::         'select vdisk file=' + '\"' + \$vhd + '\"', 'attach vdisk readonly', 'compact vdisk', 'detach vdisk' | Out-File -FilePath \$tempFile -Encoding ascii; ^
    ::         Start-Process diskpart -ArgumentList \"/s \$tempFile\" -Wait; ^
    ::         Remove-Item \$tempFile; ^
    ::     }"
    :: echo [OK] Disk maintenance finished.
    :: --- FINISH DISK MAINTENANCE - IN DEVELOPMENT - NEED TO TEST THIS ---

    :: --- START AIRFLOW ---
    echo [INFO] Starting Airflow Service...
    C:\\Windows\\System32\\wsl.exe -d $WSL_DISTRO -u $USER bash -lc 'export AIRFLOW_HOME=$AIRFLOW_HOME; . $AIRFLOW_VENV/bin/activate; airflow standalone '
    
    if %errorlevel% neq 0 (
        echo [ERRO] O Airflow parou com erro %errorlevel%
        pause
    )
    exit /b
EOF
    chmod +x "$BAT_PATH"
    CREATED_FILES+=("$BAT_PATH")

    log_info "Opening Windows UAC Prompt... Please authorize."
    powershell.exe -NoProfile -NonInteractive -Command "Start-Process '$WIN_BAT' -Verb RunAs -ArgumentList 'create'"
    
    # Polling Logic
    MAX_RETRIES=15
    RETRY=0
    while [ $RETRY -lt $MAX_RETRIES ]; do
        if powershell.exe -NonInteractive -Command "schtasks /query /tn Airflow3AutoStart" &>/dev/null; then
            log_success "Windows Auto-start Task linked!"
            return
        fi
        sleep 2
        RETRY=$((RETRY+1))
    done
    log_warn "UAC Task creation timed out or was denied."
}

install_flow() {
# Run initial system checks and environment detection
    require_sudo
    check_dependencies
    detect_wsl_distro

    # Installation Guard Loop: Prevents accidental overwrites of existing installations
    while true; do
        # Prompt for Airflow Home and Virtualenv paths with default values
        read -p "Airflow home [~/airflow]: " AIRFLOW_HOME
        AIRFLOW_HOME=${AIRFLOW_HOME:-$HOME/airflow}
        read -p "Virtualenv path [~/airflow_venv]: " AIRFLOW_VENV
        AIRFLOW_VENV=${AIRFLOW_VENV:-$HOME/airflow_venv}

        # Check if an existing installation is detected at the specified locations
        if [ -f "$AIRFLOW_HOME/airflow.cfg" ] || [ -d "$AIRFLOW_VENV/bin" ]; then
            log_warn "Conflict: An Airflow installation was already detected at these locations."
            echo "Options: [y]es (Overwrite) | [n]o (Change Path) | [c]ancel (Abort)"
            read -p "Your choice: " GUARD_CHOICE
            
            # Handle user decision with case-insensitive matching
            case "${GUARD_CHOICE,,}" in
                y|yes) 
                    log_info "Proceeding with overwrite as requested..."
                    break ;;
                n|no) 
                    log_info "Please specify new installation paths."
                    continue ;;
                c|cancel) 
                    log_info "Installation process cancelled by user."
                    return ;;
                *) 
                    log_warn "Invalid option. Please type 'y', 'n', or 'c'."
                    continue ;;
            esac
        else
            # No existing installation found; proceed with current paths
            break
        fi
    done

    # Set a trap to trigger the rollback function on any error
    trap 'rollback' ERR

    # Create necessary Airflow directories
    mkdir -p "$AIRFLOW_HOME"/{dags,logs,plugins}
    CREATED_DIRS+=("$AIRFLOW_HOME" "$AIRFLOW_VENV")

    # Prompt user for the Webserver port with a default value
    read -p "Webserver port [8080]: " AIRFLOW_PORT
    AIRFLOW_PORT=${AIRFLOW_PORT:-8080}

    # Prompt user for the IP default address with a default value
    read -p "IP address [127.0.0.1]: " AIRFLOW_IP
    AIRFLOW_IP=${AIRFLOW_IP:-127.0.0.1}

    # Initialize the Python virtual environment
    python3 -m venv "$AIRFLOW_VENV"
    
    # Call the version selection function
    choose_airflow_version

    # Activate the environment and upgrade core packaging tools
    source "$AIRFLOW_VENV/bin/activate"
    pip install --upgrade pip setuptools wheel
    
    # Attempt to install Airflow using the official constraints file
    log_info "Installing Airflow $AIRFLOW_VERSION with constraints..."
    pip install "apache-airflow==$AIRFLOW_VERSION" --constraint "$CONSTRAINTS_URL" || {
        # Fallback: install without constraints if the URL is unreachable or invalid
        log_warn "Constraints installation failed. Attempting direct installation..."
        pip install "apache-airflow==$AIRFLOW_VERSION"
    }

    # Set AIRFLOW_HOME environment variable for the database initialization
    export AIRFLOW_HOME="$AIRFLOW_HOME"
    
    # Initialize the metadata database (using migrate for Airflow 3+ or init as fallback)
    log_info "Initializing Airflow Database..."
    airflow db migrate || airflow db init

    # Update Airflow Configuration: 
    log_info "Applying configurations to airflow.cfg..."
    # Disable examples
    sed -i "s/^load_examples = .*/load_examples = False/" "$AIRFLOW_HOME/airflow.cfg"
    # Set the custom Webserver port 
    sed -i "s/^web_server_port = .*/web_server_port = $AIRFLOW_PORT/" "$AIRFLOW_HOME/airflow.cfg"
    # Protect
    sed -i "s/^host = 0.0.0.0.*/host = $AIRFLOW_IP/" "$AIRFLOW_HOME/airflow.cfg"

    # Maintenance DAG: Deploying a 3-day log cleanup task (Scheduled for 01:00 AM)
    log_info "Deploying Maintenance DAG: 3-day Log Cleanup..."
    cat <<EOF > "$AIRFLOW_HOME/dags/dag_log_cleanup.py"
from airflow import DAG
from airflow.providers.standard.operators.bash import BashOperator
import pendulum  # Airflow includes pendulum by default
from datetime import timedelta
import os

# Define AIRFLOW_HOME in case the environment variable is not correctly inherited by the BashOperator
airflow_home = os.environ.get("AIRFLOW_HOME", os.path.expanduser("~/airflow"))

with DAG(
    "maintenance_log_cleanup",
    # Replacing legacy days_ago(1) with pendulum to fetch the previous day in UTC
    start_date=pendulum.today('UTC').add(days=-1),
    schedule="0 1 * * *",
    catchup=False,
    tags=["maintenance"],
    doc_md="""
    ### Log Cleanup DAG
    This DAG deletes Airflow task logs older than 3 days to prevent disk space issues on WSL.
    """
) as dag:
    
    BashOperator(
        task_id="cleanup_logs",
        # Using absolute path to ensure the command runs correctly regardless of shell context
        bash_command=f"find {airflow_home}/logs/ -type f -mtime +3 -print -delete"
    )
EOF

    # Finalize Windows Integration: Prompt user to enable the auto-start bridge
    read -p "Enable Windows auto-start bridge? (y/n) [y]: " AUTOWIN
    [[ "${AUTOWIN:-y}" =~ ^[Yy]$ ]] && create_windows_autostart

    # Disable the error trap once the installation is successful
    trap - ERR
    
    # Final success message for the user
    log_success "Airflow 3 installation completed successfully!"
    log_info "You can now start Airflow by running: airflow standalone"
}

uninstall_flow() {
    # Ensure environment variables exist for the removal process
    AIRFLOW_HOME=${AIRFLOW_HOME:-$HOME/airflow}
    AIRFLOW_VENV=${AIRFLOW_VENV:-$HOME/airflow_venv}
    
    log_warn "DANGER: This will delete everything in $AIRFLOW_HOME and $AIRFLOW_VENV, plus Windows tasks."
    read -p "Type 'DELETE' to confirm: " CONF
    
    if [ "$CONF" == "DELETE" ]; then
        # Identify Windows user and define paths (Windows vs WSL mount)
        USER_WIN=$(powershell.exe -NonInteractive -Command "echo \$env:USERNAME" | tr -d '\r' | xargs)
        BAT_WIN_PATH="C:\\Users\\$USER_WIN\\airflow_autostart.bat"
        BAT_WSL_PATH="/mnt/c/Users/$USER_WIN/airflow_autostart.bat"

        # Attempt to remove the Scheduled Task via PowerShell with UAC Elevation
        log_info "Requesting Admin privileges to remove Windows Task..."
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
            "Start-Process powershell.exe -ArgumentList '-NoProfile -Command & {schtasks /delete /tn Airflow3AutoStart /f}' -Verb RunAs -Wait"

        # Remove the Windows bridge .bat file using the WSL mount path
        if [ -f "$BAT_WSL_PATH" ]; then
            log_info "Removing bridge file: $BAT_WSL_PATH"
            rm -f "$BAT_WSL_PATH"
        fi

        # Clean up Linux installation directories
        log_info "Cleaning up Linux directories..."
        rm -rf "$AIRFLOW_HOME" "$AIRFLOW_VENV"

        log_success "Uninstallation complete. Windows task, bridge file, and Linux data removed."
    else
        log_info "Uninstallation aborted by user."
    fi
}

start_flow() {
    # Setup paths
    export AIRFLOW_HOME=${AIRFLOW_HOME:-$HOME/airflow}
    local venv_path=${AIRFLOW_VENV:-$HOME/airflow_venv}

    # Safety check: Ensure the configuration file exists
    if [ ! -f "$AIRFLOW_HOME/airflow.cfg" ]; then
        log_error "Configuration file not found at $AIRFLOW_HOME/airflow.cfg"
        return
    fi

    # Verify and Launch Airflow 3.x
    if [ -d "$venv_path" ]; then
        log_info "Activating environment: $venv_path"
        source "$venv_path/bin/activate"
        
        # We read the port just for the log message, so the user knows where to click
        local port_to_use=$(grep -E "^web_server_port\s*=" "$AIRFLOW_HOME/airflow.cfg" | awk -F'=' '{print $2}' | tr -d ' \r ')
        port_to_use=${port_to_use:-8080}

        log_success "Starting Apache Airflow 3.x Standalone..."
        log_info "Webserver will be available at: http://localhost:$port_to_use"
        log_warn "Press CTRL+C to stop the services."
        
        # FIXED: Airflow 3 standalone does not accept --port argument anymore.
        # It reads the port directly from your airflow.cfg.
        airflow standalone
    else
        log_error "Virtual environment not found at $venv_path"
    fi
}

# --- Interactive Menu ---
while true; do
    set +e
    clear
    echo "=============================================="
    echo "       Apache Airflow 3.x - Standalone         "
    echo "=============================================="
    echo "1) Install Airflow"
    echo "2) Uninstall Airflow"
    echo "3) Start Airflow now (Interactive)"
    echo "4) Exit"
    echo ""
    read -p "Choice: " OP

    case "$OP" in
        1) install_flow ;;
        2) uninstall_flow ;;
        3) start_flow ;;
        4) exit 0 ;;
        *) log_warn "Invalid option: $OP" ;;
    esac

    echo ""
    read -p "Press ENTER to continue..."
done