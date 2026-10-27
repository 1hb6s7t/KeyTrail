/* Only versioned static shell assets are cached. API/credentials/statistics never enter CacheStorage. */
const CACHE='keytrail-shell-v1.2.8';const ASSETS=['/','/style.css','/app.js','/metrics.js','/text.js','/csv.js','/manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(ASSETS))));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(k=>k.startsWith('keytrail-shell-')&&k!==CACHE).map(k=>caches.delete(k))))));
self.addEventListener('fetch',event=>{const url=new URL(event.request.url);if(event.request.method==='GET'&&url.origin===location.origin&&ASSETS.includes(url.pathname)&&!url.search){event.respondWith(fetch(event.request).then(response=>{if(response.ok){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(event.request,copy));}return response;}).catch(()=>caches.match(event.request)));}});
