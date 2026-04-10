#!/usr/bin/env bash
# Vet – macOS Installer
# Tries direct ZIP download first; falls back to GitHub API asset lookup.
#
# Usage (one-liner):
#   bash <(curl -fsSL https://stafne.github.io/vet_app/install_vet.sh)

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

GITHUB_REPO="stafne/vet"
GITHUB_API_BASE="https://api.github.com"
APP_NAME="Vet"

echo ""
echo "============================================================"
echo "  🐾 Vet – macOS Installer"
echo "============================================================"
echo ""

# ── macOS check ───────────────────────────────────────────────────────────────
if [[ "$OSTYPE" != "darwin"* ]]; then
  echo -e "${RED}❌ This installer is for macOS only (detected: $OSTYPE).${NC}"
  exit 1
fi
echo -e "${BLUE}✅ macOS detected${NC}"
echo ""

# ── Dependency check ──────────────────────────────────────────────────────────
check_dependencies() {
  echo -e "${BLUE}🔍 Checking dependencies...${NC}"
  if ! command -v curl &>/dev/null; then
    echo -e "${RED}❌ curl is required. Install Xcode Command Line Tools:${NC}"
    echo "   xcode-select --install"
    exit 1
  fi
  echo -e "${GREEN}✅ curl available${NC}"

  JQ_AVAILABLE=0
  if command -v jq &>/dev/null; then
    JQ_AVAILABLE=1
    echo -e "${GREEN}✅ jq available${NC}"
  else
    echo -e "${YELLOW}⚠  jq not found – will use grep-based fallback${NC}"
  fi
  echo ""
}

# ── Install from a local ZIP path ─────────────────────────────────────────────
install_from_zip() {
  local zip_path="$1"
  local tmp_dir
  tmp_dir=$(dirname "$zip_path")

  echo -e "${BLUE}📦 Extracting...${NC}"
  if ! unzip -q "$zip_path" -d "$tmp_dir"; then
    echo -e "${RED}❌ Failed to extract ZIP.${NC}"
    rm -rf "$tmp_dir"; exit 1
  fi

  local app_src
  app_src=$(find "$tmp_dir" -maxdepth 3 -type d -name "*.app" | head -1)
  if [[ -z "$app_src" ]]; then
    echo -e "${RED}❌ No .app bundle found in the ZIP.${NC}"
    rm -rf "$tmp_dir"; exit 1
  fi

  local app_dest="/Applications/$(basename "$app_src")"
  echo -e "${BLUE}📂 Installing to ${app_dest}...${NC}"

  # Remove previous installation
  [[ -d "$app_dest" ]] && rm -rf "$app_dest"

  if ! ditto --noqtn "$app_src" "$app_dest" 2>/dev/null; then
    cp -R "$app_src" "/Applications/" || {
      echo -e "${RED}❌ Could not copy to Applications. Check permissions.${NC}"
      rm -rf "$tmp_dir"; exit 1
    }
  fi

  # Strip quarantine so macOS doesn't immediately block it
  xattr -rd com.apple.quarantine "$app_dest" 2>/dev/null || true

  rm -rf "$tmp_dir"

  echo ""
  echo -e "${GREEN}✅ ${APP_NAME} installed: ${app_dest}${NC}"
  echo ""
  echo -e "${YELLOW}First launch note:${NC}"
  echo "  • Open Applications → right-click Vet.app → Open"
  echo "  • If blocked: System Settings → Privacy & Security → Open Anyway"
  echo "  • You only need to do this once."
  echo ""

  read -rp "Launch Vet now? (y/n): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    echo -e "${BLUE}🚀 Launching ${APP_NAME}...${NC}"
    open "$app_dest"
  fi
}

# ── Method 1: direct /latest/download/Vet.zip URL ────────────────────────────
try_direct_download() {
  local url="https://github.com/${GITHUB_REPO}/releases/latest/download/Vet.zip"
  local tmp_dir tmp_zip
  tmp_dir=$(mktemp -d)
  tmp_zip="${tmp_dir}/Vet.zip"

  echo -e "${BLUE}📥 Downloading Vet.zip (direct)...${NC}"
  if curl -L --fail --progress-bar -o "$tmp_zip" "$url"; then
    install_from_zip "$tmp_zip"
    return 0
  else
    echo -e "${YELLOW}⚠  Direct download failed – trying GitHub API...${NC}"
    rm -rf "$tmp_dir"
    return 1
  fi
}

# ── Method 2: GitHub API asset lookup ─────────────────────────────────────────
try_api_download() {
  local api_url="${GITHUB_API_BASE}/repos/${GITHUB_REPO}/releases/latest"
  local tmp_json tmp_dir tmp_zip

  echo -e "${BLUE}📡 Fetching release info from GitHub API...${NC}"
  tmp_json=$(mktemp)
  if ! curl -fsSL -H "Accept: application/vnd.github+json" \
              -H "User-Agent: vet-installer" \
              -o "$tmp_json" "$api_url"; then
    echo -e "${RED}❌ Could not reach GitHub API. Check your internet connection.${NC}"
    rm -f "$tmp_json"; exit 1
  fi

  # Parse tag
  local tag
  if [[ "$JQ_AVAILABLE" -eq 1 ]]; then
    tag=$(jq -r '.tag_name' "$tmp_json")
  else
    tag=$(grep -o '"tag_name"\s*:\s*"[^"]*"' "$tmp_json" | head -1 \
          | sed -E 's/.*"([^"]+)".*/\1/')
  fi
  echo -e "${GREEN}Latest release: ${tag}${NC}"

  # Find a ZIP asset
  local asset_name download_url
  if [[ "$JQ_AVAILABLE" -eq 1 ]]; then
    asset_name=$(jq -r '.assets[] | select(.name | endswith(".zip")) | .name' \
                 "$tmp_json" | head -1)
    download_url=$(jq -r ".assets[] | select(.name == \"$asset_name\") | .browser_download_url" \
                   "$tmp_json")
  else
    asset_name=$(grep -o '"name"\s*:\s*"[^"]*\.zip"' "$tmp_json" | head -1 \
                 | sed -E 's/.*"([^"]+)".*/\1/')
    download_url=$(grep -A5 "\"name\": \"$asset_name\"" "$tmp_json" \
                   | grep -o '"browser_download_url"\s*:\s*"[^"]*"' | head -1 \
                   | sed -E 's/.*"([^"]+)".*/\1/')
  fi
  rm -f "$tmp_json"

  if [[ -z "$asset_name" || "$asset_name" == "null" ]]; then
    echo -e "${RED}❌ No ZIP asset found in release ${tag}.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Asset: ${asset_name}${NC}"

  tmp_dir=$(mktemp -d)
  tmp_zip="${tmp_dir}/${asset_name}"

  echo -e "${BLUE}📥 Downloading ${asset_name}...${NC}"
  if ! curl -L --fail --progress-bar -o "$tmp_zip" "$download_url"; then
    echo -e "${RED}❌ Download failed.${NC}"
    rm -rf "$tmp_dir"; exit 1
  fi

  install_from_zip "$tmp_zip"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_dependencies
  try_direct_download || try_api_download
  echo -e "${GREEN}🎉 Installation complete!${NC}"
  echo -e "${BLUE}   Vet is in your Applications folder.${NC}"
  echo ""
}

main "$@"
