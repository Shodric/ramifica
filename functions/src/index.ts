import {setGlobalOptions} from "firebase-functions/v2";

import {commitChoice} from "./feed/commitChoice";
import {generateNodeText} from "./create/generateNodeText";
import {createNode, saveNode} from "./create/nodes";
import {loadPlayback} from "./feed/loadPlayback";
import {startRun} from "./feed/startRun";
import {graphStubs} from "./graph/graphStubs";
import {playApproach} from "./graph/playApproach";
import {rewindRun} from "./graph/rewindRun";
import {storyPage} from "./storyPage";

setGlobalOptions({region: "us-central1"});
export {
  commitChoice,
  createNode,
  generateNodeText,
  loadPlayback,
  saveNode,
  startRun,
  storyPage,
  graphStubs,
  playApproach,
  rewindRun,
};
