import {strict as assert} from "assert";
import {readFileSync} from "fs";
import {test} from "node:test";
import {join} from "path";

test("encode.sh ships with LF endings", () => {
  // The trigger runs this exact copy (`processVideo` resolves it via
  // `__dirname`): a CR byte breaks `set -eo pipefail` in Cloud with
  // `set: pipefail: invalid option name`, failing every upload.
  const script = readFileSync(join(__dirname, "encode.sh"), "utf8");
  assert(!script.includes("\r"), "encode.sh must not contain CR bytes.");
  assert(
    script.includes("set -eo pipefail"),
    "encode.sh must keep strict mode."
  );
});
