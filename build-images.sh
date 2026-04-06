#!/usr/bin/env bash
set -e

# ANSI Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Help message
show_help() {
    echo -e "${BLUE}Usage: $0 [TARGET] [TAG]${NC}"
    echo
    echo "Targets:"
    echo "  all      - Build all images (default)"
    echo "  rust     - Build rust-claude and rust-claude-pipeline"
    echo "  general  - Build general-claude-base and general-claude-pipeline"
    echo
    echo "Arguments:"
    echo "  TAG      - Optional image tag (default: latest)"
    echo
    echo "Examples:"
    echo "  $0                  # Build all images with 'latest' tag"
    echo "  $0 rust             # Build rust images with 'latest' tag"
    echo "  $0 general v1.0.0   # Build general images with 'v1.0.0' tag"
    exit 0
}

# Parse args
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    show_help
fi

TARGET=${1:-all}
TAG=${2:-latest}

# Move to script directory
cd "$(dirname "$0")"

build_rust() {
    echo -e "\n${BLUE}=== Building Rust Images ===${NC}"
    
    echo -e "${YELLOW}1/2: Building rust-claude:${TAG}...${NC}"
    docker build -t "rust-claude:$TAG" -f agent/Dockerfile.rust-base ./agent/
    
    echo -e "${YELLOW}2/2: Building rust-claude-pipeline:${TAG}...${NC}"
    docker build -t "rust-claude-pipeline:$TAG" -f agent/Dockerfile.rust-agent ./agent/
}

build_general() {
    echo -e "\n${BLUE}=== Building General Images ===${NC}"
    
    echo -e "${YELLOW}1/2: Building general-claude-base:${TAG}...${NC}"
    docker build -t "general-claude-base:$TAG" -f agent/Dockerfile.general-base ./agent/
    
    echo -e "${YELLOW}2/2: Building general-claude-pipeline:${TAG}...${NC}"
    docker build -t "general-claude-pipeline:$TAG" -f agent/Dockerfile.general-agent ./agent/
}

echo -e "${GREEN}Starting build for target: ${TARGET}, tag: ${TAG}${NC}"

case "$TARGET" in
    all)
        build_rust
        build_general
        ;;
    rust)
        build_rust
        ;;
    general)
        build_general
        ;;
    *)
        echo -e "${RED}Error: Unknown target '$TARGET'${NC}"
        show_help
        ;;
esac

echo -e "\n${GREEN}✅ Success! All requested images have been built and tagged with '${TAG}'.${NC}"
echo "Local images available:"
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' | grep -E "rust-claude|general-claude"
