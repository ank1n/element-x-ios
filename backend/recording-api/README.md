# Recording API

REST API для управления записью звонков через LiveKit Egress.

## API Endpoints

### Health Check
```
GET /health
```

### Start Recording
```
POST /api/recording/start
Content-Type: application/json

{
  "roomName": "your-room-name",
  "layout": "grid-dark"  // optional, default: "grid-dark"
}

Response:
{
  "success": true,
  "egressId": "EG_xxx",
  "status": 0,
  "roomName": "your-room-name",
  "filepath": "recordings/your-room-name_1234567890.mp4"
}
```

### Stop Recording
```
POST /api/recording/stop
Content-Type: application/json

{
  "egressId": "EG_xxx"
}

Response:
{
  "success": true,
  "egressId": "EG_xxx",
  "status": 2
}
```

### Get Recording Status
```
GET /api/recording/status/:egressId

Response:
{
  "success": true,
  "egress": {
    "egressId": "EG_xxx",
    "roomName": "your-room-name",
    "status": 1,
    "startedAt": "...",
    "endedAt": null
  }
}
```

### List Recordings
```
GET /api/recording/list?roomName=optional-filter

Response:
{
  "success": true,
  "recordings": [...]
}
```

## Local Development

```bash
# Install dependencies
npm install

# Run with default config
npm start

# Run with watch mode
npm run dev

# With custom config
LIVEKIT_URL=wss://your-livekit.com \
LIVEKIT_API_KEY=your-key \
LIVEKIT_API_SECRET=your-secret \
npm start
```

## Deployment

### Build and Deploy
```bash
# Build locally and deploy
./deploy.sh all

# Or step by step
./deploy.sh build
./deploy.sh deploy

# With remote registry
REGISTRY=your-registry.com/repo IMAGE_TAG=v1.0.0 ./deploy.sh all
```

### Manual Kubernetes Deployment
```bash
# Apply all resources
kubectl apply -k k8s/

# Check status
kubectl get pods -n livekit -l app=recording-api
kubectl logs -n livekit -l app=recording-api
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| PORT | Server port | 3000 |
| LIVEKIT_URL | LiveKit server URL | wss://livekit.market.implica.ru |
| LIVEKIT_API_KEY | LiveKit API key | devkey |
| LIVEKIT_API_SECRET | LiveKit API secret | (see secret.yaml) |
| S3_ENDPOINT | MinIO/S3 endpoint | http://minio.minio.svc.cluster.local:9000 |
| S3_ACCESS_KEY | S3 access key | minioadmin |
| S3_SECRET_KEY | S3 secret key | (see secret.yaml) |
| S3_BUCKET | S3 bucket name | livekit-recordings |

## Testing

```bash
# Health check
curl https://api.market.implica.ru/health

# Start recording
curl -X POST https://api.market.implica.ru/api/recording/start \
  -H "Content-Type: application/json" \
  -d '{"roomName": "test-room"}'

# Stop recording
curl -X POST https://api.market.implica.ru/api/recording/stop \
  -H "Content-Type: application/json" \
  -d '{"egressId": "EG_xxx"}'

# List recordings
curl https://api.market.implica.ru/api/recording/list
```
