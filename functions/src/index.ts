import {setGlobalOptions} from "firebase-functions/v2";
import {createVideoUploadUrl} from "./create/createVideoUploadUrl";
import {decideChoiceIcon} from "./create/decideChoiceIcon";
import {generateEndingBadge} from "./create/generateEndingBadge";
import {generateNodeImage, generateNodeVideo} from "./create/generateNodeMedia";
import {generateStoryCover} from "./create/generateStoryCover";
import {generateNodeText} from "./create/generateNodeText";
import {proposeStoryOutline} from "./create/proposeOutline";
import {generateNodeVoice} from "./media/generateNodeVoice";
import {transcribeVoice} from "./media/transcribeVoice";
import {onUploadFinalized} from "./media/onUploadFinalized";

setGlobalOptions({region: "us-central1"});
export {
  createVideoUploadUrl,
  decideChoiceIcon,
  generateEndingBadge,
  generateNodeImage, generateNodeVideo, generateNodeText, generateStoryCover,
  proposeStoryOutline, generateNodeVoice, transcribeVoice, onUploadFinalized,
};
