import {strict as assert} from "assert";
import {test} from "node:test";
import {requireCreator} from "./shared";

const author = "author@example.com";
const saved = process.env.CREATOR_EMAIL;

const withEmail = (email: string | undefined, run: () => void): void => {
  if (email === undefined) delete process.env.CREATOR_EMAIL;
  else process.env.CREATOR_EMAIL = email;
  try {
    run();
  } finally {
    if (saved === undefined) delete process.env.CREATOR_EMAIL;
    else process.env.CREATOR_EMAIL = saved;
  }
};

const denied = (auth: unknown): void => {
  assert.throws(() => requireCreator(auth), (error: unknown) => {
    return (error as {code?: string}).code === "permission-denied";
  });
};

test("requireCreator accepts the verified env email", () => {
  withEmail(author, () => {
    const uid = requireCreator({
      uid: "author",
      token: {email: "  Author@Example.com ", email_verified: true},
    });
    assert.equal(uid, "author");
  });
});

test("requireCreator rejects anyone else", () => {
  withEmail(author, () => {
    denied({
      uid: "other",
      token: {email: "other@example.com", email_verified: true},
    });
    denied({
      uid: "author",
      token: {email: author, email_verified: false},
    });
    denied({uid: "author"});
    denied({uid: "author", token: {email: author}});
  });
  assert.throws(() => requireCreator(null), (error: unknown) => {
    return (error as {code?: string}).code === "unauthenticated";
  });
});

test("requireCreator rejects every account when CREATOR_EMAIL is unset", () => {
  withEmail(undefined, () => {
    denied({
      uid: "author",
      token: {email: author, email_verified: true},
    });
  });
});
