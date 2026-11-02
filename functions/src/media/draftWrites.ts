import {HttpsError} from "firebase-functions/v2/https";
import {Db, DbTx, docData} from "../feed/shared";

type Fields = Record<string, unknown>;

/**
 * Media writes participate in the same revision fence as client edits.
 * @param {Db} db Firestore database.
 * @param {string} storyId Story id.
 * @param {Function} action Transaction body.
 * @return {Promise<T>} Transaction result.
 */
export const draftTransaction = async <T>(
  db: Db, storyId: string,
  action: (tx: DbTx, story: Fields) => Promise<T>
): Promise<T> => db.runTransaction(async (tx) => {
  const ref = db.doc(`stories/${storyId}`);
  const snap = await tx.get(ref);
  if (!snap.exists || docData(snap, "Story").status !== "draft") {
    throw new HttpsError(
      "failed-precondition",
      "The draft is no longer editable."
    );
  }
  const story = docData(snap, "Story");
  const result = await action(tx, story);
  await tx.set(ref, {
    revision: Number(story.revision ?? 0) + 1,
    updatedAt: new Date().toISOString(),
  }, {merge: true});
  return result;
});

/**
 * Never resurrect a deleted node when a provider finishes late.
 * @param {Db} db Firestore database.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {Fields} fields Fields to merge.
 * @param {Function} check Optional node guard.
 * @return {Promise<void>} Resolves when written.
 */
export const writeMedia = async (
  db: Db, storyId: string, nodeId: string, fields: Fields,
  check?: (node: Fields) => void
): Promise<void> => draftTransaction(db, storyId, async (tx) => {
  const ref = db.doc(`stories/${storyId}/nodes/${nodeId}`);
  const snap = await tx.get(ref);
  if (!snap.exists) throw new HttpsError("not-found", "Node was deleted.");
  check?.(docData(snap, "Node"));
  await tx.set(ref, fields, {merge: true});
});

/**
 * A bounded lease makes a killed image/TTS worker recoverable after reload.
 * @param {Db} db Firestore database.
 * @param {string} storyId Story id.
 * @param {string} nodeId Node id.
 * @param {string} kind Media kind.
 * @param {Fields} fields Fields to merge.
 * @return {Promise<void>} Resolves when the lease is written.
 */
export const beginMedia = async (
  db: Db, storyId: string, nodeId: string, kind: string, fields: Fields
): Promise<void> => {
  const now = Date.now();
  await writeMedia(db, storyId, nodeId, {...fields, generationKind: kind,
    generationStartedAt: new Date(now).toISOString(),
    generationExpiresAt: new Date(now + 300000).toISOString()}, (node) => {
    if (node.generationKind != null &&
        Date.parse(String(node.generationExpiresAt ?? "")) > now) {
      throw new HttpsError(
        "failed-precondition",
        "A media request is already running. " +
          "Wait for it or retry after its timeout."
      );
    }
  });
};
