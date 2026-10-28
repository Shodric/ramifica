import {setGlobalOptions} from "firebase-functions/v2";

import {commitChoice} from "./feed/commitChoice";
import {loadPlayback} from "./feed/loadPlayback";
import {startRun} from "./feed/startRun";
import {storyPage} from "./storyPage";

setGlobalOptions({region: "us-central1"});

export {commitChoice, loadPlayback, startRun, storyPage};
