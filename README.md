# Airflow 3.x Installer (WSL + Windows Bridge)

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)

An automated, interactive Bash utility designed to install, manage, and run **Apache Airflow 3.x** in a standalone configuration. Built specifically with **WSL (Windows Subsystem for Linux)** users in mind, this script includes a unique "Windows Bridge" feature that integrates with Windows Task Scheduler to automatically start your Airflow environment upon Windows logon.

## 🚀 Features

* **Interactive Menu:** Easy-to-use CLI interface for installing, uninstalling, and starting Airflow.
* **Smart Dependency Management:** Automatically detects and installs required packages (`curl`, `jq`, `python3`, `python3-venv`, `python3-pip`).
* **Dynamic Version Selection:** Fetches the latest Airflow 3.x releases directly from PyPI and uses official constraint files for a stable build.
* **Windows Bridge Integration:** Seamlessly creates a Windows `.bat` file and registers a Scheduled Task (requiring UAC) to run Airflow automatically when you log into Windows.
* **Safe Installation:** Features a built-in rollback mechanism to clean up created files and directories if the installation fails midway.
* **Built-in Maintenance:** Automatically deploys a maintenance DAG (`dag_log_cleanup.py`) scheduled to clear task logs older than 3 days, preventing WSL disk bloat.

## 📋 Prerequisites

* Windows compatible with **WSL 2.0**
* A **WSL 2.0** environment (Ubuntu/Debian-based is recommended for `apt` package management).
* User with `sudo` privileges.
* Active internet connection.

## 🛠️ Usage

1.  **Clone the repository or download the script inside your WSL system:**
    ```bash
    git clone [https://github.com/fontmas/wsl2-airflow3-installer.git](https://github.com/fontmas/wsl2-airflow3-installer.git)
    cd wsl2-airflow3-installer
    ```

2.  **Make the script executable:**
    ```bash
    chmod +x airflow_installer.sh
    ```

3.  **Run the script:**
    ```bash
    ./airflow_installer.sh
    ```

## 🧰 Interactive Menu Options

When you run the script, you will be greeted with a main menu:

* **1) Install Airflow:** Walks you through setting up the Airflow home directory, virtual environment path, webserver port, and IP. It then fetches available 3.x versions, installs the selected version, applies configurations, and optionally sets up the Windows auto-start bridge.
* **2) Uninstall Airflow:** Completely removes the Airflow home directory, the Python virtual environment, the Windows bridge `.bat` file, and unregisters the Windows Scheduled Task. 
* **3) Start Airflow now (Interactive):** Activates the virtual environment and runs `airflow standalone`. The console will display the local URL to access the web UI.
* **4) Exit:** Closes the script.

## 🌉 How the Windows Bridge Works

If you opt-in to the Windows auto-start bridge during installation:
1. The script identifies your Windows username via PowerShell.
2. It generates a `.bat` file at `C:\Users\<Your_Windows_User>\airflow_autostart.bat`.
3. It opens a Windows UAC (User Account Control) prompt asking for administrative privileges.
4. Once granted, it registers a Windows Scheduled Task (`Airflow3AutoStart`) that triggers on logon, executing the `.bat` file.
5. The `.bat` file runs a headless WSL command to activate the virtual environment and start `airflow standalone` in the background.

## 📜 License

This project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. 

Permissions of this strong copyleft license are conditioned on making available complete source code of licensed works and modifications, which include larger works using a licensed work, under the same license. Copyright and license notices must be preserved. Contributors provide an express grant of patent rights.

See the [LICENSE](LICENSE) file for more details.
