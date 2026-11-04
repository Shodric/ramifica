import {existsSync, readFileSync, writeFileSync} from "fs";

const fromFile = () => {
  if (!existsSync("functions/.env")) return "";
  for (const line of readFileSync("functions/.env", "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("CREATOR_EMAIL=")) continue;
    return trimmed.slice("CREATOR_EMAIL=".length).trim();
  }
  return "";
};

const email = (process.env.CREATOR_EMAIL || fromFile()).trim().toLowerCase();
if (!/^[^@\s']+@[^@\s']+\.[^@\s']+$/.test(email)) {
  console.error("Set CREATOR_EMAIL to the verified author address.");
  process.exit(1);
}

const file = "firestore.rules";
const rules = readFileSync(file, "utf8");
const needle = /request\.auth\.token\.email\.lower\(\) == '[^']*'/;
if (!needle.test(rules)) {
  console.error("creator() email comparison not found in firestore.rules");
  process.exit(1);
}
writeFileSync(
  file,
  rules.replace(
    needle,
    `request.auth.token.email.lower() == '${email}'`,
  ),
);
console.log("Stamped creator() in firestore.rules.");
