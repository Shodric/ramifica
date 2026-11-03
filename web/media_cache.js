// Runtime media caching shared by the release and development workers.
// Cache keys include the complete URL, including signed query parameters.
(function () {
  const cacheNames = {
    image: "ramifica-images-v2",
    audio: "ramifica-audio-v2",
    video: "ramifica-video-v2",
  };
  const limits = { image: 300, audio: 100, video: 30 };
  const metadataName = "ramifica-media-metadata-v2";
  const maxAge = 30 * 24 * 60 * 60 * 1000;
  const mutableAge = 60 * 60 * 1000;
  const pending = new Map();
  const finalizing = new Map();
  const completed = new Set();
  const chunkSize = 512 * 1024;
  let database;

  function mediaType(request, url) {
    const path = url.pathname.toLowerCase();
    if (/\.(?:png|jpe?g|webp|gif|avif|svg|bmp|ico)$/.test(path)) return "image";
    if (/\.(?:m4a|mp3|wav|ogg|opus|aac|flac)$/.test(path)) return "audio";
    if (/\.(?:mp4|webm|mov|m4v|ogv)$/.test(path)) return "video";
    return ["image", "audio", "video"].includes(request.destination)
      ? request.destination : null;
  }

  function mayHandle(request, url) {
    if (request.method !== "GET" || request.mode === "navigate" ||
        request.cache === "no-store" ||
        (request.credentials === "include" && request.mode !== "no-cors") ||
        request.headers.has("authorization")) return false;
    if (url.protocol !== "https:" && url.protocol !== "http:") return false;
    const host = url.hostname.toLowerCase();
    if (host.endsWith("cloudfunctions.net") ||
        host.endsWith("cloudfunctions.googleapis.com") ||
        (host.endsWith(".googleapis.com") &&
          host !== "storage.googleapis.com" &&
          host !== "firebasestorage.googleapis.com")) return false;
    if (url.origin === self.location.origin && url.pathname.startsWith("/__/")) {
      return false;
    }
    const type = mediaType(request, url);
    // CanvasKit and Web Audio use fetch(), whose destination is empty. For
    // extensionless cross-origin URLs, inspect the response's content type.
    return type !== null ||
      (request.destination === "" && url.origin !== self.location.origin);
  }

  function typeFromResponse(response) {
    const contentType = (response.headers.get("content-type") || "").toLowerCase();
    if (contentType.startsWith("image/")) return "image";
    if (contentType.startsWith("audio/")) return "audio";
    if (contentType.startsWith("video/")) return "video";
    return null;
  }

  function canStore(response, type) {
    // Opaque images can still be displayed. Audio/video must be readable so
    // a cached 200 response can safely answer future Range requests.
    if (response.type === "opaque") return type === "image";
    if (response.status !== 200) return false;
    if (/\bno-store\b/i.test(response.headers.get("cache-control") || "")) {
      return false;
    }
    const actualType = typeFromResponse(response);
    if (actualType !== null) return actualType === type ||
      (type === "video" && actualType === "audio");
    const contentType = (response.headers.get("content-type") || "").toLowerCase();
    return contentType === "" || contentType.startsWith("application/octet-stream");
  }

  async function trim(cache, type) {
    const keys = await cache.keys();
    const excess = keys.length - limits[type];
    if (excess <= 0) return;
    const metadata = await caches.open(metadataName);
    for (const key of keys.slice(0, excess)) {
      await cache.delete(key);
      await metadata.delete(key);
      completed.delete(key.url);
    }
  }

  async function store(url, type, response) {
    if (!canStore(response, type)) return false;
    try {
      const cache = await caches.open(cacheNames[type]);
      try {
        await cache.put(url, response.clone());
      } catch (error) {
        // A full device should still play from the network. Free older media
        // and retry once; never let a cache failure break a media request.
        if (error.name !== "QuotaExceededError") return false;
        const keys = await cache.keys();
        const metadata = await caches.open(metadataName);
        for (const key of keys.slice(0, Math.max(1, Math.ceil(keys.length / 4)))) {
          await cache.delete(key);
          await metadata.delete(key);
          completed.delete(key.url);
        }
        await cache.put(url, response.clone());
      }
      const metadata = await caches.open(metadataName);
      await metadata.put(url, new Response(String(Date.now())));
      await trim(cache, type);
      return true;
    } catch (_) {
      // Storage can be unavailable or cleared at any time by the browser.
      return false;
    }
  }

  async function cached(url, type) {
    const types = type ? [type] : ["image", "audio", "video"];
    for (const candidate of types) {
      const cache = await caches.open(cacheNames[candidate]);
      const response = await cache.match(url);
      if (response) return { response, type: candidate };
    }
    // Entries can be evicted by the browser or by our size limit while the
    // worker is still running; allow a later download to be saved again.
    completed.delete(url);
    return null;
  }

  async function shouldRefresh(url, type) {
    const metadata = await caches.open(metadataName);
    const entry = await metadata.match(url);
    const storedAt = entry ? Number(await entry.text()) : 0;
    const path = new URL(url).pathname;
    // Generated files include their content hash in the filename. Other URLs
    // (notably profile photos) may change without their URL changing.
    const immutable = /-[a-f0-9]{8,}(?:-[^/]*)?\.[a-z0-9]+$/i.test(path);
    return !storedAt || Date.now() - storedAt > (immutable ? maxAge : mutableAge);
  }

  function refresh(url, type) {
    const key = type + " " + url;
    if (pending.has(key)) return pending.get(key);
    const task = (async function () {
      try {
        // A full CORS response is needed to serve byte ranges. Signed URLs
        // carry their authorization in the URL; cookies are not forwarded.
        const response = await fetch(url, { mode: "cors", credentials: "omit" });
        await store(url, type, response);
      } catch (_) {
        // CORS, a revoked URL, offline mode, or a quota failure: playback
        // continues through the original network request.
      } finally {
        pending.delete(key);
      }
    })();
    pending.set(key, task);
    return task;
  }

  function openParts() {
    if (database) return database;
    database = new Promise(function (resolve, reject) {
      const request = indexedDB.open("ramifica-media-parts-v1", 1);
      request.onupgradeneeded = function () {
        const db = request.result;
        db.createObjectStore("entries", { keyPath: "url" });
        const chunks = db.createObjectStore("chunks", { keyPath: ["url", "start"] });
        chunks.createIndex("url", "url");
      };
      request.onsuccess = function () { resolve(request.result); };
      request.onerror = function () { reject(request.error); };
      request.onblocked = function () { reject(new Error("Media cache is blocked")); };
    }).catch(function (error) {
      database = null;
      throw error;
    });
    return database;
  }

  function transactionDone(transaction) {
    return new Promise(function (resolve, reject) {
      transaction.oncomplete = function () { resolve(); };
      transaction.onerror = function () { reject(transaction.error); };
      transaction.onabort = function () { reject(transaction.error); };
    });
  }

  function readRequest(request) {
    return new Promise(function (resolve, reject) {
      request.onsuccess = function () { resolve(request.result); };
      request.onerror = function () { reject(request.error); };
    });
  }

  async function deleteParts(url) {
    const db = await openParts();
    const transaction = db.transaction(["entries", "chunks"], "readwrite");
    transaction.objectStore("entries").delete(url);
    const cursor = transaction.objectStore("chunks").index("url")
      .openKeyCursor(IDBKeyRange.only(url));
    cursor.onsuccess = function () {
      if (!cursor.result) return;
      transaction.objectStore("chunks").delete(cursor.result.primaryKey);
      cursor.result.continue();
    };
    await transactionDone(transaction);
  }

  async function prepareParts(url, type, total, validator, contentType) {
    if (completed.has(url)) return;
    const db = await openParts();
    const read = db.transaction("entries", "readonly");
    const previous = await readRequest(read.objectStore("entries").get(url));
    if (previous && ((total !== null && previous.total !== null &&
        previous.total !== total) ||
        ((validator || previous.validator) && previous.validator !== validator) ||
        Date.now() - previous.updatedAt > mutableAge)) {
      await deleteParts(url);
    }
    const transaction = db.transaction("entries", "readwrite");
    transaction.objectStore("entries").put({
      url, type, total, validator, contentType, updatedAt: Date.now(),
    });
    await transactionDone(transaction);
    // Incomplete downloads also consume quota. Keep only a bounded number and
    // remove abandoned entries, without downloading anything to fill them.
    const list = db.transaction("entries", "readonly");
    const entries = await readRequest(list.objectStore("entries").getAll());
    const expired = new Set();
    for (const entry of entries) {
      if (entry.url !== url && Date.now() - entry.updatedAt > mutableAge) {
        await deleteParts(entry.url);
        expired.add(entry.url);
      }
    }
    const sameType = entries.filter(function (entry) {
      return entry.type === type && !expired.has(entry.url);
    })
      .sort(function (a, b) { return b.updatedAt - a.updatedAt; });
    for (const entry of sameType.slice(limits[type])) {
      if (entry.url !== url) await deleteParts(entry.url);
    }
  }

  async function savePart(url, start, data, type, total, validator) {
    if (completed.has(url)) return;
    const db = await openParts();
    const transaction = db.transaction(["entries", "chunks"], "readwrite");
    const chunks = transaction.objectStore("chunks");
    const entry = transaction.objectStore("entries").get(url);
    entry.onsuccess = function () {
      const current = entry.result;
      if (!current || current.type !== type ||
          (total !== null && current.total !== null && total !== current.total) ||
          ((validator || current.validator) && current.validator !== validator)) {
        return;
      }
      current.updatedAt = Date.now();
      transaction.objectStore("entries").put(current);
      const existing = chunks.get([url, start]);
      existing.onsuccess = function () {
        if (!existing.result || existing.result.data.size < data.size) {
          chunks.put({ url, start, data });
        }
      };
    };
    await transactionDone(transaction);
  }

  function finishParts(url) {
    const previous = finalizing.get(url) || Promise.resolve();
    const task = previous.catch(function () {}).then(async function () {
      const db = await openParts();
      const transaction = db.transaction(["entries", "chunks"], "readonly");
      const entryPromise = readRequest(transaction.objectStore("entries").get(url));
      const chunksPromise = readRequest(transaction.objectStore("chunks")
        .index("url").getAll(IDBKeyRange.only(url)));
      const [entry, chunks] = await Promise.all([entryPromise, chunksPromise]);
      if (!entry || !Number.isSafeInteger(entry.total) || entry.total <= 0) return;
      chunks.sort(function (a, b) { return a.start - b.start; });
      const pieces = [];
      let offset = 0;
      for (const chunk of chunks) {
        if (chunk.start > offset) return;
        const skip = offset - chunk.start;
        if (skip >= chunk.data.size) continue;
        const take = Math.min(chunk.data.size - skip, entry.total - offset);
        pieces.push(chunk.data.slice(skip, skip + take));
        offset += take;
        if (offset === entry.total) break;
      }
      if (offset !== entry.total) return;
      const check = db.transaction("entries", "readonly");
      const current = await readRequest(check.objectStore("entries").get(url));
      if (!current || current.total !== entry.total ||
          current.validator !== entry.validator || current.type !== entry.type) return;
      const headers = new Headers({
        "Content-Type": entry.contentType || "application/octet-stream",
        "Content-Length": String(entry.total),
        "Accept-Ranges": "bytes",
      });
      const saved = await store(
        url, entry.type, new Response(new Blob(pieces), { headers }),
      );
      if (saved) {
        completed.add(url);
        await deleteParts(url);
      }
    }).catch(function () {});
    finalizing.set(url, task);
    task.finally(function () {
      if (finalizing.get(url) === task) finalizing.delete(url);
    });
    return task;
  }

  function capture(response, url, type, background) {
    if (!response.body || response.type === "opaque" ||
        ![200, 206].includes(response.status) ||
        /\bno-store\b/i.test(response.headers.get("cache-control") || "")) {
      return response;
    }
    const actualType = typeFromResponse(response);
    if (actualType && actualType !== type &&
        !(type === "video" && actualType === "audio")) return response;
    const headerType = (response.headers.get("content-type") || "").toLowerCase();
    if (!actualType && headerType &&
        !headerType.startsWith("application/octet-stream")) return response;
    const contentRange = response.headers.get("content-range");
    const range = contentRange && /^bytes (\d+)-(\d+)\/(\d+)$/i.exec(contentRange);
    if (response.status === 206 && !range) return response;
    const start = range ? Number(range[1]) : 0;
    const rangeEnd = range ? Number(range[2]) : null;
    const length = Number(response.headers.get("content-length"));
    const total = range ? Number(range[3]) : (length > 0 ? length : null);
    if (!Number.isSafeInteger(start) ||
        (total !== null && (!Number.isSafeInteger(total) || start >= total)) ||
        (rangeEnd !== null && (!Number.isSafeInteger(rangeEnd) ||
          rangeEnd < start || rangeEnd >= total))) {
      return response;
    }
    const contentType = response.headers.get("content-type") || "";
    const validator = response.headers.get("etag") ||
      response.headers.get("last-modified") || "";
    const ready = prepareParts(url, type, total, validator, contentType)
      .catch(function () {});
    const reader = response.body.getReader();
    let offset = start;
    let buffered = [];
    let bufferedSize = 0;
    let done;
    let ended = false;
    const finished = new Promise(function (resolve) { done = resolve; });
    background.push(finished);

    async function flush() {
      if (!bufferedSize) return;
      const data = new Blob(buffered);
      const position = offset;
      offset += bufferedSize;
      buffered = [];
      bufferedSize = 0;
      try {
        await ready;
        await savePart(url, position, data, type, total, validator);
      } catch (_) {
        // Quota and IndexedDB failures must not interrupt playback.
      }
    }

    async function finish(complete) {
      if (ended) return;
      ended = true;
      try {
        await flush();
        if (complete && total === null && response.status === 200) {
          try {
            await prepareParts(url, type, offset, validator, contentType);
          } catch (_) {}
        }
        await finishParts(url);
      } finally {
        done();
      }
    }

    const stream = new ReadableStream({
      async pull(controller) {
        try {
          const result = await reader.read();
          if (result.done) {
            controller.close();
            await finish(true);
            return;
          }
          buffered.push(result.value);
          bufferedSize += result.value.byteLength;
          controller.enqueue(result.value);
          if (bufferedSize >= chunkSize) await flush();
        } catch (error) {
          try { controller.error(error); } catch (_) {}
          await finish(false);
        }
      },
      async cancel(reason) {
        try { await reader.cancel(reason); } catch (_) {}
        await finish(false);
      },
    });
    return new Response(stream, {
      status: response.status,
      statusText: response.statusText,
      headers: response.headers,
    });
  }

  async function partial(response, range) {
    const match = /^bytes=(\d*)-(\d*)$/i.exec(range.trim());
    if (!match || (!match[1] && !match[2]) || response.type === "opaque") {
      return null;
    }
    const blob = await response.blob();
    const size = blob.size;
    let start;
    let end;
    if (!match[1]) {
      const suffix = Number(match[2]);
      if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
      start = Math.max(size - suffix, 0);
      end = size - 1;
    } else {
      start = Number(match[1]);
      end = match[2] ? Number(match[2]) : size - 1;
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end)) return null;
      end = Math.min(end, size - 1);
    }
    if (start >= size || start > end) {
      return new Response(null, {
        status: 416,
        headers: { "Content-Range": "bytes */" + size },
      });
    }
    const headers = new Headers(response.headers);
    headers.set("Accept-Ranges", "bytes");
    headers.set("Content-Length", String(end - start + 1));
    headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
    return new Response(blob.slice(start, end + 1), {
      status: 206,
      statusText: "Partial Content",
      headers,
    });
  }

  async function respond(request, type, background) {
    const url = request.url;
    const range = request.headers.get("range");
    let hit = null;
    try {
      hit = await cached(url, type);
    } catch (_) {
      // Private browsing or storage restrictions must not block playback.
    }
    let stale = false;
    if (hit) stale = await shouldRefresh(url, hit.type).catch(() => false);
    if (hit && !(range && request.headers.has("if-range")) &&
        !(stale && hit.type !== "image")) {
      if (range) {
        try {
          const response = await partial(hit.response.clone(), range);
          if (response) {
            if (stale && hit.type === "image") {
              background.push(refresh(url, hit.type));
            }
            return response;
          }
        } catch (_) {
          // Fall back to the server for malformed or unreadable ranges.
        }
      } else {
        if (stale && hit.type === "image") {
          background.push(refresh(url, hit.type));
        }
        return hit.response;
      }
    }

    let response;
    try {
      if ((type === "audio" || type === "video") &&
          request.mode === "no-cors" && !request.headers.has("if-range")) {
        // Media elements default to no-CORS. Ask for the same byte range
        // anonymously so its bytes can be saved as they are consumed.
        try {
          const headers = new Headers();
          if (range) headers.set("Range", range);
          response = await fetch(url, { mode: "cors", credentials: "omit", headers });
          if (!response.ok) response = await fetch(request);
        } catch (_) {
          response = await fetch(request);
        }
      } else {
        response = await fetch(request);
      }
    } catch (error) {
      if (!hit) throw error;
      if (!range) return hit.response;
      const fallback = await partial(hit.response.clone(), range);
      if (fallback) return fallback;
      throw error;
    }
    if (hit && stale && response.status >= 500) {
      if (!range) return hit.response;
      const fallback = await partial(hit.response.clone(), range);
      if (fallback) return fallback;
    }
    const actualType = type || typeFromResponse(response);
    if (hit && stale && hit.type !== "image" && response.ok) {
      try {
        completed.delete(url);
        await (await caches.open(cacheNames[hit.type])).delete(url);
        await (await caches.open(metadataName)).delete(url);
        await deleteParts(url);
      } catch (_) {}
    }
    if (actualType === "audio" || actualType === "video") {
      return capture(response, url, actualType, background);
    }
    if (!range && actualType === "image") {
      // Media elements default to credentialed no-CORS requests. Cache an
      // anonymous readable copy instead of persisting a cookie-bound response.
      if (request.credentials === "include") {
        background.push(refresh(url, actualType));
      } else {
        background.push(store(url, actualType, response.clone()));
      }
    }
    return response;
  }

  self.addEventListener("fetch", function (event) {
    const request = event.request;
    const url = new URL(request.url);
    if (!mayHandle(request, url)) return;
    const background = [];
    const response = respond(request, mediaType(request, url), background);
    event.respondWith(response);
    event.waitUntil(response.then(function () {
      return Promise.allSettled(background);
    }, function () {}));
  });
})();
