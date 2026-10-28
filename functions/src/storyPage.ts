import * as admin from "firebase-admin";
import {onRequest} from "firebase-functions/v2/https";

if (admin.apps.length === 0) {
  admin.initializeApp();
}

const shellCache = "public, max-age=300, s-maxage=600";

const genericDescription =
  "Vertical interactive video. A narrator asks which decision the " +
  "protagonist should take, and you choose by holding a point on the " +
  "scene for one second.";

interface StoryPreview {
  title: string;
  synopsis: string | null;
  ogImageUrl: string | null;
}

/** Crawlers read this HTML without running JS. Players boot the app. */
export const storyPage = onRequest(async (req, res) => {
  const id = storyIdFromPath(req.path);
  const story = id ? await readStory(id) : null;
  res.set("Content-Type", "text/html; charset=utf-8");
  res.set("Cache-Control", shellCache);
  res.status(200).send(buildStoryHtml(canonicalUrl(req, id), story));
});

/**
 * Reads the published story preview. Returns null for missing, unpublished,
 * or unreadable docs so the link always serves at least the generic shell.
 * @param {string} id Story id from the path.
 * @return {Promise<StoryPreview | null>} The preview, or null.
 */
async function readStory(id: string): Promise<StoryPreview | null> {
  try {
    const snap = await admin.firestore().doc(`stories/${id}`).get();
    if (!snap.exists) return null;
    const data = snap.data() as {
      status?: unknown;
      title?: unknown;
      synopsis?: unknown;
      ogImageUrl?: unknown;
    };
    if (data.status !== "published") return null;
    if (typeof data.title !== "string" || data.title.trim() === "") {
      return null;
    }
    return {
      title: data.title,
      synopsis:
        typeof data.synopsis === "string" && data.synopsis.trim() !== "" ?
          data.synopsis :
          null,
      ogImageUrl:
        typeof data.ogImageUrl === "string" &&
        data.ogImageUrl.trim() !== "" ?
          data.ogImageUrl :
          null,
    };
  } catch {
    // A preview must never break the link: fall back to the generic shell.
    return null;
  }
}

/**
 * Extracts the story id from a `/story/{id}` path. Returns null for
 * anything else.
 * @param {string} path Request path without the query string.
 * @return {string | null} The decoded id, or null.
 */
export function storyIdFromPath(path: string): string | null {
  const match = /^\/story\/([^/?#]+)\/?$/.exec(path);
  if (!match) return null;
  try {
    const id = decodeURIComponent(match[1]).trim();
    return id === "" ? null : id;
  } catch {
    return null;
  }
}

/**
 * Absolute canonical URL for the OG tags, from the request host.
 * @param {Object} req Request host carrier.
 * @param {string | null} id Story id, or null for the site root.
 * @return {string} The absolute URL.
 */
function canonicalUrl(
  req: {hostname?: string; path?: string},
  id: string | null
): string {
  const host = req.hostname ?? "localhost";
  return id ? `https://${host}/story/${id}` : `https://${host}/`;
}
/**
 * Escapes a string for use inside HTML text and attribute values.
 * @param {string} value Raw text.
 * @return {string} The escaped text.
 */
export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Mirrors web/index.html with absolute asset paths (this document is served
 * under /story/{id}, where relative paths would resolve wrongly) plus the
 * OG tags. Keep in sync with web/index.html when that file changes.
 * @param {string} url Absolute canonical URL for `og:url`.
 * @param {StoryPreview | null} story Published preview, or null for the shell.
 * @return {string} The full HTML document.
 */
export function buildStoryHtml(
  url: string,
  story: StoryPreview | null
): string {
  const title = story ? story.title : "Ramifica";
  const description = story?.synopsis ?? genericDescription;
  const image = story?.ogImageUrl;
  const tags = [
    `<meta property="og:title" content="${escapeHtml(title)}">`,
    `<meta property="og:description" content="${escapeHtml(description)}">`,
    `<meta property="og:url" content="${escapeHtml(url)}">`,
    "<meta property=\"og:type\" content=\"website\">",
    "<meta property=\"og:site_name\" content=\"Ramifica\">",
    ...(image ?
      [
        `<meta property="og:image" content="${escapeHtml(image)}">`,
        "<meta name=\"twitter:card\" content=\"summary_large_image\">",
      ] :
      ["<meta name=\"twitter:card\" content=\"summary\">"]),
  ].join("\n  ");
  return `<!DOCTYPE html>
<html>
<head>
  <base href="/">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <meta name="description" content="${escapeHtml(description)}">
  <meta name="viewport"
    content="width=device-width, initial-scale=1.0, viewport-fit=cover">
  <meta name="mobile-web-app-capable" content="yes">
  <meta name="apple-mobile-web-app-status-bar-style" content="black">
  <meta name="apple-mobile-web-app-title" content="Ramifica">
  <link rel="apple-touch-icon" href="/icons/Icon-192.png">
  <link rel="icon" type="image/png" href="/favicon.png"/>
  <title>${escapeHtml(title)}</title>
  ${tags}
  <link rel="manifest" href="/manifest.webmanifest">
  <style>
    html, body {
      height: 100dvh;
      margin: 0;
      overscroll-behavior: none;
      background: #131318;
    }

    body {
      touch-action: none;
      user-select: none;
      -webkit-user-select: none;
      -webkit-touch-callout: none;
    }

    video {
      pointer-events: none;
    }
  </style>
</head>
<body>
  <script>
    // A hold is a choice. The browser must not turn it into a callout.
    document.addEventListener("contextmenu", function (event) {
      event.preventDefault();
    });
  </script>
  <script src="/flutter_bootstrap.js" async></script>
</body>
</html>
`;
}
