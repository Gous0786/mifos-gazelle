#!/bin/bash
# Fixed script to detect architecture and download/install the correct JDK binaries.

# --- Configuration ---
# Define a list of desired JDK versions and their provider/base information.
# Format: "VERSION|PROVIDER|URL_TEMPLATE"
# PROVIDER determines the URL logic and naming convention.
#  - 'oracle_archive': For older Oracle releases (e.g., JDK 11, 13, 17)
#  - 'temurin8': For Adoptium Temurin JDK 8
# NOTE: You MUST update the URL templates if the provider's naming scheme changes.
jdk_config=(
    "17.0.2|oracle_archive|https://download.java.net/java/GA/jdk$VERSION_MAJOR/$BUILD/GPL/openjdk-$VERSION_FULL_DASH_NO_U_$OS_ARCH_BIN_FILENAME"
    "8u422-b05|temurin8|https://github.com/adoptium/temurin8-binaries/releases/download/jdk$VERSION_NO_DASH_U-b$BUILD_SHORT/OpenJDK8U-jdk_$ARCH_SHORT_linux_hotspot_$VERSION_NO_DASH_U_b$BUILD_SHORT.tar.gz"
    "11.0.1|oracle_archive|https://download.java.net/java/GA/jdk$VERSION_MAJOR/$BUILD/GPL/openjdk-$VERSION_FULL_DASH_NO_U_$OS_ARCH_BIN_FILENAME"
)

# --- Architecture and OS Detection ---

# Check OS
if [[ "$(uname -s)" != "Linux" ]]; then
  echo "❌ This script is only for Linux systems."
  exit 1
fi

# Detect architecture and set variables
case "$(uname -m)" in
  x86_64)
    ARCH_SHORT="x64"
    OS_ARCH_BIN_FILENAME="linux-x64_bin.tar.gz"
    ;;
  aarch64)
    ARCH_SHORT="aarch64"
    OS_ARCH_BIN_FILENAME="linux-aarch64_bin.tar.gz"
    ;;
  *)
    echo "❌ Unsupported architecture: $(uname -m). This script supports x86_64 and aarch64."
    exit 1
    ;;
esac

echo "✅ Running on **Linux** (**$ARCH_SHORT** architecture)."
echo "---"

# --- Main Script Logic ---

# Create a downloads directory if it doesn't exist
downloads_dir="$HOME/downloads/jdk_installers"
install_dir="$HOME/java"
mkdir -p "$downloads_dir" "$install_dir"

for config_string in "${jdk_config[@]}"; do
    # Parse the configuration string
    IFS='|' read -r JDK_VERSION PROVIDER URL_TEMPLATE <<< "$config_string"
    
    echo "Processing **JDK $JDK_VERSION** (Provider: **$PROVIDER**)..."

    # --- Variable Setup based on VERSION and PROVIDER ---
    
    # Reset version variables
    JDK_URL=""
    VERSION_MAJOR=""
    VERSION_FULL_DASH_NO_U=""
    VERSION_NO_DASH_U=""
    BUILD=""
    BUILD_SHORT=""

    if [[ "$JDK_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        # Format: X.Y.Z (e.g., 17.0.2)
        VERSION_MAJOR="${BASH_REMATCH[1]}"
        BUILD="$VERSION_MAJOR" # Common build number placeholder
        # For Oracle (>=9), use version with underscores instead of dots for download
        VERSION_FULL_DASH_NO_U="${JDK_VERSION//./_}" 
    elif [[ "$JDK_VERSION" =~ ^([0-9]+)u([0-9]+)-b([0-9]+)$ ]]; then
        # Format: X_uY-bZ (e.g., 8u422-b05)
        VERSION_MAJOR="${BASH_REMATCH[1]}"
        BUILD="${BASH_REMATCH[2]}"
        BUILD_SHORT="${BASH_REMATCH[3]}"
        VERSION_NO_DASH_U="${BASH_REMATCH[1]}u${BASH_REMATCH[2]}"
    else
        echo "⚠️ Skipping JDK $JDK_VERSION: Unknown version format."
        continue
    fi

    # --- URL Construction ---
    
    JDK_URL=$(eval echo "$URL_TEMPLATE") # Use 'eval echo' to substitute variables in URL_TEMPLATE

    if [ -z "$JDK_URL" ]; then
        echo "❌ Failed to construct a valid URL for JDK $JDK_VERSION."
        continue
    fi
    
    # --- Download and Install ---

    echo "  ➡️ URL: $JDK_URL"
    jdk_filename=$(basename "$JDK_URL") 
    download_path="$downloads_dir/$jdk_filename"

    # Check if file already exists
    if [ -f "$download_path" ]; then
        echo "  ✅ File already exists: $jdk_filename. Skipping download."
    else
        echo "  ⬇️ Downloading OpenJDK $JDK_VERSION..."
        curl -L "$JDK_URL" -o "$download_path"

        if [[ $? -ne 0 ]]; then
            echo "  ❌ Failed to download OpenJDK $JDK_VERSION."
            continue
        fi
        echo "  ✅ Downloaded to $download_path"
    fi

    # Check for .tar.gz and extract
    if [[ ! "$jdk_filename" =~ \.tar\.gz$ ]]; then
      echo "  ❌ The downloaded file is not a .tar.gz file. Skipping extraction."
      continue
    fi

    tmp_dir="$downloads_dir/tmp_extract"
    mkdir -p "$tmp_dir"

    echo "  📦 Extracting OpenJDK $JDK_VERSION..."
    if ! tar -xzf "$download_path" -C "$tmp_dir"; then
        echo "  ❌ Failed to extract OpenJDK $JDK_VERSION."
        rm -rf "$tmp_dir"
        continue
    fi

    # --- Dynamic Directory Naming ---
    
    # Find the extracted top-level directory (e.g., jdk-17.0.2 or jdk8u422-b05)
    extracted_dir_name=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [ -z "$extracted_dir_name" ]; then
        echo "  ❌ Failed to find the extracted directory inside $tmp_dir."
        rm -rf "$tmp_dir"
        continue
    fi

    # Extract just the folder name
    base_folder_name=$(basename "$extracted_dir_name")
    
    # --- Move and Cleanup ---

    target_path="$install_dir/$base_folder_name"
    
    if [ -d "$target_path" ]; then
        echo "  ⚠️ Target directory $target_path already exists. Skipping move."
    else
        echo "  ➡️ Installing to $target_path"
        mv "$extracted_dir_name" "$install_dir/"
        echo "  ✅ Installed OpenJDK $JDK_VERSION successfully."
    fi
    
    rm -rf "$tmp_dir"
    echo "---"
done

echo "🎉 All specified JDK versions have been processed and installed to $install_dir."
echo "You may need to update your PATH and JAVA_HOME environment variables."