/**
 * Hotspot icon categories for the two-stage icon decision. The decision
 * model caps a single `choice` question at 256 options while the catalog
 * holds 391 icons, so `decideChoiceIcon` first picks one of these
 * categories and then the icon inside it. Every `knownChoiceIcons` entry
 * must appear in exactly one category; the decide test enforces the
 * coverage and the per-category option ceiling.
 */
export const choiceIconCategories: Record<string, readonly string[]> = {
  nature: [
    "mountain", "forest", "tree", "leaf", "grass", "flower", "garden",
    "park", "desert", "river", "beach", "water", "volcano", "hive",
  ],
  weather: [
    "sun", "moon", "crescent", "dawn", "night", "eclipse", "cloud",
    "fog", "wind", "fire", "blaze", "bright", "lightning", "thunder",
    "tornado", "cyclone", "waves", "flood", "tsunami", "snow",
    "snowfall", "umbrella",
  ],
  animals: ["pets", "wildlife", "bug", "pest"],
  food: [
    "food", "dish", "pizza", "burger", "noodles", "kebab", "bbq",
    "tapas", "soup", "rice", "egg", "omelette", "breakfast", "brunch",
    "meal", "dinner", "bakery", "donut", "cake", "icecream", "coffee",
    "tea", "wine", "fast",
  ],
  places: [
    "door", "home", "castle", "fort", "church", "mosque", "temple",
    "synagogue", "school", "library", "museum", "cinema", "tavern",
    "bar", "festival", "arena", "shop", "boutique", "mall", "bank",
    "post", "hospital", "pharmacy", "inn", "lounge", "tower",
    "apartment", "villa", "cabin", "cottage", "chalet", "bungalow",
    "warehouse", "factory", "city", "elevator", "stairs", "escalator",
  ],
  home: [
    "bed", "tub", "bath", "wc", "sofa", "chair", "table", "counter",
    "kitchen", "microwave", "mop", "clean", "laundry", "wallpaper",
    "curtains", "window", "balcony", "fence", "garage", "roofing",
    "fireplace", "deck",
  ],
  travel: [
    "compass", "map", "globe", "world", "anchor", "ship", "boat",
    "houseboat", "plane", "shuttle", "car", "truck", "camper",
    "forklift", "tractor", "moto", "moped", "scooter", "ebike",
    "bike", "train", "tram", "bus", "subway", "carwash",
    "snowmobile", "backpack", "bag", "fuel",
  ],
  sports: [
    "run", "walk", "hike", "swim", "dive", "surf", "kayak", "glide",
    "ski", "skate", "roller", "iceskate", "sled", "yoga", "gym",
    "fighter", "wrestle", "ball", "hoop", "tennis",
  ],
  people: [
    "face", "hand", "eye", "heart", "smile", "sorrow", "sleep",
    "mood", "calm", "joy", "grief", "crush", "heartbreak", "wave",
    "reach", "like", "dislike", "pact", "party", "crew", "tribe",
    "member", "chat", "call",
  ],
  symbols: [
    "star", "halfstar", "diamond", "flag", "trophy", "medal",
    "moonshield", "cards", "dice", "puzzle", "masks", "question",
    "check", "cross", "warning", "info", "ban", "infinity", "math",
    "target", "bell", "badge", "wish", "elite", "premium", "verified",
    "approval", "debut", "verdict", "scales", "ranks", "unseen",
    "plan", "levels", "burst", "bulb", "gift",
  ],
  security: [
    "key", "keys", "lock", "unlock", "shield", "fingerprint",
    "guard", "ward", "police", "safe", "access", "login", "logout",
  ],
  tools: [
    "hammer", "wrench", "tools", "gear", "build", "repair", "paint",
    "brush", "pencil", "lab", "print", "torch", "tune", "search",
  ],
  tech: [
    "phone", "watch", "laptop", "desktop", "monitor", "tablet",
    "keyboard", "mouse", "webcam", "router", "server", "chip",
    "code", "terminal", "signal", "bluetooth", "gps", "battery",
    "power", "charge", "plug", "cable", "usb", "sdcard", "sim",
    "radar", "satellite", "rocket", "robot", "droid", "ar",
  ],
  media: [
    "music", "song", "album", "playlist", "tunes", "beat", "audio",
    "mic", "speaker", "headset", "surround", "radio", "podcast",
    "voice", "play", "shuffle", "repeat", "video", "film", "camera",
    "image", "art", "tv", "game", "toys", "news", "press",
    "megaphone", "book", "feed",
  ],
  time: [
    "clock", "timer", "timelapse", "hourglass", "schedule", "dates",
    "event", "history",
  ],
  files: [
    "doc", "file", "folder", "archive", "box", "inbox", "outbox",
    "drafts", "mail", "send", "unread", "backup", "restore",
    "storage",
  ],
  actions: [
    "tap", "gesture", "swipe", "drag", "pin", "locate", "zoom",
    "scan", "launch", "dash", "spin", "swap", "sync", "renew",
    "update", "upgrade", "save", "download", "upload", "share",
    "undo", "redo", "more", "halt", "input", "output",
  ],
  health: [
    "sick", "blood", "pulse", "aid", "medic", "heal", "pills",
    "rescue", "spa",
  ],
  money: [
    "coin", "cash", "card", "wallet", "cart", "tag", "ticket",
    "receipt", "redeem",
  ],
  magic: ["magic", "sparkles", "portal"],
};
