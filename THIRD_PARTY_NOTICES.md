# Third-party notices

The MIT license at the repository root covers Fala's first-party application source.
It does not relicense system frameworks, dependencies, fonts or model weights.

- **Figtree and EB Garamond**: SIL Open Font License 1.1. Font copyright/license
  notices are bundled in `iOS/Fonts/OFL-*.txt` and `Mac/Resources/Fonts/OFL-*.txt`;
  those notices also cover the same typefaces under `android/app/src/main/res/font`.
- **WhisperKit 1.1.1**: https://github.com/argmaxinc/WhisperKit — MIT.
  Model/tokenizer downloads have their own upstream notices.
- **Whisper/faster-whisper, Piper, Kokoro, Chatterbox and Vosk**: optional voice
  components. Consult each upstream implementation and model card before
  downloading or redistributing their code/weights. Weights are not included here.
- **FFmpeg**: the Windows build script downloads a BtbN LGPL build. FFmpeg retains
  its upstream license and redistribution/source obligations; it is not MIT Fala code.
- **Python cryptography, websockets and segno; Wrangler/workerd; Android/Compose
  dependencies; Gradle** retain their upstream licenses and notices.
- Apple SDKs and platform capabilities remain subject to Apple's terms.

No private research repositories or vendored third-party experiments are part of
this source publication.
