import {setGlobalOptions} from "firebase-functions/v2";
import {generateNodeImage, generateNodeVideo} from "./create/generateNodeMedia";
import {generateNodeText} from "./create/generateNodeText";
import {proposeStoryOutline} from "./create/proposeOutline";
import {generateNodeVoice} from "./media/generateNodeVoice";
import {transcribeVoice} from "./media/transcribeVoice";
import {onUploadFinalized} from "./media/onUploadFinalized";

setGlobalOptions({region: "us-central1"});
export {
  generateNodeImage, generateNodeVideo, generateNodeText,
  proposeStoryOutline, generateNodeVoice, transcribeVoice, onUploadFinalized,
};
