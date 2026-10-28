import {setGlobalOptions} from "firebase-functions/v2";

import {commitChoice} from "./feed/commitChoice";
import {
  approveNodeImage,
  generateNodeImage,
  generateNodeVideo,
} from "./create/generateNodeMedia";
import {generateNodeText} from "./create/generateNodeText";
import {generateNodeVoice} from "./media/generateNodeVoice";
import {createNode, deleteNode, saveNode} from "./create/nodes";
import {publishStory} from "./publish/publishStory";
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
  deleteNode,
  generateNodeImage,
  generateNodeText,
  generateNodeVideo,
  generateNodeVoice,
  graphStubs,
  loadPlayback,
  onUploadFinalized,
  playApproach,
  publishStory,
  rewindRun,
  saveNode,
  startRun,
  storyPage,
};
