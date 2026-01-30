#!/bin/bash
set -e

# Recording API Deployment Script
# Usage: ./deploy.sh [build|deploy|all]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="recording-api"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# For remote deployment, set REGISTRY variable
# Example: REGISTRY=your-registry.com/your-repo ./deploy.sh all
REGISTRY="${REGISTRY:-}"

if [ -n "$REGISTRY" ]; then
    FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
else
    FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
fi

build() {
    echo "Building Docker image: ${FULL_IMAGE}"
    docker build -t "${FULL_IMAGE}" "${SCRIPT_DIR}"

    if [ -n "$REGISTRY" ]; then
        echo "Pushing image to registry..."
        docker push "${FULL_IMAGE}"
    fi
}

deploy() {
    echo "Deploying to Kubernetes..."

    # Update image in deployment if using registry
    if [ -n "$REGISTRY" ]; then
        kubectl set image deployment/recording-api \
            recording-api="${FULL_IMAGE}" \
            -n livekit --record || true
    fi

    # Apply all manifests
    kubectl apply -k "${SCRIPT_DIR}/k8s"

    echo "Waiting for deployment to be ready..."
    kubectl rollout status deployment/recording-api -n livekit --timeout=120s

    echo "Deployment complete!"
    kubectl get pods -n livekit -l app=recording-api
}

case "${1:-all}" in
    build)
        build
        ;;
    deploy)
        deploy
        ;;
    all)
        build
        deploy
        ;;
    *)
        echo "Usage: $0 [build|deploy|all]"
        exit 1
        ;;
esac
