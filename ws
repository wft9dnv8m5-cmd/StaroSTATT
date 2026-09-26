/*
 * StaroSTATT — service worker с самоочисткой кеша.
 *
 * Как это работает:
 * 1. CACHE_NAME содержит номер версии. При каждом деплое сайта меняйте
 *    этот номер (например, 'starostatt-v3') — это единственное, что нужно
 *    сделать, чтобы включить самоочистку для новой версии.
 * 2. При активации новой версии (activate) worker сам находит и удаляет
 *    ВСЕ старые кеши сайта — вручную чистить ничего не нужно, сайт
 *    никогда не "разбухнет" от старых файлов и не зависнет из-за них.
 * 3. Этот кеш хранит только статические файлы (HTML/CSS/JS/иконки).
 *    Данные журнала (список группы, посещаемость, заметки) лежат в
 *    localStorage и в Firestore — это два ДРУГИХ хранилища браузера,
 *    и данный service worker их никогда не касается и не удаляет.
 *    Поэтому кеш можно чистить сколько угодно агрессивно — информация
 *    старосты всегда остаётся цела.
 */

const CACHE_NAME = 'starostatt-v2';

// Основной "каркас" сайта, который стоит держать под рукой офлайн.
// Если какого-то файла нет на сервере — это не страшно, кеш просто
// пропустит его без ошибок.
const CORE_ASSETS = [
  './',
  './index.html',
  './manifest.json',
  './icon.svg'
];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return Promise.all(
        CORE_ASSETS.map((url) =>
          cache.add(url).catch(() => {
            /* файла может не быть — это нормально, продолжаем */
          })
        )
      );
    })
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      // Самоочистка: удаляем абсолютно все кеши, кроме текущей версии.
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((name) => name !== CACHE_NAME)
          .map((name) => caches.delete(name))
      );
      await self.clients.claim();
    })()
  );
});

// Позволяет странице попросить новую версию активироваться немедленно,
// без ожидания закрытия всех вкладок.
self.addEventListener('message', (event) => {
  if (event.data === 'skipWaiting') self.skipWaiting();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);
  const isSameOrigin = url.origin === self.location.origin;
  const isHTML = req.mode === 'navigate' || req.headers.get('accept')?.includes('text/html');

  if (isSameOrigin && isHTML) {
    // HTML-страницы: сначала сеть (чтобы всегда видеть свежую версию сайта),
    // а если сети нет — отдаём то, что успели закешировать.
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req).then((res) => res || caches.match('./index.html')))
    );
    return;
  }

  if (isSameOrigin) {
    // Статика (css/js/иконки): сначала кеш — быстрее открывается,
    // в фоне тихо обновляем кеш свежей копией с сервера.
    event.respondWith(
      caches.match(req).then((cached) => {
        const network = fetch(req)
          .then((res) => {
            if (res && res.ok) {
              const copy = res.clone();
              caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
            }
            return res;
          })
          .catch(() => cached);
        return cached || network;
      })
    );
  }
  // Внешние ресурсы (шрифты, Firebase, видео) — не трогаем, идут напрямую в сеть.
});
