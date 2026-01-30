делай план изменений что мы провели
записывай изменения в функционале как новые ппункты плана изменений и добаляй ссылку на коммит в коде который нужно применять для того чтобы изменения функциональные применять для новой версии исходников element x в случаи их обновления

## Git репозиторий

Форк проекта: https://github.com/ank1n/element-x-ios

При выполнении минорных и мажорных изменений — пушить в репозиторий:
```bash
cd /Users/ankin/Documents/element-x-fork/ios
git add -A
git commit --no-verify -m "описание изменений"
git push origin develop
```

Remotes:
- origin: https://github.com/ank1n/element-x-ios.git (форк)
- upstream: https://github.com/element-hq/element-x-ios.git (оригинал)
