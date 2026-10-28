import {setGlobalOptions} from "firebase-functions/v2";

import {storyPage} from "./storyPage";

setGlobalOptions({region: "us-central1"});

export {storyPage};
