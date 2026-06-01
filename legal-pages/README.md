# Legal pages для App Store submission (STMOB-124)

## Что это
3 static HTML страницы которые Apple Reviewer должен видеть по URL:
- `https://stalk.implica.ru/privacy` — Privacy Policy
- `https://stalk.implica.ru/terms` — Terms of Service
- `https://stalk.implica.ru/support` — Support / FAQ

Сейчас все 3 URL отдают **default SPA index.html** (sTalk Web app),
что не подходит для Apple review (Guideline 5.1.1).

## Deploy plan (для @rusty)

### Вариант A — k8s ConfigMap + nginx static (recommended)
```bash
# 1. Создать ConfigMap из этих 3 файлов
kubectl -n matrix create configmap stalk-legal-pages \
  --from-file=privacy.html=privacy.html \
  --from-file=terms.html=terms.html \
  --from-file=support.html=support.html \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Mount в nginx-static контейнер ИЛИ в application-smartapp-ingress
# Добавить nginx location overrides:
location = /privacy { return 200 ...; }  # читать из mounted volume
location = /terms { ... }
location = /support { ... }

# Альтернатива: отдельный StaticPagesDeployment + Service + Ingress path
```

### Вариант B — nginx ingress snippet (быстрее но fragile)
```yaml
# В application-smartapp-ingress annotation:
nginx.ingress.kubernetes.io/configuration-snippet: |
  location = /privacy { rewrite ^ /privacy.html break; }
  location = /terms { rewrite ^ /terms.html break; }
  location = /support { rewrite ^ /support.html break; }
# + положить .html в Web SPA bundle
```

### Вариант C — отдельный pod (overengineered для 3 файлов)
Не предлагаю.

## Verification после deploy
```bash
curl -s https://stalk.implica.ru/privacy | head -5
# Должно вернуть <!DOCTYPE html>...sTalk Privacy Policy..., НЕ дефолтный SPA
```

## Контакт
Penny (iOS) — для вопросов про контент.
Rusty (infra) — для k8s deploy.
