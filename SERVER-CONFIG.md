# Server Configuration Reference

## Сервер

- **Host**: ozzy.implica.ru
- **IP**: 194.87.190.230
- **SSH**: `ssh root@ozzy.implica.ru`

## Kubernetes Namespaces

| Namespace | Компоненты |
|-----------|------------|
| matrix | synapse, element, postgres, dimension, stats-widget |
| keycloak | keycloak, keycloak-postgres |
| livekit | livekit, lk-jwt-service, egress, redis |
| minio | minio |

## Домены

| URL | Namespace | Сервис |
|-----|-----------|--------|
| https://market.implica.ru | matrix | Element + Synapse |
| https://auth.market.implica.ru | keycloak | Keycloak SSO |
| https://stats.market.implica.ru | matrix | Stats Widget |
| https://livekit.market.implica.ru | livekit | LiveKit WebRTC |
| https://jwt.market.implica.ru | livekit | JWT Service |
| https://api.market.implica.ru | livekit | Recording API (новый) |

## LiveKit Configuration

### LiveKit Server
```yaml
# ConfigMap: livekit-config
keys:
  devkey: secret123456789012345678901234567890
port: 7880
rtc:
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true
turn:
  enabled: true
  domain: livekit.market.implica.ru
  tls_port: 5349
  udp_port: 3478
```

### Egress Service
```yaml
# ConfigMap: egress-config
api_key: devkey
api_secret: secret123456789012345678901234567890
ws_url: ws://livekit.livekit.svc.cluster.local:7880
redis:
  address: redis.livekit.svc.cluster.local:6379
s3:
  access_key: minioadmin
  secret: MinioAdmin2026!
  endpoint: http://minio.minio.svc.cluster.local:9000
  bucket: livekit-recordings
  force_path_style: true
```

## Matrix Widget State Events

### Тип события: `m.widget` или `im.vector.modular.widgets`

```json
{
  "type": "im.vector.modular.widgets",
  "state_key": "widget_unique_id",
  "content": {
    "type": "customwidget",
    "name": "Stats Widget",
    "url": "https://stats.market.implica.ru/?roomId=$matrix_room_id&userId=$matrix_user_id",
    "creatorUserId": "@admin:market.implica.ru",
    "waitForIframeLoad": true,
    "data": {}
  }
}
```

### URL Template Variables

| Variable | Description |
|----------|-------------|
| `$matrix_room_id` | ID комнаты (e.g., !abc123:market.implica.ru) |
| `$matrix_user_id` | ID пользователя (e.g., @user:market.implica.ru) |
| `$matrix_display_name` | Display name пользователя |
| `$matrix_avatar_url` | URL аватара |

## Keycloak SSO

```
Realm: matrix
Client ID: synapse
Client Secret: gjeuiMPwfejOHQax9WJmJvp32rE5RnF5
OIDC Issuer: https://auth.market.implica.ru/realms/matrix
```

## Полезные команды

```bash
# Проверить pods
kubectl get pods -n matrix
kubectl get pods -n livekit
kubectl get pods -n minio

# Логи
kubectl logs -n livekit -l app=egress --tail=50
kubectl logs -n livekit -l app=livekit --tail=50

# Рестарт
kubectl rollout restart deployment/egress -n livekit

# Проверить записи в MinIO
kubectl exec -n minio deploy/minio -- ls -la /data/livekit-recordings/recordings/

# Скачать запись
kubectl cp minio/minio-xxx:/data/livekit-recordings/recordings/file.mp4 ./file.mp4
```

## Recording Script (на сервере)

```bash
/root/track-recording.sh list      # Показать комнаты и записи
/root/track-recording.sh start     # Начать запись
/root/track-recording.sh stop      # Остановить запись
```
