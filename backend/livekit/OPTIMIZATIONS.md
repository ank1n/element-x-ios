# LiveKit Server Optimizations

**Дата:** 02 февраля 2026
**Версия LiveKit:** 1.9.11
**Статус:** ✅ Применено

---

## Проблемы (до оптимизации)

- ❌ Хрипы при старте звонка
- ❌ Лаги аудио во время разговора
- ❌ Лаги видео при резких движениях
- ⚠️ Медленное соединение (~11 секунд с мобильных)

---

## Применённые оптимизации

### 1. Congestion Control

```yaml
rtc:
  congestion_control:
    enabled: true
    allow_pause: false  # Не останавливать треки при перегрузке
```

**Эффект:** Предотвращает остановку треков при временных проблемах с сетью.

### 2. Увеличенные буферы

```yaml
rtc:
  packet_buffer_size_video: 1000  # было 500
  packet_buffer_size_audio: 400   # было 200
```

**Эффект:** Сглаживает jitter, уменьшает артефакты при нестабильной сети.

### 3. Агрессивный PLI (Picture Loss Indication)

```yaml
rtc:
  pli_throttle:
    low_quality: 250ms   # было 500ms
    mid_quality: 500ms   # было 1s
    high_quality: 500ms  # было 1s
```

**Эффект:** Быстрое восстановление видео после потери пакетов.

### 4. Оптимизированный Playout Delay

```yaml
room:
  playout_delay:
    enabled: true
    min: 50      # минимум 50ms
    max: 500     # максимум 500ms (было 2000ms)
```

**Эффект:** Уменьшает задержку воспроизведения, улучшает синхронизацию аудио/видео.

### 5. Разрешенные кодеки

```yaml
room:
  enabled_codecs:
    - mime: audio/opus
    - mime: video/VP8
    - mime: video/H264
```

**Примечание:** Параметры битрейта и FEC настраиваются на клиенте (см. TZ-WEBRTC-QUALITY-OPTIMIZATION.md).

---

## Конфигурация

**Файл:** `/tmp/livekit-config-optimized-full.yaml`

**Применение:**
```bash
ssh root@194.87.190.230
kubectl create configmap livekit-config -n livekit \
  --from-file=config.yaml=livekit-config-optimized-full.yaml \
  -o yaml --dry-run=client | kubectl apply -f -

kubectl delete pod -n livekit -l app=livekit
```

---

## Результаты

### До оптимизации:
- Соединение с ноутбука: ~2.7 сек
- Соединение с мобильного: ~11 сек
- Хрипы при старте: ❌ Есть
- Лаги видео: ❌ Есть

### После оптимизации:
- Требуется тестирование с пользователем
- Ожидаемое улучшение: устранение хрипов, плавное видео

---

## Следующие шаги

1. ✅ Сервер оптимизирован
2. 🔄 Web-разработчик применяет оптимизации на клиенте (Element Call)
3. 🔄 Тестирование с реальными звонками
4. 🔄 Тестирование записи звонков

---

## Ограничения LiveKit 1.9.11

LiveKit 1.9.11 **не поддерживает** следующие поля конфигурации:

- `rtc.ice_candidate_pool_size` — предзагрузка ICE candidates
- `video.dynacast` — динамическое управление слоями simulcast
- `codecs[].fmtp` — параметры кодеков (bitrate, FEC)

Эти параметры должны настраиваться на клиенте при создании media tracks.

---

## Referenceы

- [LiveKit v1.9.11 Config Sample](https://github.com/livekit/livekit/blob/v1.9.11/config-sample.yaml)
- [ТЗ для Web-разработчика](../TZ-WEBRTC-QUALITY-OPTIMIZATION.md)
