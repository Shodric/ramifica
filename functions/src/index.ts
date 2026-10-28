import {setGlobalOptions} from "firebase-functions/v2";

import {commitChoice} from "./feed/commitChoice";
import {
  approveNodeImage,
  generateNodeImage,
  generateNodeVideo,
} from "./create/generateNodeMedia";
import {generateNodeText} from "./create/generateNodeText";
import {createNode, saveNode} from "./create/nodes";
import {loadPlayback} from "./feed/loadPlayback";
import {startRun} from "./feed/startRun";
import {graphStubs} from "./graph/graphStubs";
import {playApproach} from "./graph/playApproach";
import {rewindRun} from "./graph/rewindRun";
import {storyPage} from "./storyPage";
import {onUploadFinalized} from "./media/onUploadFinalized";

setGlobalOptions({region: "us-central1"});
export {
  approveNodeImage,
  commitChoice,
  createNode,
  generateNodeImage,
  generateNodeText,
  generateNodeVideo,
  loadPlayback,
  onUploadFinalized,
  saveNode,
  startRun,
  storyPage,
  graphStubs,
  playApproach,
  rewindRun,
};
